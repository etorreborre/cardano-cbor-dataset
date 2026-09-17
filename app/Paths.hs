{-# LANGUAGE ScopedTypeVariables #-}

-- | Filesystem checks shared by the commands that read or publish trees of
-- CBOR files. Every check refuses symbolic links, so a corpus cannot smuggle
-- reads or writes outside the directory it names.
module Paths (
  listDirectoryChecked,
  publishDirectory,
  requireCBORFile,
  requireRealDirectory,
) where

import Control.Exception (IOException, onException, try)
import Data.List (sort)
import System.Directory (listDirectory, makeAbsolute, removePathForcibly, renameDirectory)
import System.Exit (die)
import System.FilePath (isAbsolute, takeDirectory, takeExtension, takeFileName)
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

-- | 'Nothing' when the path does not exist; any other failure to inspect it is
-- fatal, since carrying on would treat an unreadable path as an absent one.
--
-- This stats the link itself rather than following it, which is what lets every
-- check below refuse a symbolic link instead of silently reporting on whatever
-- it points at.
pathStatus :: FilePath -> IO (Maybe FileStatus)
pathStatus path = do
  result <- try $ getSymbolicLinkStatus path
  case result of
    Left (err :: IOException)
      | isDoesNotExistError err -> pure Nothing
      | otherwise -> die $ "cannot inspect path '" <> path <> "': " <> show err
    Right status -> pure $ Just status

-- | A relative path is resolved against the working directory, which is rarely
-- the one the caller had in mind when the process runs somewhere else, such as
-- inside a container. Name both spellings so the mismatch is visible.
describePath :: FilePath -> IO String
describePath path
  | isAbsolute path = pure path
  | otherwise = do
      absolute <- makeAbsolute path
      pure $ path <> " (resolved to " <> absolute <> ")"

-- | Exit unless the path is a directory and not a symbolic link. The
-- description names the role the caller expects of it, such as @\"dataset
-- directory\"@, and is what the reader sees in the failure.
requireRealDirectory :: String -> FilePath -> IO ()
requireRealDirectory description path = do
  status <- pathStatus path
  case status of
    Nothing -> do
      located <- describePath path
      die $ "missing " <> description <> ": " <> located
    Just entry
      | isSymbolicLink entry -> die $ description <> " must not be a symbolic link: " <> path
      | isDirectory entry -> pure ()
      | otherwise -> die $ "expected " <> description <> ": " <> path

-- | Exit if anything at all occupies the path. Generation and publication both
-- write whole trees, so refusing up front is what keeps a second run from
-- merging into the output of the first.
requireAbsentPath :: FilePath -> IO ()
requireAbsentPath path = do
  status <- pathStatus path
  case status of
    Nothing -> pure ()
    Just _ -> die $ "output path already exists: " <> path

-- | Exit unless the path is a regular @.cbor@ file and not a symbolic link.
requireCBORFile :: FilePath -> IO ()
requireCBORFile path = do
  status <- pathStatus path
  case status of
    Just entry
      | isSymbolicLink entry -> die $ "dataset files must not be symbolic links: " <> path
      | isRegularFile entry && takeExtension path == ".cbor" -> pure ()
    _ -> die $ "expected a .cbor dataset file: " <> path

-- | Entry names in one directory, sorted. Readdir order is filesystem defined,
-- so sorting is what makes a corpus walk produce the same sequence, and so the
-- same file numbering and the same summaries, on every machine.
listDirectoryChecked :: FilePath -> IO [FilePath]
listDirectoryChecked directory = do
  entriesResult <- try (listDirectory directory) :: IO (Either IOException [FilePath])
  case entriesResult of
    Left err -> die $ "cannot list directory '" <> directory <> "': " <> show err
    Right entries -> pure $ sort entries

-- | Remove a staging tree, ignoring any failure to do so. This only runs while
-- unwinding from an earlier error, and that error is the one worth reporting.
cleanupDirectory :: FilePath -> IO ()
cleanupDirectory path = do
  _ <- try (removePathForcibly path) :: IO (Either IOException ())
  pure ()

-- | Build the destination in a sibling staging tree and move it into place, so
-- an interrupted run never leaves a half-written directory at the final path.
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
