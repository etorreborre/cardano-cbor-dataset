{-# LANGUAGE LambdaCase #-}

-- | CBOR normalization.
--
-- Rewrite a CBOR item into the one encoding of itself that every conforming
-- implementation can agree on, without touching what it says. @generate@
-- applies this to every reference encoding it writes, and @verify@ applies it
-- to its own reserialization before comparing the two.
--
-- CDDL accepts both definite- and indefinite-length containers for the same
-- type, so the container form an encoder picks is not part of the format.
-- Comparing bytes against a reference therefore forces other implementations
-- to reproduce one encoder's arbitrary choices. Normalizing both sides removes
-- that, and only that: map key order, duplicate keys, tags, float widths and
-- every integer value survive untouched, so a decoder that reads the wrong
-- thing still fails the comparison.
module Normalize (
  normalizeBytes,
  normalizeShape,
) where

import Codec.CBOR.Read (deserialiseFromBytes)
import Codec.CBOR.Term (Term (..), decodeTerm, encodeTerm)
import Codec.CBOR.Write (toStrictByteString)
import Control.Monad (unless)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Text.Lazy as TL

-- | Collapse every indefinite-length construct, applied recursively. Chunked
-- strings become one definite string. Integer, tag and length heads are
-- minimised by re-encoding the term.
--
-- Bignum folding is part of that re-encoding rather than a case below. @cborg@
-- types the @#6.2@ and @#6.3@ headers as integers rather than as tags, so a
-- bignum arrives here as a plain 'TInteger' with any leading zero bytes already
-- gone, and is written back out with a native @uint@ or @nint@ head when the
-- magnitude fits one, as a minimal bignum when it does not.
normalizeShape :: Term -> Term
normalizeShape = \case
  TList items -> TList $ map normalizeShape items
  TListI items -> TList $ map normalizeShape items
  TMap entries -> TMap $ normalizeEntries entries
  TMapI entries -> TMap $ normalizeEntries entries
  TBytesI chunks -> TBytes $ BSL.toStrict chunks
  TStringI chunks -> TString $ TL.toStrict chunks
  TTagged tag item -> TTagged tag $ normalizeShape item
  other -> other
 where
  normalizeEntries entries = [(normalizeShape key, normalizeShape value) | (key, value) <- entries]

decodeWholeTerm :: BS.ByteString -> Either String Term
decodeWholeTerm bytes =
  case deserialiseFromBytes decodeTerm $ BSL.fromStrict bytes of
    Left err -> Left $ "cannot decode CBOR: " <> show err
    Right (unconsumed, term)
      | BSL.null unconsumed -> Right term
      | otherwise -> Left $ show (BSL.length unconsumed) <> " trailing bytes after the top-level item"

encodeShape :: Term -> BS.ByteString
encodeShape = toStrictByteString . encodeTerm

-- | Normalize one encoded item, checking that the result is already normal.
--
-- The check is a guard against the encoder, not against the rewrite: if
-- @encodeTerm@ ever chose a form this module does not consider normal, such as
-- a bignum for an integer that fits a @uint@ head, the output would not be
-- reproducible by a consumer normalizing its own bytes, and the file is
-- reported as a failure instead of being silently written.
normalizeBytes :: BS.ByteString -> Either String BS.ByteString
normalizeBytes bytes = do
  term <- decodeWholeTerm bytes
  let normalized = encodeShape $ normalizeShape term
  reread <- decodeWholeTerm normalized
  unless (encodeShape (normalizeShape reread) == normalized) $
    Left "normalization is not idempotent for this item"
  pure normalized
