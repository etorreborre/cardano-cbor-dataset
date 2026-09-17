-- | Check the committed normalization vectors against the reference
-- implementation.
--
-- The vectors are a specification artifact: their hex table was verified by
-- hand, so this test asks whether the implementation still agrees with the
-- specification, not whether the vectors match whatever the implementation
-- currently does. A failure means one of the two has moved and the other has
-- not, and the table in the vector directory's README is the authority.
module Main (main) where

import Control.Monad (forM, unless)
import qualified Data.ByteString as BS
import Data.List (isSuffixOf, sort)
import Normalize (normalizeBytes)
import System.Directory (doesFileExist, listDirectory)
import System.Environment (getArgs)
import System.Exit (die, exitFailure)
import System.FilePath ((</>))
import Text.Printf (printf)

inputSuffix :: String
inputSuffix = ".in.cbor"

outputSuffix :: String
outputSuffix = ".out.cbor"

-- | Hex, so a mismatch can be read straight against the README's table without
-- reaching for another tool.
hex :: BS.ByteString -> String
hex = concatMap (printf "%02x") . BS.unpack

data Outcome = Passed | Failed !String

checkVector :: FilePath -> String -> IO Outcome
checkVector directory name = do
  let outputPath = directory </> name <> outputSuffix
  hasOutput <- doesFileExist outputPath
  if not hasOutput
    then pure . Failed $ "no " <> name <> outputSuffix <> " beside the input"
    else do
      input <- BS.readFile $ directory </> name <> inputSuffix
      expected <- BS.readFile outputPath
      pure $ case normalizeBytes input of
        Left message -> Failed message
        Right actual
          | actual == expected -> Passed
          | otherwise -> Failed $ "got " <> hex actual <> ", want " <> hex expected

-- | An output with no input is as much a problem as a mismatch: it means a case
-- was half removed, and the run would otherwise look clean while testing less
-- than the table claims.
orphanedOutputs :: [FilePath] -> [String]
orphanedOutputs entries =
  sort [name | entry <- entries, Just name <- [stripSuffix outputSuffix entry], name `notElem` inputs]
  where
    inputs = [name | entry <- entries, Just name <- [stripSuffix inputSuffix entry]]

stripSuffix :: String -> String -> Maybe String
stripSuffix suffix name
  | suffix `isSuffixOf` name = Just $ take (length name - length suffix) name
  | otherwise = Nothing

main :: IO ()
main = do
  arguments <- getArgs
  let directory = case arguments of
        (path : _) -> path
        [] -> "normalization-vectors"
  entries <- listDirectory directory
  let names = sort [name | entry <- entries, Just name <- [stripSuffix inputSuffix entry]]
      orphans = orphanedOutputs entries
  unless (null orphans) $
    die $ "outputs with no input in '" <> directory <> "': " <> show orphans
  if null names
    then die $ "no vectors in '" <> directory <> "'"
    else do
      outcomes <- forM names $ \name -> do
        outcome <- checkVector directory name
        case outcome of
          Passed -> putStrLn $ "ok    " <> name
          Failed message -> putStrLn $ "FAIL  " <> name <> " (" <> message <> ")"
        pure outcome
      let failed = length [() | Failed _ <- outcomes]
      printf "\n%d passed, %d failed\n" (length outcomes - failed) failed
      unless (failed == 0) exitFailure
