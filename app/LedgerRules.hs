{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module LedgerRules (
  RuleCheck,
  ruleCheckName,
  deserializeRule,
  reserializeRule,
  EraSpec,
  eraSpecName,
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

data RuleCheck = RuleCheck
  { ruleCheckName :: !String
  , deserializeRule :: BS.ByteString -> Either String ()
  , reserializeRule :: BS.ByteString -> Either String BS.ByteString
  }

mkRuleCheck :: forall a. (DecCBOR a, EncCBOR a) => Version -> String -> RuleCheck
mkRuleCheck version name =
  RuleCheck
    { ruleCheckName = name
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
  , eraSpecRules :: ![RuleCheck]
  }

supportedEras :: [EraSpec]
supportedEras =
  [ EraSpec "conway" conwayRuleChecks
  , EraSpec "dijkstra" dijkstraRuleChecks
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
