module Main where

import Corpus (
  VerificationMode (..),
  emitExpectedDataset,
  generateDataset,
  verifyDataset,
 )
import Data.List (intercalate)
import LedgerRules (
  EraSpec,
  eraSpecName,
  lookupEra,
  ruleNames,
  supportedEraNames,
  supportedEras,
 )
import Options.Applicative (
  Parser,
  ParserInfo,
  ReadM,
  argument,
  command,
  customExecParser,
  eitherReader,
  fullDesc,
  header,
  help,
  helper,
  hsubparser,
  info,
  long,
  metavar,
  option,
  prefs,
  progDesc,
  showHelpOnEmpty,
  showHelpOnError,
  strArgument,
  (<**>),
 )

data Command
  = Generate EraSpec FilePath Integer Int
  | Verify EraSpec VerificationMode FilePath
  | EmitExpected EraSpec FilePath FilePath
  | ListEras
  | ListRules EraSpec

eraOption :: Parser EraSpec
eraOption =
  option
    (eitherReader lookupEra)
    (long "era" <> metavar "ERA" <> help ("Ledger era: " <> intercalate ", " supportedEraNames))

isAsciiDigit :: Char -> Bool
isAsciiDigit character = character >= '0' && character <= '9'

readNatural :: String -> Either String Integer
readNatural "0" = Right 0
readNatural raw@(first : _)
  | first /= '0' && all isAsciiDigit raw = Right $ read raw
readNatural _ = Left "expected a non-negative decimal integer without leading zeros"

seedReader :: ReadM Integer
seedReader = eitherReader readNatural

countReader :: ReadM Int
countReader = eitherReader $ \raw -> do
  count <- readNatural raw
  if count >= 1 && count <= 99999
    then Right $ fromInteger count
    else Left "expected an integer from 1 to 99999 without leading zeros"

datasetArgument :: Parser FilePath
datasetArgument = strArgument $ metavar "DATASET_DIR"

commandInfo :: String -> Parser a -> ParserInfo a
commandInfo description parser = info parser $ progDesc description

verifyRequestParser :: Parser (VerificationMode, FilePath)
verifyRequestParser =
  hsubparser $
    command
      "deserialize"
      (commandInfo "Check decoder acceptance only" $ (,) DeserializeOnly <$> datasetArgument)
      <> command
        "reserialize"
        (commandInfo "Require reserialization to equal each input" $ (,) CheckReserialization <$> datasetArgument)
      <> command
        "expected"
        ( commandInfo "Require reserialization to equal a reference tree" $
            ( (\dataset expected -> (CheckExpectedOutput expected, dataset))
                <$> datasetArgument
                <*> strArgument (metavar "EXPECTED_DIR")
            )
        )

commandParser :: Parser Command
commandParser =
  hsubparser $
    command
      "generate"
      ( commandInfo "Generate a deterministic CBOR corpus" $
          ( Generate
              <$> eraOption
              <*> strArgument (metavar "OUTPUT_DIR")
              <*> argument seedReader (metavar "SEED")
              <*> argument countReader (metavar "COUNT")
          )
      )
      <> command
        "verify"
        ( commandInfo "Verify a CBOR corpus" $
            ((\era (mode, dataset) -> Verify era mode dataset) <$> eraOption <*> verifyRequestParser)
        )
      <> command
        "emit-expected"
        ( commandInfo "Create a reference reserialization tree" $
            (EmitExpected <$> eraOption <*> datasetArgument <*> strArgument (metavar "OUTPUT_DIR"))
        )
      <> command
        "list-eras"
        (commandInfo "List supported ledger eras" $ pure ListEras)
      <> command
        "list-rules"
        (commandInfo "List rules supported for an era" $ ListRules <$> eraOption)

parserInfo :: ParserInfo Command
parserInfo =
  info
    (commandParser <**> helper)
    (fullDesc <> header "Cardano ledger CBOR corpus generator and verifier")

runCommand :: Command -> IO ()
runCommand (Generate era outputDir seed count) = generateDataset era outputDir seed count
runCommand (Verify era mode datasetDir) = verifyDataset era mode datasetDir
runCommand (EmitExpected era datasetDir outputDir) = emitExpectedDataset era datasetDir outputDir
runCommand ListEras = mapM_ (putStrLn . eraSpecName) supportedEras
runCommand (ListRules era) = mapM_ putStrLn $ ruleNames era

main :: IO ()
main =
  customExecParser (prefs $ showHelpOnError <> showHelpOnEmpty) parserInfo
    >>= runCommand
