{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The conformance report a verification run publishes.
--
-- Node implementors publish this same shape from their own suites, so the
-- field names and their meaning are a contract with consumers of the dataset
-- rather than an internal detail. The README carries the specification; this
-- module is its one implementation, and the two must be changed together.
--
-- Fields are written in the order the specification lists them, and rules are
-- written in name order, so two reports for the same corpus diff cleanly.
module Report (
  ConformanceReport (..),
  Failure (..),
  Outcome (..),
  Reason,
  FailureKind (..),
  failureKindLabel,
  writeReport,
) where

import qualified Data.Aeson.Encoding as Encoding
import qualified Data.Aeson.Key as Key
import qualified Data.ByteString.Builder as Builder
import Data.List (sortOn)
import Data.Monoid (Sum (..))
import GHC.Generics (Generic, Generically (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import System.IO (IOMode (WriteMode), hSetBinaryMode, withFile)

-- | What one rule, or a whole corpus, was asked to do and what it did.
--
-- The fields are counters, so per-rule outcomes roll up into the totals by
-- 'mconcat' rather than by a hand-written sum. Deriving it means a new field
-- cannot be left out of the roll-up, which would show as totals quietly
-- disagreeing with the rules they are the sum of.
data Outcome = Outcome
  { generatedTotal :: !(Sum Int)
  , generatedDecodedReencodedExpected :: !(Sum Int)
  , generatedDecodedReencodedActual :: !(Sum Int)
  , generatedMustBeRejectedExpected :: !(Sum Int)
  , generatedMustBeRejectedActual :: !(Sum Int)
  , zapMustBeRejectedExpected :: !(Sum Int)
  , zapMustBeRejectedActual :: !(Sum Int)
  }
  deriving stock (Generic)
  deriving (Semigroup, Monoid) via Generically Outcome

data Failure = Failure
  { failureSample :: !String
  , failureRule :: !String
  , failureClass :: !String
  , failureReason :: !String
  }

-- | Why one sample failed. The report collapses a reason to a stable label, so
-- the label comes from the shape of the failure rather than from matching on
-- the message text, which is free to be reworded.
data FailureKind
  = DecodeFailed
  | DecodeSucceeded
  | ReferenceMismatch
  | ByteExactMismatch
  | ReferenceUnreadable
  | SampleUnreadable

failureKindLabel :: FailureKind -> String
failureKindLabel DecodeFailed = "decoding failed"
failureKindLabel DecodeSucceeded = "decoding succeeded but the sample must be rejected"
failureKindLabel ReferenceMismatch = "re-encoding differs from the cbor reference"
failureKindLabel ByteExactMismatch = "re-encoding differs from the original bytes"
failureKindLabel ReferenceUnreadable = "the cbor reference is missing or unreadable"
failureKindLabel SampleUnreadable = "the sample is unreadable"

-- | A failure kind and the full error text behind it.
type Reason = (FailureKind, String)

data ConformanceReport = ConformanceReport
  { reportCorpus :: !String
  , reportProtocolVersion :: !String
  , reportTotals :: !Outcome
  , reportRules :: ![(String, Outcome)]
  , reportFailures :: ![Failure]
  }

outcomeEncoding :: Outcome -> Encoding.Encoding
outcomeEncoding outcome =
  Encoding.pairs $
    count "generated_total" generatedTotal
      <> count "generated_decoded_reencoded_expected" generatedDecodedReencodedExpected
      <> count "generated_decoded_reencoded_actual" generatedDecodedReencodedActual
      <> count "generated_must_be_rejected_expected" generatedMustBeRejectedExpected
      <> count "generated_must_be_rejected_actual" generatedMustBeRejectedActual
      <> count "zap_must_be_rejected_expected" zapMustBeRejectedExpected
      <> count "zap_must_be_rejected_actual" zapMustBeRejectedActual
  where
    count name field = Encoding.pair name (Encoding.int . getSum $ field outcome)

failureEncoding :: Failure -> Encoding.Encoding
failureEncoding failure =
  Encoding.pairs $
    Encoding.pair "sample" (Encoding.string $ failureSample failure)
      <> Encoding.pair "rule" (Encoding.string $ failureRule failure)
      <> Encoding.pair "class" (Encoding.string $ failureClass failure)
      <> Encoding.pair "reason" (Encoding.string $ failureReason failure)

rulesEncoding :: [(String, Outcome)] -> Encoding.Encoding
rulesEncoding entries =
  Encoding.pairs $
    foldMap
      (\(name, outcome) -> Encoding.pair (Key.fromString name) (outcomeEncoding outcome))
      (sortOn fst entries)

-- | A run is successful only when nothing failed, so the flag is derived from
-- the failures rather than passed in beside them and able to disagree.
reportEncoding :: ConformanceReport -> Encoding.Encoding
reportEncoding report =
  Encoding.pairs $
    Encoding.pair "corpus" (Encoding.string $ reportCorpus report)
      <> Encoding.pair "protocol_version" (Encoding.string $ reportProtocolVersion report)
      <> Encoding.pair "successful" (Encoding.bool . null $ reportFailures report)
      <> Encoding.pair "totals" (outcomeEncoding $ reportTotals report)
      <> Encoding.pair "rules" (rulesEncoding $ reportRules report)
      <> Encoding.pair "failures" (Encoding.list failureEncoding $ reportFailures report)

writeReport :: FilePath -> ConformanceReport -> IO ()
writeReport path report = do
  createDirectoryIfMissing True $ takeDirectory path
  withFile path WriteMode $ \handle -> do
    hSetBinaryMode handle True
    Builder.hPutBuilder handle $
      Encoding.fromEncoding (reportEncoding report) <> Builder.char7 '\n'
