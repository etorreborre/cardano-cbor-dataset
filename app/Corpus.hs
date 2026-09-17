{-# LANGUAGE ScopedTypeVariables #-}

module Corpus
  ( VerificationMode (..),
    generateDataset,
    verifyDataset,
  )
where

import Cardano.Crypto.Hash.Class (Hash, hashToStringAsHex, hashWith)
import Cardano.Crypto.Hash.SHA256 (SHA256)
import Control.Exception (IOException, try)
import Control.Monad (foldM, forM, forM_, unless, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (digitToInt, isHexDigit, isSpace)
import Data.Either (isLeft)
import Data.List (intercalate, isInfixOf, sort)
import Data.Maybe (isNothing)
import Data.Monoid (Sum (..))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import LedgerRules
  ( EraSpec,
    RuleCheck,
    deserializeRule,
    eraSpecName,
    eraSpecProtocolVersion,
    eraSpecRules,
    lookupRule,
    reserializeRule,
    ruleCheckByteExact,
    ruleCheckName,
  )
import Normalize (normalizeBytes)
import Numeric (readHex)
import Paths
  ( listDirectoryChecked,
    publishDirectory,
    requireCBORFile,
    requireRealDirectory,
  )
import Report
  ( ConformanceReport (..),
    Failure (..),
    Outcome (..),
    Reason,
    FailureKind (..),
    failureKindLabel,
    writeReport,
  )
import System.Directory
  ( canonicalizePath,
    createDirectoryIfMissing,
    getPermissions,
    writable,
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess), die, exitFailure)
import System.FilePath (dropExtension, takeDirectory, takeFileName, (</>))
import System.IO (hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)
import Text.Printf (printf)

-- VERIFICATION MODES
data VerificationMode
  = DeserializeOnly
  | CheckExpectedOutput

verificationModeName :: VerificationMode -> String
verificationModeName DeserializeOnly = "deserialize"
verificationModeName CheckExpectedOutput = "expected"

modeReadsReferences :: VerificationMode -> Bool
modeReadsReferences DeserializeOnly = False
modeReadsReferences CheckExpectedOutput = True

data Expectation = MustDecode | MustReject
  deriving (Eq)

data DatasetFile = DatasetFile
  { datasetFilePath :: !FilePath,
    datasetFileRule :: !RuleCheck,
    datasetFileCategory :: !DatasetCategory,
    -- | @\<rule\>\/\<category\>\/\<file stem\>@, the name a report gives this
    -- sample. It carries no extension, so a consumer can append its own.
    datasetFileSample :: !FilePath,
    -- | The reference this sample's re-encoding must reproduce. Only a @valid@
    -- sample has one, and every @valid@ sample does: generation puts a sample
    -- it cannot decode under @invalid@ instead.
    datasetFileExpectedPath :: !(Maybe FilePath)
  }

-- | Where a sample lives, which is also what it must do. Generation decides
-- this per sample rather than by where the generator was aimed: bytes that
-- satisfy the CDDL but that the decoder rejects are not valid, so they go under
-- @invalid@ at severity zero, beside the mutations of the same sample.
data DatasetCategory = Valid | Zap !Int
  deriving (Eq)

-- | Path of a category relative to its rule directory.
categoryName :: DatasetCategory -> FilePath
categoryName Valid = validCategoryName
categoryName (Zap level) = invalidCategoryName </> zapLevelName level

-- | The one category that must decode.
validCategoryName :: FilePath
validCategoryName = "valid"

-- | Parent of every category that must be rejected.
invalidCategoryName :: FilePath
invalidCategoryName = "invalid"

zapLevelName :: Int -> FilePath
zapLevelName level = "zap-" <> show level

categoryExpectation :: DatasetCategory -> Expectation
categoryExpectation Valid = MustDecode
categoryExpectation (Zap _) = MustReject

-- | What a sample must do. Its category settles this on its own, which is the
-- point of putting the generator output the decoder rejects under @invalid@
-- rather than leaving it in @valid@ without a reference.
datasetFileExpectation :: DatasetFile -> Expectation
datasetFileExpectation = categoryExpectation . datasetFileCategory

-- | Severity zero is the unmutated sample the decoder rejects; one to three are
-- the mutations of increasing severity.
zapLevels :: [Int]
zapLevels = [0 .. 3]

-- | Every category a corpus can hold.
datasetCategories :: [DatasetCategory]
datasetCategories = Valid : map Zap zapLevels

-- | The categories generation is aimed at. Severity zero is not among them: it
-- is filled by the @valid@ run, from the samples the decoder rejects.
generatedCategories :: [DatasetCategory]
generatedCategories = Valid : map Zap (filter (> 0) zapLevels)

-- | Sibling of the sample categories, holding the normalized reference
-- encoding of every @valid@ sample under the same file name.
expectedCategoryName :: FilePath
expectedCategoryName = "expected"

-- | Reject entries that name no category at all, and demand the two a run
-- cannot do without: @valid@, and @expected@ in the mode that reads it.
--
-- An @invalid@ directory is not demanded, nor are the severities inside it. The
-- generator creates them all but leaves one empty for a rule whose mutations
-- the decoder never rejects, and version control tracks no empty directory, so
-- a committed corpus arrives without them. Treating that as a broken corpus
-- stopped verification of every other rule; the absent directories are reported
-- in the summary instead.
requireKnownCategories :: Bool -> FilePath -> [FilePath] -> [FilePath] -> IO ()
requireKnownCategories referencesRequired path actual severities = do
  let known = [validCategoryName, expectedCategoryName, invalidCategoryName]
      unknown = sort $ filter (`notElem` known) actual
      unknownSeverities = sort $ filter (`notElem` map zapLevelName zapLevels) severities
      required =
        [validCategoryName | validCategoryName `notElem` actual]
          <> [expectedCategoryName | referencesRequired, expectedCategoryName `notElem` actual]
  unless (null unknown) $
    die $ "unexpected entries in '" <> path <> "': " <> show unknown
  unless (null unknownSeverities) $
    die $
      "unexpected entries in '"
        <> (path </> invalidCategoryName)
        <> "': "
        <> show unknownSeverities
  unless (null required) $
    die $ "missing directories in '" <> path <> "': " <> show required

-- | Every sample in the corpus, and the categories that are not there.
listDatasetFiles :: EraSpec -> Bool -> FilePath -> IO ([DatasetFile], [FilePath])
listDatasetFiles era referencesRequired root = do
  actualRules <- listDirectoryChecked root
  when (null actualRules) $ die $ "dataset contains no rule directories: " <> root
  selectedRules <- forM actualRules $ \ruleName ->
    case lookupRule era ruleName of
      Left message -> die $ message <> " in '" <> root <> "'"
      Right rule -> pure rule
  nested <- forM selectedRules $ \rule -> do
    let ruleName = ruleCheckName rule
        rulePath = root </> ruleName
    requireRealDirectory "dataset directory" rulePath
    actualCategories <- listDirectoryChecked rulePath
    severities <-
      if invalidCategoryName `elem` actualCategories
        then do
          requireRealDirectory "dataset directory" $ rulePath </> invalidCategoryName
          listDirectoryChecked $ rulePath </> invalidCategoryName
        else pure []
    requireKnownCategories referencesRequired rulePath actualCategories severities
    let present Valid = validCategoryName `elem` actualCategories
        present (Zap level) = zapLevelName level `elem` severities
    categoryFiles <- forM datasetCategories $ \category ->
      if not $ present category
        then pure ([], [ruleName </> categoryName category])
        else do
          let categoryPath = rulePath </> categoryName category
          requireRealDirectory "dataset directory" categoryPath
          fileNames <- listDirectoryChecked categoryPath
          found <- forM fileNames $ \fileName -> do
            let path = categoryPath </> fileName
            requireCBORFile path
            pure $
              DatasetFile
                { datasetFilePath = path,
                  datasetFileRule = rule,
                  datasetFileCategory = category,
                  datasetFileSample =
                    ruleName </> categoryName category </> dropExtension fileName,
                  datasetFileExpectedPath =
                    case category of
                      Valid -> Just $ rulePath </> expectedCategoryName </> fileName
                      Zap _ -> Nothing
                }
          pure (found, [])
    pure (concatMap fst categoryFiles, concatMap snd categoryFiles)
  let files = concatMap fst nested
  when (null files) $ die $ "dataset contains no CBOR files: " <> root
  pure (files, concatMap snd nested)

-- | One accepted sample decoded and re-encoded: the raw re-encoding, and the
-- reference encoding a conforming implementation has to reproduce.
--
-- Normalizing is what makes an ordinary reference portable. An implementation
-- reproduces it from its own decoder without having to reproduce this encoder's
-- choice of container form or integer head, neither of which the format fixes.
--
-- A rule whose bytes are hashed is the exception, and its reference is the raw
-- re-encoding. There the container form is fixed, by the hash, so normalizing
-- would throw away the very thing the reference is there to pin down.
expectedBytes :: RuleCheck -> BS.ByteString -> Either String (BS.ByteString, BS.ByteString)
expectedBytes rule bytes = do
  reserialized <- reserializeRule rule bytes
  reference <-
    if ruleCheckByteExact rule
      then pure reserialized
      else normalizeBytes reserialized
  pure (reserialized, reference)

checkExpectation :: Expectation -> Either String a -> Either Reason (Maybe a)
checkExpectation MustReject (Left _) = Right Nothing
checkExpectation MustReject (Right _) = Left (DecodeSucceeded, "deserialization unexpectedly succeeded")
checkExpectation MustDecode (Left err) = Left (DecodeFailed, "deserialization failed: " <> err)
checkExpectation MustDecode (Right value) = Right $ Just value

checkDatasetFile :: (RuleCheck -> BS.ByteString -> Either String a) -> DatasetFile -> IO (Either Reason (BS.ByteString, Maybe a))
checkDatasetFile operation datasetFile = do
  readResult <- try (BS.readFile $ datasetFilePath datasetFile) :: IO (Either IOException BS.ByteString)
  pure $ case readResult of
    Left err -> Left (SampleUnreadable, "cannot read file: " <> show err)
    Right bytes -> do
      checked <-
        checkExpectation
          (datasetFileExpectation datasetFile)
          (operation (datasetFileRule datasetFile) bytes)
      pure (bytes, checked)

verifyFile :: VerificationMode -> DatasetFile -> IO (Either Reason ())
verifyFile DeserializeOnly datasetFile =
  fmap (fmap $ const ()) $ checkDatasetFile deserializeRule datasetFile
-- | For a sample that must be rejected the only question is whether the decoder
-- rejects it, so ask the decoder directly rather than routing through the
-- re-encode and normalize steps, whose own failures would read as a rejection.
verifyFile CheckExpectedOutput datasetFile
  | isNothing (datasetFileExpectedPath datasetFile) =
      fmap (fmap $ const ()) $ checkDatasetFile deserializeRule datasetFile
verifyFile CheckExpectedOutput datasetFile = do
  checked <- checkDatasetFile expectedBytes datasetFile
  case checked of
    Left reason -> pure $ Left reason
    Right (_, Nothing) -> pure $ Right ()
    Right (original, Just (reserialized, bytes)) ->
      case datasetFileExpectedPath datasetFile of
        Nothing ->
          pure $ Left (ReferenceUnreadable, "sample was accepted but has no reference encoding")
        Just expectedPath -> do
          expectedResult <- try (BS.readFile expectedPath) :: IO (Either IOException BS.ByteString)
          pure $ case expectedResult of
            Left err ->
              Left
                ( ReferenceUnreadable
                , "cannot read expected output '" <> expectedPath <> "': " <> show err
                )
            Right referenceBytes -> do
              -- The hashed types are checked first: agreeing with the reference
              -- after normalization says nothing about a hash, so reporting the
              -- weaker mismatch for one of these rules would understate it.
              byteExactCheck original reserialized
              if bytes == referenceBytes
                then Right ()
                else
                  Left
                    ( ReferenceMismatch
                    , "normalized reserialization differs from '" <> expectedPath <> "'"
                    )
  where
    byteExactCheck original reserialized
      | not . ruleCheckByteExact $ datasetFileRule datasetFile = Right ()
      | reserialized == original = Right ()
      | otherwise =
          Left
            ( ByteExactMismatch
            , "reserialization differs from the original bytes, which this rule hashes"
            )

loadDataset :: EraSpec -> Bool -> FilePath -> IO (FilePath, [DatasetFile], [FilePath])
loadDataset era referencesRequired datasetDir = do
  requireRealDirectory "dataset directory" datasetDir
  root <- canonicalizePath datasetDir
  (files, absent) <- listDatasetFiles era referencesRequired root
  pure (root, files, absent)

reportResult :: DatasetFile -> Either Reason a -> IO (Either Reason a)
reportResult datasetFile result = do
  case result of
    Left (_, message) ->
      hPutStrLn stderr $ "FAIL " <> datasetFilePath datasetFile <> " (" <> message <> ")"
    Right _ -> pure ()
  pure result

-- | One rule's counts. @generated@ covers everything the CDDL generator
-- produced, which the layout splits in two: a @valid@ sample must decode,
-- re-encode and match its reference, and an @invalid\/zap-0@ sample is the same
-- generator output that the decoder rejects, since satisfying the CDDL does not
-- make bytes decodable. @zap@ counts the mutations of severity one and above,
-- which must always be rejected.
ruleOutcome :: [(DatasetFile, Either Reason ())] -> Outcome
ruleOutcome results =
  mempty
    { generatedTotal = count generated
    , generatedDecodedReencodedExpected = count decodable
    , generatedDecodedReencodedActual = count [() | (_, Right ()) <- decodable]
    , generatedMustBeRejectedExpected = count undecodable
    , generatedMustBeRejectedActual = count [() | (_, Right ()) <- undecodable]
    , zapMustBeRejectedExpected = count zaps
    , zapMustBeRejectedActual = count [() | (_, Right ()) <- zaps]
    }
  where
    count :: [a] -> Sum Int
    count = Sum . length
    -- Severity zero is the generator's own output, unmutated, so it counts as
    -- generated rather than as a mutation even though it lives under @invalid@.
    decodable = [entry | entry@(file, _) <- results, datasetFileCategory file == Valid]
    undecodable = [entry | entry@(file, _) <- results, datasetFileCategory file == Zap 0]
    zaps = [entry | entry@(file, _) <- results, isMutation $ datasetFileCategory file]
    generated = decodable <> undecodable
    isMutation (Zap level) = level > 0
    isMutation Valid = False

conformanceReport :: EraSpec -> FilePath -> [(DatasetFile, Either Reason ())] -> ConformanceReport
conformanceReport era corpus results =
  ConformanceReport
    { reportCorpus = corpus
    , reportProtocolVersion = eraSpecProtocolVersion era
    , reportTotals = foldMap snd perRule
    , reportRules = perRule
    , reportFailures =
        [ Failure
            { failureSample = datasetFileSample file
            , failureRule = ruleCheckName $ datasetFileRule file
            , failureClass = failureKindLabel kind
            , failureReason = message
            }
        | (file, Left (kind, message)) <- results
        ]
    }
  where
    perRule =
      Map.toList . Map.map ruleOutcome $
        Map.fromListWith
          (<>)
          [(ruleCheckName $ datasetFileRule file, [entry]) | entry@(file, _) <- results]

verifyDataset :: EraSpec -> VerificationMode -> FilePath -> IO ()
verifyDataset era mode datasetDir = do
  (root, files, absent) <- loadDataset era (modeReadsReferences mode) datasetDir
  results <- forM files $ \datasetFile -> do
    outcome <- verifyFile mode datasetFile >>= reportResult datasetFile
    pure (datasetFile, outcome)

  let outcomes = map snd results
      total = length files
      expectedValid = length [() | datasetFile <- files, datasetFileExpectation datasetFile == MustDecode]
      expectedInvalid = total - expectedValid
      passed = length [() | Right _ <- outcomes]
      failed = total - passed
  putStrLn $ "Checked " <> show total <> " " <> eraSpecName era <> " CBOR files"
  putStrLn $ "  mode:             " <> verificationModeName mode
  putStrLn $ "  expected valid:   " <> show expectedValid
  putStrLn $ "  expected invalid: " <> show expectedInvalid
  putStrLn $ "  passed:           " <> show passed
  putStrLn $ "  failed:           " <> show failed
  -- A rule whose mutations the decoder never rejects is a hole in the suite, so
  -- name it rather than letting the run look complete.
  unless (null absent) $
    putStrLn $ "  absent, no samples: " <> intercalate ", " (sort absent)

  -- Only the mode that checks references has the counts a conformance report
  -- claims; a deserialize run knows nothing about re-encoding.
  case mode of
    DeserializeOnly -> pure ()
    CheckExpectedOutput -> do
      let corpus = takeFileName root
          reportPath = takeDirectory root </> "reports" </> corpus </> "latest.json"
      writeResult <- try $ writeReport reportPath (conformanceReport era corpus results)
      case writeResult of
        Left (err :: IOException) -> die $ "cannot write conformance report: " <> show err
        Right () -> putStrLn $ "  report:           " <> reportPath

  when (failed /= 0) exitFailure

-- | Write the normalized reference encoding of one generated @valid@ sample,
-- returning why it has none when it has none: either the generator emitted
-- bytes the ledger decoder rejects, or the re-encoding has no reproducible
-- normal form. Neither stops generation, since the sample itself is still a
-- legitimate decoder test case.
emitReference :: RuleCheck -> FilePath -> FilePath -> FilePath -> IO (Maybe String)
emitReference rule validDir expectedDir fileName = do
  readResult <- try (BS.readFile $ validDir </> fileName) :: IO (Either IOException BS.ByteString)
  case fmap (expectedBytes rule) readResult of
    Left err -> pure $ Just $ "cannot read file: " <> show err
    Right (Left message) -> pure $ Just message
    Right (Right (_, bytes)) -> do
      let outputPath = expectedDir </> fileName
      writeResult <- try (BS.writeFile outputPath bytes) :: IO (Either IOException ())
      pure $ case writeResult of
        Left err -> Just $ "cannot write expected output '" <> outputPath <> "': " <> show err
        Right () -> Nothing

-- | Number of references written for one rule, and the samples that have none.
emitRuleReferences :: FilePath -> RuleCheck -> IO (Int, Int)
emitRuleReferences staging rule = do
  let ruleDir = staging </> ruleCheckName rule
      validDir = ruleDir </> categoryName Valid
      expectedDir = ruleDir </> expectedCategoryName
  createDirectoryIfMissing True expectedDir
  fileNames <- listDirectoryChecked validDir
  failures <- forM fileNames $ \fileName -> do
    outcome <- emitReference rule validDir expectedDir fileName
    case outcome of
      Just message ->
        hPutStrLn stderr $ "FAIL " <> (validDir </> fileName) <> " (" <> message <> ")"
      Nothing -> pure ()
    pure outcome
  pure (length [() | Nothing <- failures], length [() | Just _ <- failures])

sha256Hex :: BS.ByteString -> String
sha256Hex bytes =
  hashToStringAsHex (hashWith id bytes :: Hash SHA256 BS.ByteString)

seedFor :: Integer -> String -> DatasetCategory -> Int -> Int
seedFor topSeed rule category batch =
  case readHex $ take 8 digest of
    [(value, "")] -> fromInteger $ value `mod` 1500000000
    _ -> error "internal error: SHA-256 digest is not hexadecimal"
  where
    digest = sha256Hex $ BSC.pack $ show topSeed <> "|" <> rule <> "|" <> categoryName category <> "|" <> show batch

data BatchResult = BatchResult
  { batchLines :: ![String],
    batchExhausted :: !Bool
  }

generateBatch :: EraSpec -> Integer -> RuleCheck -> DatasetCategory -> Int -> Int -> IO BatchResult
generateBatch era topSeed rule category batch requested = do
  let ruleName = ruleCheckName rule
      name = categoryName category
      zapArguments =
        case category of
          Valid -> []
          Zap level -> ["--zap", show level]
      arguments =
        [ "--era",
          eraSpecName era,
          "--seed",
          show $ seedFor topSeed ruleName category batch,
          "--count",
          show requested
        ]
          <> zapArguments
          <> [ruleName]
  processResult <-
    try (readProcessWithExitCode "generate-cbor" arguments "") ::
      IO (Either IOException (ExitCode, String, String))
  (status, stdoutText, stderrText) <-
    case processResult of
      Left err -> die $ "cannot execute generate-cbor: " <> show err
      Right result -> pure result

  let outputLines = filter (not . all isSpace) $ lines stdoutText
      exhausted = "failed to generate a sample after " `isInfixOf` stderrText
      failGeneration message =
        die $
          "generate-cbor failed for "
            <> ruleName
            <> "/"
            <> name
            <> message
            <> if null stderrText then "" else "\n" <> stderrText
  case status of
    ExitSuccess -> pure $ BatchResult outputLines False
    ExitFailure code
      | Zap _ <- category,
        exhausted -> do
          when (length outputLines >= requested) $
            failGeneration $
              ": invalid partial output for a batch of " <> show requested
          pure $ BatchResult outputLines True
      | otherwise -> failGeneration $ " with exit " <> show code

decodeHex :: String -> Either String BS.ByteString
decodeHex encoded
  | null encoded || odd (length encoded) || any (not . isHexDigit) encoded =
      Left $ "invalid hexadecimal output '" <> encoded <> "'"
  | otherwise = Right $ BS.pack $ decodePairs encoded
  where
    decodePairs [] = []
    decodePairs (high : low : rest) =
      fromIntegral (digitToInt high * 16 + digitToInt low) : decodePairs rest
    decodePairs _ = error "internal error: odd hexadecimal length"

-- | Where one generated sample belongs, decided by the decoder rather than by
-- which generator run produced it.
--
-- A sample the CDDL generator produced but the decoder rejects is not valid, so
-- it goes under @invalid@ at severity zero. A mutation the decoder still accepts
-- tests nothing, since the corpus would demand a rejection that is correct not
-- to happen, so it is dropped: the generator mutates bytes without consulting
-- the decoder, and rules whose fields are all optional, such as
-- @protocol_param_update@, often survive a mutation as another legal value.
data Destination = Keep !DatasetCategory | Drop

destinationOf :: RuleCheck -> DatasetCategory -> BS.ByteString -> Destination
destinationOf rule category bytes =
  case category of
    Valid
      | rejected -> Keep $ Zap 0
      | otherwise -> Keep Valid
    Zap _
      | rejected -> Keep category
      | otherwise -> Drop
  where
    rejected = isLeft $ deserializeRule rule bytes

-- | Samples written to the category asked for, samples routed to severity zero
-- because the decoder rejected them, mutations dropped for being decodable, and
-- the digests seen so far. A dropped mutation still joins the digests, so an
-- identical one later in the run costs a lookup rather than another decode.
data Accumulated = Accumulated !Int !Int !Int !(Set.Set String)

addGeneratedLine :: FilePath -> RuleCheck -> DatasetCategory -> Accumulated -> String -> IO Accumulated
addGeneratedLine ruleDir rule category (Accumulated written rejected dropped seen) encoded = do
  let ruleName = ruleCheckName rule
  bytes <-
    case decodeHex encoded of
      Left message -> die $ message <> " for " <> ruleName <> "/" <> categoryName category
      Right value -> pure value
  let digest = sha256Hex bytes
      seenNow = Set.insert digest seen
      writeTo destination position = do
        let fileName = printf "%05d-%s.cbor" position (take 16 digest) :: FilePath
            path = ruleDir </> categoryName destination </> fileName
        writeResult <- try (BS.writeFile path bytes) :: IO (Either IOException ())
        case writeResult of
          Left (err :: IOException) -> die $ "cannot write '" <> path <> "': " <> show err
          Right () -> pure ()
  if Set.member digest seen
    then pure $ Accumulated written rejected dropped seen
    else case destinationOf rule category bytes of
      Drop -> pure $ Accumulated written rejected (dropped + 1) seenNow
      Keep (Zap 0)
        | Valid <- category -> do
            writeTo (Zap 0) (rejected + 1)
            pure $ Accumulated written (rejected + 1) dropped seenNow
      Keep destination -> do
        writeTo destination (written + 1)
        pure $ Accumulated (written + 1) rejected dropped seenNow

-- | Samples written for one rule and category. The count includes the ones the
-- @valid@ run routed to severity zero, so a rule still receives the number of
-- generated samples that was asked for however few of them decode.
addCases :: FilePath -> EraSpec -> Integer -> RuleCheck -> DatasetCategory -> Int -> IO Int
addCases staging era topSeed rule category target = do
  let ruleName = ruleCheckName rule
      name = categoryName category
      ruleDir = staging </> ruleName
      -- The @valid@ run fills severity zero as well, so both directories have to
      -- exist before it starts.
      destinations
        | Valid <- category = [Valid, Zap 0]
        | otherwise = [category]
      maxAttempts = 3 * target
      batchSize = 128
      finish accepted dropped attempts batches exhaustions = do
        when (accepted /= target) $
          hPutStrLn stderr $
            "generated "
              <> show accepted
              <> "/"
              <> show target
              <> " samples for "
              <> ruleName
              <> "/"
              <> name
              <> " after "
              <> show attempts
              <> " attempts in "
              <> show batches
              <> " batches"
        when (exhaustions > 0) $
          hPutStrLn stderr $
            "retried " <> ruleName <> "/" <> name <> " after " <> show exhaustions <> " generator search exhaustions"
        -- A rule that drops many mutations has a generator producing weak ones,
        -- which is worth knowing even when the budget still meets the target.
        when (dropped > 0) $
          hPutStrLn stderr $
            "dropped "
              <> show dropped
              <> " "
              <> ruleName
              <> "/"
              <> name
              <> " mutations the decoder accepts"
        pure accepted
      loop :: Int -> Int -> Int -> Int -> Int -> Int -> Set.Set String -> IO Int
      loop written rejected dropped attempts batch exhaustions seen
        | accepted >= target || attempts >= maxAttempts =
            finish accepted dropped attempts batch exhaustions
        | otherwise = do
            let requested = min batchSize $ min (target - accepted) (maxAttempts - attempts)
            result <- generateBatch era topSeed rule category batch requested
            let actualLines = length $ batchLines result
                attempted = actualLines + if batchExhausted result then 1 else 0
            when (not (batchExhausted result) && actualLines /= requested) $
              die $
                "unexpected "
                  <> ruleName
                  <> "/"
                  <> name
                  <> " output: "
                  <> show actualLines
                  <> " lines, expected "
                  <> show requested
            Accumulated nextWritten nextRejected nextDropped nextSeen <-
              foldM
                (addGeneratedLine ruleDir rule category)
                (Accumulated written rejected dropped seen)
                (batchLines result)
            loop
              nextWritten
              nextRejected
              nextDropped
              (attempts + attempted)
              (batch + 1)
              (exhaustions + if batchExhausted result then 1 else 0)
              nextSeen
        where
          accepted = written + rejected
  forM_ destinations $ \destination ->
    createDirectoryIfMissing True $ ruleDir </> categoryName destination
  loop 0 0 0 0 0 0 Set.empty

generateDataset :: EraSpec -> FilePath -> Integer -> Int -> IO ()
generateDataset era requestedOutputRoot topSeed count = do
  requireRealDirectory "output directory" requestedOutputRoot
  permissions <- getPermissions requestedOutputRoot
  unless (writable permissions) $ die $ "output directory is not writable: " <> requestedOutputRoot
  outputRoot <- canonicalizePath requestedOutputRoot
  when (outputRoot == "/") $ die "output directory must not be the filesystem root"

  let corpusName = eraSpecName era <> "-" <> show topSeed <> "-" <> show count
      destination = outputRoot </> corpusName
      rules = eraSpecRules era
  (generated, referenced, unreferenced) <- publishDirectory destination $ \staging -> do
    counts <- forM rules $ \rule ->
      forM generatedCategories $ \category -> do
        putStrLn $ "Generating " <> ruleCheckName rule <> "/" <> categoryName category
        addCases staging era topSeed rule category count
    references <- forM rules $ \rule -> do
      putStrLn $ "Emitting " <> ruleCheckName rule <> "/" <> expectedCategoryName
      emitRuleReferences staging rule
    pure (sum $ concat counts, sum $ map fst references, sum $ map snd references)

  let target = length rules * length generatedCategories * count
  putStrLn $ "Generated " <> show generated <> "/" <> show target <> " samples in " <> destination
  putStrLn $ "  references emitted:      " <> show referenced
  putStrLn $ "  valid samples without one: " <> show unreferenced
