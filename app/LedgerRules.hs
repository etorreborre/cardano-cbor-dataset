{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module LedgerRules (
  RuleCheck,
  ruleCheckByteExact,
  ruleCheckName,
  deserializeRule,
  reserializeRule,
  EraSpec,
  eraSpecName,
  eraSpecProtocolVersion,
  eraSpecRules,
  supportedEras,
  supportedEraNames,
  lookupEra,
  ruleNames,
  lookupRule,
) where

import Cardano.Ledger.Allegra.Scripts (Timelock)
import Cardano.Ledger.Alonzo.Scripts (AlonzoEraScript (PlutusPurpose), AsIx, CostModels)
import Cardano.Ledger.Alonzo.TxWits (Redeemers)
import Cardano.Ledger.Binary (
  DecCBOR (decCBOR),
  DecCBORGroup (decCBORGroup),
  EncCBOR (encCBOR),
  EncCBORGroup (encCBORGroup),
  Version,
  decodeFull',
  decodeRecordNamed,
  encodeListLen,
  getVersion64,
  serialize',
 )
import Cardano.Ledger.Block (Block)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Governance (
  GovAction,
  ProposalProcedure,
  VotingProcedure,
  VotingProcedures,
 )
import Cardano.Ledger.Core (
  BlockBody,
  NativeScript,
  PParamsUpdate,
  Script,
  SubTx,
  TopTx,
  Tx,
  TxAuxData,
  TxBody,
  TxCert,
  TxOut,
  TxWits,
  Value,
  eraProtVerHigh,
 )
import Cardano.Ledger.Credential (Credential)
import Cardano.Ledger.Dijkstra (DijkstraEra)
import Cardano.Ledger.Dijkstra.Scripts (AccountBalanceInterval, AccountBalanceIntervals)
import Cardano.Ledger.DRep (DRep)
import Cardano.Ledger.Keys (KeyRole (Staking))
import Cardano.Ledger.Plutus.Data (Data, Datum)
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Ledger.State (StakePoolRelay)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Protocol.Crypto (StandardCrypto)
import Cardano.Protocol.TPraos.BlockHeader (BHBody, BHeader)
import qualified Data.ByteString as BS
import Data.List (find, intercalate)
import Data.OSet.Strict (OSet)
import Test.Cardano.Ledger.Conway.Binary.Annotator ()
import Test.Cardano.Ledger.Core.Binary.Annotator ()
import Test.Cardano.Ledger.Dijkstra.Binary.Annotator ()
import Test.Cardano.Protocol.Binary.Annotator ()

data ConwaySingleRedeemer = ConwaySingleRedeemer
  !(PlutusPurpose AsIx ConwayEra)
  !(Data ConwayEra)
  !ExUnits

instance DecCBOR ConwaySingleRedeemer where
  decCBOR =
    decodeRecordNamed "Redeemer" (const 4) $
      ConwaySingleRedeemer <$> decCBORGroup <*> decCBOR <*> decCBOR

instance EncCBOR ConwaySingleRedeemer where
  encCBOR (ConwaySingleRedeemer purpose redeemerData exUnits) =
    encodeListLen 4
      <> encCBORGroup purpose
      <> encCBOR redeemerData
      <> encCBOR exUnits

decodeAs :: forall a b. DecCBOR a => Version -> (a -> b) -> BS.ByteString -> Either String b
decodeAs version transform bytes =
  case decodeFull' version bytes of
    Left err -> Left $ show err
    Right (value :: a) -> Right $ transform value

-- | Rules whose own bytes are a hash preimage. For those the encoding is part
-- of the format, since a different encoding is a different hash, so re-encoding
-- one of these samples must reproduce the original bytes exactly rather than
-- merely agree with them after normalization.
--
-- A rule belongs here only when the bytes of the item this rule encodes are
-- themselves hashed. Containing something that is hashed is not enough: a
-- @script@ is a tag beside a payload and a @datum_option@ selects between a
-- hash and an inline value, so what gets hashed is the payload, encoded by its
-- own rule, and the selector around it is free to be re-encoded. @cost_models@
-- is the case worth remembering, because its bytes genuinely do reach a hash,
-- but as the @language_views@ embedding inside the script integrity hash rather
-- than as the protocol-parameter map this rule encodes.
--
-- The ledger settles it for each type. A type built on @MemoBytes@ keeps the
-- bytes it decoded and re-emits them verbatim, since @encCBOR@ for a
-- @MemoBytes@ is @encodePreEncoded@ over the stored bytes, and a hash needs
-- exactly that. Everything else builds a fresh encoding, so a sample whose
-- original container form differs from the one the encoder writes cannot be
-- reproduced by anyone, and listing such a rule would demand the impossible.
--
-- @block@, @header_body@ and @transaction@ are the near misses: each wraps
-- memoized contents in a record it rebuilds on encode, so the parts keep their
-- bytes while the wrapper does not.
byteExactRuleNames :: [String]
byteExactRuleNames =
  [ "auxiliary_data"
  , "header"
  , "native_script"
  , "plutus_data"
  , "redeemers"
  , "transaction_body"
  , "transaction_witness_set"
  ]

data RuleCheck = RuleCheck
  { ruleCheckName :: !String
  , ruleCheckByteExact :: !Bool
  , deserializeRule :: BS.ByteString -> Either String ()
  , reserializeRule :: BS.ByteString -> Either String BS.ByteString
  }

mkRuleCheck :: forall a. (DecCBOR a, EncCBOR a) => Version -> String -> RuleCheck
mkRuleCheck version name =
  RuleCheck
    { ruleCheckName = name
    , ruleCheckByteExact = name `elem` byteExactRuleNames
    , deserializeRule = decodeAs @a version $ const ()
    , reserializeRule = decodeAs @a version $ serialize' version
    }

conwayRuleChecks :: [RuleCheck]
conwayRuleChecks =
  let version = eraProtVerHigh @ConwayEra
   in [ mkRuleCheck @(Block (BHeader StandardCrypto) ConwayEra) version "block"
      , mkRuleCheck @(BHeader StandardCrypto) version "header"
      , mkRuleCheck @(BHBody StandardCrypto) version "header_body"
      , mkRuleCheck @(Tx TopTx ConwayEra) version "transaction"
      , mkRuleCheck @(TxBody TopTx ConwayEra) version "transaction_body"
      , mkRuleCheck @TxIn version "transaction_input"
      , mkRuleCheck @(TxWits ConwayEra) version "transaction_witness_set"
      , mkRuleCheck @(TxOut ConwayEra) version "transaction_output"
      , mkRuleCheck @(Value ConwayEra) version "value"
      , mkRuleCheck @(Script ConwayEra) version "script"
      , mkRuleCheck @(Datum ConwayEra) version "datum_option"
      , mkRuleCheck @(TxCert ConwayEra) version "certificate"
      , mkRuleCheck @(Timelock ConwayEra) version "native_script"
      , mkRuleCheck @(Data ConwayEra) version "plutus_data"
      , mkRuleCheck @ConwaySingleRedeemer version "redeemer"
      , mkRuleCheck @(Redeemers ConwayEra) version "redeemers"
      , mkRuleCheck @(TxAuxData ConwayEra) version "auxiliary_data"
      , mkRuleCheck @(Credential Staking) version "credential"
      , mkRuleCheck @DRep version "drep"
      , mkRuleCheck @StakePoolRelay version "relay"
      , mkRuleCheck @(GovAction ConwayEra) version "gov_action"
      , mkRuleCheck @(VotingProcedure ConwayEra) version "voting_procedure"
      , mkRuleCheck @(ProposalProcedure ConwayEra) version "proposal_procedure"
      , mkRuleCheck @(PParamsUpdate ConwayEra) version "protocol_param_update"
      , mkRuleCheck @CostModels version "cost_models"
      ]

dijkstraRuleChecks :: [RuleCheck]
dijkstraRuleChecks =
  let version = eraProtVerHigh @DijkstraEra
   in [ mkRuleCheck @(Block (BHeader StandardCrypto) DijkstraEra) version "block"
      , mkRuleCheck @(BHeader StandardCrypto) version "header"
      , mkRuleCheck @(BHBody StandardCrypto) version "header_body"
      , mkRuleCheck @(BlockBody DijkstraEra) version "block_body"
      , mkRuleCheck @(Tx TopTx DijkstraEra) version "transaction"
      , mkRuleCheck @(TxBody TopTx DijkstraEra) version "transaction_body"
      , mkRuleCheck @(TxBody SubTx DijkstraEra) version "sub_transaction_body"
      , mkRuleCheck @TxIn version "transaction_input"
      , mkRuleCheck @(TxWits DijkstraEra) version "transaction_witness_set"
      , mkRuleCheck @(TxOut DijkstraEra) version "transaction_output"
      , mkRuleCheck @(Value DijkstraEra) version "value"
      , mkRuleCheck @(Script DijkstraEra) version "script"
      , mkRuleCheck @(Datum DijkstraEra) version "datum_option"
      , mkRuleCheck @(TxCert DijkstraEra) version "certificate"
      , mkRuleCheck @(OSet (TxCert DijkstraEra)) version "certificates"
      , mkRuleCheck @(NativeScript DijkstraEra) version "native_script"
      , mkRuleCheck @(Data DijkstraEra) version "plutus_data"
      , mkRuleCheck @(Redeemers DijkstraEra) version "redeemers"
      , mkRuleCheck @(TxAuxData DijkstraEra) version "auxiliary_data"
      , mkRuleCheck @(Credential Staking) version "credential"
      , mkRuleCheck @DRep version "drep"
      , mkRuleCheck @StakePoolRelay version "relay"
      , mkRuleCheck @(GovAction DijkstraEra) version "gov_action"
      , mkRuleCheck @(VotingProcedure DijkstraEra) version "voting_procedure"
      , mkRuleCheck @(VotingProcedures DijkstraEra) version "voting_procedures"
      , mkRuleCheck @(ProposalProcedure DijkstraEra) version "proposal_procedure"
      , mkRuleCheck @(OSet (ProposalProcedure DijkstraEra)) version "proposal_procedures"
      , mkRuleCheck @(PParamsUpdate DijkstraEra) version "protocol_param_update"
      , mkRuleCheck @CostModels version "cost_models"
      , mkRuleCheck @(AccountBalanceInterval DijkstraEra) version "account_balance_interval"
      , mkRuleCheck @(AccountBalanceIntervals DijkstraEra) version "account_balance_intervals"
      ]

data EraSpec = EraSpec
  { eraSpecName :: !String
  , -- | The protocol version the era's decoders run at, as a conformance
    -- report spells it. Taken from the ledger rather than written out here, so
    -- a report cannot claim a version the samples were not decoded against.
    eraSpecProtocolVersion :: !String
  , eraSpecRules :: ![RuleCheck]
  }

protocolVersionName :: Version -> String
protocolVersionName version = show (getVersion64 version) <> ".0"

supportedEras :: [EraSpec]
supportedEras =
  [ EraSpec "conway" (protocolVersionName $ eraProtVerHigh @ConwayEra) conwayRuleChecks
  , EraSpec "dijkstra" (protocolVersionName $ eraProtVerHigh @DijkstraEra) dijkstraRuleChecks
  ]

supportedEraNames :: [String]
supportedEraNames = map eraSpecName supportedEras

lookupNamed :: String -> (a -> String) -> [a] -> String -> Either String a
lookupNamed description getName values requested =
  case find ((== requested) . getName) values of
    Just value -> Right value
    Nothing ->
      Left $
        "unknown "
          <> description
          <> " '"
          <> requested
          <> "': expected "
          <> intercalate ", " (map getName values)

lookupEra :: String -> Either String EraSpec
lookupEra = lookupNamed "era" eraSpecName supportedEras

ruleNames :: EraSpec -> [String]
ruleNames = map ruleCheckName . eraSpecRules

lookupRule :: EraSpec -> String -> Either String RuleCheck
lookupRule era = lookupNamed (eraSpecName era <> " rule") ruleCheckName (eraSpecRules era)
