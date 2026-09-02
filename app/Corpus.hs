{-# LANGUAGE ScopedTypeVariables #-}

module Corpus (
  VerificationMode (..),
  generateDataset,
  verifyDataset,
  emitExpectedDataset,
) where

import Cardano.Crypto.Hash.Class (Hash, hashToStringAsHex, hashWith)
import Cardano.Crypto.Hash.SHA256 (SHA256)
import Control.Exception (IOException, onException, try)
import Control.Monad (foldM, forM, unless, when)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Char (digitToInt, isHexDigit, isSpace)
import Data.List (isInfixOf, isPrefixOf, sort)
import qualified Data.Set as Set
import LedgerRules (
  EraSpec,
  RuleCheck,
  deserializeRule,
  eraSpecName,
  eraSpecRules,
  lookupRule,
  reserializeRule,
  ruleCheckName,
 )
import Numeric (readHex)
import System.Directory (
  canonicalizePath,
  createDirectoryIfMissing,
  doesDirectoryExist,
  getPermissions,
  listDirectory,
  removePathForcibly,
  renameDirectory,
  writable,
 )
import System.Exit (ExitCode (ExitFailure, ExitSuccess), die, exitFailure)
import System.FilePath ((</>), splitDirectories, takeDirectory, takeExtension, takeFileName)
import System.IO (hPutStrLn, stderr)
import System.IO.Error (isDoesNotExistError)
import System.IO.Temp (createTempDirectory)
import System.Posix.Files (
  FileStatus,
  getSymbolicLinkStatus,
  isDirectory,
  isRegularFile,
  isSymbolicLink,
  setFileMode,
 )
import System.Process (readProcessWithExitCode)
import Text.Printf (printf)

data VerificationMode
  = DeserializeOnly
  | CheckReserialization
  | CheckExpectedOutput FilePath

verificationModeName :: VerificationMode -> String
verificationModeName DeserializeOnly = "deserialize"
verificationModeName CheckReserialization = "reserialize"
verificationModeName (CheckExpectedOutput _) = "expected"

data Expectation = MustDecode | MustReject
  deriving (Eq)

data DatasetFile = DatasetFile
  { datasetFilePath :: !FilePath
  , datasetFileRelativePath :: !FilePath
  , datasetFileRule :: !RuleCheck
  , datasetFileExpectation :: !Expectation
  }

data DatasetCategory = Valid | Zap !Int

categoryName :: DatasetCategory -> FilePath
categoryName Valid = "valid"
categoryName (Zap level) = "zap-" <> show level

categoryExpectation :: DatasetCategory -> Expectation
categoryExpectation Valid = MustDecode
categoryExpectation (Zap _) = MustReject

datasetCategories :: [DatasetCategory]
datasetCategories = Valid : map Zap [1 .. 3]

pathStatus :: FilePath -> IO (Maybe FileStatus)
pathStatus path = do
  result <- try $ getSymbolicLinkStatus path
  case result of
    Left (err :: IOException)
      | isDoesNotExistError err -> pure Nothing
      | otherwise -> die $ "cannot inspect path '" <> path <> "': " <> show err
    Right status -> pure $ Just status

requireRealDirectory :: String -> FilePath -> IO ()
requireRealDirectory description path = do
  status <- pathStatus path
  case status of
    Nothing -> die $ "missing " <> description <> ": " <> path
    Just entry
      | isSymbolicLink entry -> die $ description <> " must not be a symbolic link: " <> path
      | isDirectory entry -> pure ()
      | otherwise -> die $ "expected " <> description <> ": " <> path

requireAbsentPath :: FilePath -> IO ()
requireAbsentPath path = do
  status <- pathStatus path
  case status of
    Nothing -> pure ()
    Just _ -> die $ "output path already exists: " <> path

listDirectoryChecked :: FilePath -> IO [FilePath]
listDirectoryChecked directory = do
  entriesResult <- try (listDirectory directory) :: IO (Either IOException [FilePath])
  case entriesResult of
    Left err -> die $ "cannot list directory '" <> directory <> "': " <> show err
    Right entries -> pure $ sort entries

requireCBORFile :: FilePath -> IO ()
requireCBORFile path = do
  status <- pathStatus path
  case status of
    Just entry
      | isSymbolicLink entry -> die $ "dataset files must not be symbolic links: " <> path
      | isRegularFile entry && takeExtension path == ".cbor" -> pure ()
    _ -> die $ "expected a .cbor dataset file: " <> path

requireExactCategories :: FilePath -> [FilePath] -> IO ()
requireExactCategories path actual = do
  let sortedExpected = sort $ map categoryName datasetCategories
      sortedActual = sort actual
  unless (sortedExpected == sortedActual) $
    die $
      "invalid category entries in '"
        <> path
        <> "': expected "
        <> show sortedExpected
        <> ", got "
        <> show sortedActual

listDatasetFiles :: EraSpec -> FilePath -> IO [DatasetFile]
listDatasetFiles era root = do
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
    requireExactCategories rulePath actualCategories
    categoryFiles <- forM datasetCategories $ \category -> do
      let categoryPath = rulePath </> categoryName category
      requireRealDirectory "dataset directory" categoryPath
      fileNames <- listDirectoryChecked categoryPath
      forM fileNames $ \fileName -> do
        let relativePath = ruleName </> categoryName category </> fileName
            path = root </> relativePath
        requireCBORFile path
        pure $
          DatasetFile
            { datasetFilePath = path
            , datasetFileRelativePath = relativePath
            , datasetFileRule = rule
            , datasetFileExpectation = categoryExpectation category
            }
    pure $ concat categoryFiles
  let files = concat nested
  when (null files) $ die $ "dataset contains no CBOR files: " <> root
  pure files

pathIsWithin :: FilePath -> FilePath -> Bool
pathIsWithin parent child =
  splitDirectories parent `isPrefixOf` splitDirectories child

pathsOverlap :: FilePath -> FilePath -> Bool
pathsOverlap left right = pathIsWithin left right || pathIsWithin right left

canonicalDisjointDirectory :: FilePath -> FilePath -> IO FilePath
canonicalDisjointDirectory datasetRoot requested = do
  directory <- canonicalizePath requested
  when (pathsOverlap datasetRoot directory) $
    die "expected output and dataset directories must not overlap"
  pure directory

resolveExpectedDirectory :: FilePath -> FilePath -> IO FilePath
resolveExpectedDirectory datasetRoot requested = do
  requireRealDirectory "expected output directory" requested
  canonicalDisjointDirectory datasetRoot requested

resolveVerificationMode :: FilePath -> VerificationMode -> IO VerificationMode
resolveVerificationMode datasetRoot (CheckExpectedOutput requested) =
  CheckExpectedOutput <$> resolveExpectedDirectory datasetRoot requested
resolveVerificationMode _ mode = pure mode

resolveNewExpectedDirectory :: FilePath -> FilePath -> IO FilePath
resolveNewExpectedDirectory datasetRoot requested = do
  requireAbsentPath requested
  directory <- canonicalDisjointDirectory datasetRoot requested
  createDirectoryIfMissing True $ takeDirectory directory
  pure directory

cleanupDirectory :: FilePath -> IO ()
cleanupDirectory path = do
  _ <- try (removePathForcibly path) :: IO (Either IOException ())
  pure ()

publishDirectory :: FilePath -> (FilePath -> IO a) -> IO a
publishDirectory destination build = do
  requireAbsentPath destination
  let parent = takeDirectory destination
      prefix = "." <> takeFileName destination <> ".tmp-"
  staging <- createTempDirectory parent prefix
  let cleanup = cleanupDirectory staging
  result <- (setFileMode staging 0o755 >> build staging) `onException` cleanup
  renameDirectory staging destination `onException` cleanup
  pure result

checkExpectation :: Expectation -> Either String a -> Either String (Maybe a)
checkExpectation MustReject (Left _) = Right Nothing
checkExpectation MustReject (Right _) = Left "deserialization unexpectedly succeeded"
checkExpectation MustDecode (Left err) = Left $ "deserialization failed: " <> err
checkExpectation MustDecode (Right value) = Right $ Just value

checkDatasetFile :: (RuleCheck -> BS.ByteString -> Either String a) -> DatasetFile -> IO (Either String (BS.ByteString, Maybe a))
checkDatasetFile operation datasetFile = do
  readResult <- try (BS.readFile $ datasetFilePath datasetFile) :: IO (Either IOException BS.ByteString)
  pure $ case readResult of
    Left err -> Left $ "cannot read file: " <> show err
    Right bytes -> do
      checked <-
        checkExpectation
          (datasetFileExpectation datasetFile)
          (operation (datasetFileRule datasetFile) bytes)
      pure (bytes, checked)

verifyFile :: VerificationMode -> DatasetFile -> IO (Either String ())
verifyFile DeserializeOnly datasetFile =
  fmap (fmap $ const ()) $ checkDatasetFile deserializeRule datasetFile
verifyFile CheckReserialization datasetFile = do
  checked <- checkDatasetFile reserializeRule datasetFile
  case checked of
    Left message -> pure $ Left message
    Right (_, Nothing) -> pure $ Right ()
    Right (original, Just bytes)
      | bytes == original -> pure $ Right ()
      | otherwise -> pure $ Left "reserialization differs from input"
verifyFile (CheckExpectedOutput expectedRoot) datasetFile = do
  checked <- checkDatasetFile reserializeRule datasetFile
  case checked of
    Left message -> pure $ Left message
    Right (_, Nothing) -> pure $ Right ()
    Right (_, Just bytes) -> do
      let expectedPath = expectedRoot </> datasetFileRelativePath datasetFile
      expectedResult <- try (BS.readFile expectedPath) :: IO (Either IOException BS.ByteString)
      pure $ case expectedResult of
        Left err -> Left $ "cannot read expected output '" <> expectedPath <> "': " <> show err
        Right expectedBytes
          | bytes == expectedBytes -> Right ()
          | otherwise -> Left $ "reserialization differs from expected output '" <> expectedPath <> "'"

loadDataset :: EraSpec -> FilePath -> IO (FilePath, [DatasetFile])
loadDataset era datasetDir = do
  requireRealDirectory "dataset directory" datasetDir
  root <- canonicalizePath datasetDir
  files <- listDatasetFiles era root
  pure (root, files)

reportResult :: DatasetFile -> Either String a -> IO (Either String a)
reportResult datasetFile result = do
  case result of
    Left message -> hPutStrLn stderr $ "FAIL " <> datasetFilePath datasetFile <> " (" <> message <> ")"
    Right _ -> pure ()
  pure result

verifyDataset :: EraSpec -> VerificationMode -> FilePath -> IO ()
verifyDataset era requestedMode datasetDir = do
  (root, files) <- loadDataset era datasetDir
  mode <- resolveVerificationMode root requestedMode
  outcomes <- forM files $ \datasetFile ->
    verifyFile mode datasetFile >>= reportResult datasetFile

  let total = length files
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
  when (failed /= 0) exitFailure

emitExpectedFile :: FilePath -> DatasetFile -> IO (Either String Bool)
emitExpectedFile outputRoot datasetFile = do
  checked <- checkDatasetFile reserializeRule datasetFile
  case checked of
    Left message -> pure $ Left message
    Right (_, Nothing) -> pure $ Right False
    Right (_, Just bytes) -> do
      let outputPath = outputRoot </> datasetFileRelativePath datasetFile
      writeResult <-
        try $ do
          createDirectoryIfMissing True $ takeDirectory outputPath
          BS.writeFile outputPath bytes
      pure $ case writeResult of
        Left (err :: IOException) -> Left $ "cannot write expected output '" <> outputPath <> "': " <> show err
        Right () -> Right True

emitExpectedDataset :: EraSpec -> FilePath -> FilePath -> IO ()
emitExpectedDataset era datasetDir requestedOutputDir = do
  (root, files) <- loadDataset era datasetDir
  outputRoot <- resolveNewExpectedDirectory root requestedOutputDir
  publication <-
    try
      ( publishDirectory outputRoot $ \staging -> do
          outcomes <- forM files $ \datasetFile ->
            emitExpectedFile staging datasetFile >>= reportResult datasetFile
          pure
            ( length outcomes
            , length [() | Right True <- outcomes]
            , length [() | Left _ <- outcomes]
            )
      )
      :: IO (Either IOException (Int, Int, Int))
  (total, emitted, failed) <-
    case publication of
      Left err -> do
        putStrLn $ "  output directory created: no (" <> outputRoot <> ")"
        die $ "cannot publish expected outputs: " <> show err
      Right summary -> pure summary
  created <- doesDirectoryExist outputRoot
  putStrLn $ "Checked " <> show total <> " " <> eraSpecName era <> " CBOR files"
  putStrLn $ "  expected outputs emitted: " <> show emitted
  putStrLn $ "  failed:                   " <> show failed
  putStrLn $
    "  output directory created: "
      <> (if created then "yes" else "no")
      <> " ("
      <> outputRoot
      <> ")"
  unless created $ die "expected output publication completed but its directory is missing"
  when (failed /= 0) exitFailure

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
  { batchLines :: ![String]
  , batchExhausted :: !Bool
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
        [ "--era"
        , eraSpecName era
        , "--seed"
        , show $ seedFor topSeed ruleName category batch
        , "--count"
        , show requested
        ]
          <> zapArguments
          <> [ruleName]
  processResult <-
    try (readProcessWithExitCode "generate-cbor" arguments "")
      :: IO (Either IOException (ExitCode, String, String))
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
      | Zap _ <- category
      , exhausted -> do
          when (length outputLines >= requested) $
            failGeneration $ ": invalid partial output for a batch of " <> show requested
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

addGeneratedLine :: FilePath -> String -> DatasetCategory -> (Int, Set.Set String) -> String -> IO (Int, Set.Set String)
addGeneratedLine categoryDir ruleName category (accepted, seen) encoded = do
  bytes <-
    case decodeHex encoded of
      Left message -> die $ message <> " for " <> ruleName <> "/" <> categoryName category
      Right value -> pure value
  let digest = sha256Hex bytes
  if Set.member digest seen
    then pure (accepted, seen)
    else do
      let next = accepted + 1
          fileName = printf "%05d-%s.cbor" next (take 16 digest)
          path = categoryDir </> fileName
      writeResult <- try (BS.writeFile path bytes) :: IO (Either IOException ())
      case writeResult of
        Left err -> die $ "cannot write '" <> path <> "': " <> show err
        Right () -> pure (next, Set.insert digest seen)

addCases :: FilePath -> EraSpec -> Integer -> RuleCheck -> DatasetCategory -> Int -> IO Int
addCases staging era topSeed rule category target = do
  let ruleName = ruleCheckName rule
      name = categoryName category
      categoryDir = staging </> ruleName </> name
      maxAttempts = 3 * target
      batchSize = 128
      finish accepted attempts batches exhaustions = do
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
        pure accepted
      loop :: Int -> Int -> Int -> Int -> Set.Set String -> IO Int
      loop accepted attempts batch exhaustions seen
        | accepted >= target || attempts >= maxAttempts = finish accepted attempts batch exhaustions
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
            (nextAccepted, nextSeen) <-
              foldM
                (addGeneratedLine categoryDir ruleName category)
                (accepted, seen)
                (batchLines result)
            loop
              nextAccepted
              (attempts + attempted)
              (batch + 1)
              (exhaustions + if batchExhausted result then 1 else 0)
              nextSeen
  createDirectoryIfMissing True categoryDir
  loop 0 0 0 0 Set.empty

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
  generated <- publishDirectory destination $ \staging -> do
    counts <- forM rules $ \rule ->
      forM datasetCategories $ \category -> do
        putStrLn $ "Generating " <> ruleCheckName rule <> "/" <> categoryName category
        addCases staging era topSeed rule category count
    pure $ sum $ concat counts

  let target = length rules * length datasetCategories * count
  putStrLn $ "Generated " <> show generated <> "/" <> show target <> " samples in " <> destination
