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

import Data.Aeson (Value, object, (.=))
import Data.Aeson.Encode.Pretty (
  Config (confCompare, confIndent, confTrailingNewline),
  Indent (Spaces),
  defConfig,
  encodePretty',
 )
import qualified Data.Aeson.Key as Key
import qualified Data.ByteString.Builder as Builder
import Data.Monoid (Sum (..))
import Data.Text (Text)
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

outcomeValue :: Outcome -> Value
outcomeValue outcome =
  object
    [ count "generated_total" generatedTotal
    , count "generated_decoded_reencoded_expected" generatedDecodedReencodedExpected
    , count "generated_decoded_reencoded_actual" generatedDecodedReencodedActual
    , count "generated_must_be_rejected_expected" generatedMustBeRejectedExpected
    , count "generated_must_be_rejected_actual" generatedMustBeRejectedActual
    , count "zap_must_be_rejected_expected" zapMustBeRejectedExpected
    , count "zap_must_be_rejected_actual" zapMustBeRejectedActual
    ]
  where
    count name field = name .= (getSum (field outcome) :: Int)

failureValue :: Failure -> Value
failureValue failure =
  object
    [ "sample" .= failureSample failure
    , "rule" .= failureRule failure
    , "class" .= failureClass failure
    , "reason" .= failureReason failure
    ]

-- | A run is successful only when nothing failed, so the flag is derived from
-- the failures rather than passed in beside them and able to disagree.
reportValue :: ConformanceReport -> Value
reportValue report =
  object
    [ "corpus" .= reportCorpus report
    , "protocol_version" .= reportProtocolVersion report
    , "successful" .= null (reportFailures report)
    , "totals" .= outcomeValue (reportTotals report)
    , "rules" .= object [Key.fromString name .= outcomeValue outcome | (name, outcome) <- reportRules report]
    , "failures" .= map failureValue (reportFailures report)
    ]

-- | The order a key is written in. A JSON object has no inherent order, so the
-- one the specification lists has to be imposed here or a reader would get
-- whatever the encoder's map iteration produced.
--
-- Keys the specification names come first, in its order; anything else, which
-- means the rule names under @rules@, follows in name order. The two never
-- collide, since no rule is called @corpus@ or @totals@.
keyOrder :: [Text]
keyOrder =
  [ "corpus"
  , "protocol_version"
  , "successful"
  , "totals"
  , "rules"
  , "failures"
  , "generated_total"
  , "generated_decoded_reencoded_expected"
  , "generated_decoded_reencoded_actual"
  , "generated_must_be_rejected_expected"
  , "generated_must_be_rejected_actual"
  , "zap_must_be_rejected_expected"
  , "zap_must_be_rejected_actual"
  , "sample"
  , "rule"
  , "class"
  , "reason"
  ]

compareKeys :: Text -> Text -> Ordering
compareKeys left right =
  case (rank left, rank right) of
    (Just a, Just b) -> compare a b
    (Just _, Nothing) -> LT
    (Nothing, Just _) -> GT
    (Nothing, Nothing) -> compare left right
  where
    rank key = lookup key $ zip keyOrder [0 :: Int ..]

-- | Indented, one field per line, with a trailing newline. A report is read and
-- diffed by people, and a whole corpus on one line is neither.
writeReport :: FilePath -> ConformanceReport -> IO ()
writeReport path report = do
  createDirectoryIfMissing True $ takeDirectory path
  withFile path WriteMode $ \handle -> do
    hSetBinaryMode handle True
    Builder.hPutBuilder handle . Builder.lazyByteString . encodePretty' configuration $ reportValue report
  where
    configuration =
      defConfig
        { confIndent = Spaces 2
        , confCompare = compareKeys
        , confTrailingNewline = True
        }
