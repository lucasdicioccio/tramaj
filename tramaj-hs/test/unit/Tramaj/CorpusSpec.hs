-- | Runs the shared cross-implementation corpus at @corpus/cases@ (see
-- @corpus/README.md@), the counterpart of @tramaj/test/Test/Main.purs@'s
-- @runCorpus@. A case here is byte-equality between two independently
-- written implementations, not merely "this implementation agrees with
-- itself" -- see @roadmap-to-v4@ Phase 0.
module Tramaj.CorpusSpec (spec) where

import Control.Monad (filterM, forM)
import Data.Aeson (FromJSON (..), Value (..), eitherDecodeStrict, encode, withObject, (.:))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.List (isSuffixOf, sort)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesDirectoryExist, listDirectory, makeAbsolute)
import System.FilePath (dropExtension, takeFileName, (</>))
import Test.Hspec
import Tramaj.Eval (LibraryTable, Output (..), evalProgram)
import Tramaj.Node (nodeToJson)
import Tramaj.Parser (parseProgram)

data CaseMeta = CaseMeta
  { metaName :: Text
  , metaKind :: Text
  , metaMode :: Text
  }

instance FromJSON CaseMeta where
  parseJSON = withObject "meta.json" $ \o ->
    CaseMeta <$> o .: "name" <*> o .: "kind" <*> o .: "mode"

spec :: Spec
spec = do
  root <- runIO findCorpusRoot
  cases <- runIO (loadCaseDirs root)
  describe "shared corpus" $
    mapM_ (\dir -> it (takeFileName dir) (runCase dir)) cases

-- | The corpus lives at @corpus/cases@ relative to the repo root, but
-- @cabal test@'s working directory depends on how it is invoked -- walk
-- upward until it is found.
findCorpusRoot :: IO FilePath
findCorpusRoot = go "."
  where
    go dir = do
      let candidate = dir </> "corpus" </> "cases"
      found <- doesDirectoryExist candidate
      if found
        then pure candidate
        else do
          absHere <- makeAbsolute dir
          absUp <- makeAbsolute (dir </> "..")
          if absHere == absUp
            then error "could not locate corpus/cases above the test working directory"
            else go (dir </> "..")

loadCaseDirs :: FilePath -> IO [FilePath]
loadCaseDirs root = do
  entries <- listDirectory root
  dirs <- filterM (doesDirectoryExist . (root </>)) entries
  pure (sort (map (root </>) dirs))

readJsonFile :: (FromJSON a) => FilePath -> IO a
readJsonFile path = do
  bytes <- BS.readFile path
  either (\e -> error (path <> ": " <> e)) pure (eitherDecodeStrict bytes)

readLibs :: FilePath -> IO LibraryTable
readLibs dir = do
  let libsDir = dir </> "libs"
  exists <- doesDirectoryExist libsDir
  if not exists
    then pure Map.empty
    else do
      files <- filter (".tramaj" `isSuffixOf`) <$> listDirectory libsDir
      entries <- forM files $ \f -> do
        src <- TE.decodeUtf8 <$> BS.readFile (libsDir </> f)
        let name = T.pack (dropExtension f)
        case parseProgram src of
          Left e -> error (libsDir </> f <> ": parse error: " <> show e)
          Right prog -> pure (name, prog)
      pure (Map.fromList entries)

runCase :: FilePath -> Expectation
runCase dir = do
  meta <- (readJsonFile (dir </> "meta.json") :: IO CaseMeta)
  metaMode meta `shouldBe` "concrete" -- symbolic mode has no runner yet (roadmap-to-v4 Phase 2)
  src <- TE.decodeUtf8 <$> BS.readFile (dir </> "template.tramaj")
  ctx <- (readJsonFile (dir </> "ctx.json") :: IO Value)
  expected <- (readJsonFile (dir </> "expected.json") :: IO Value)
  libs <- readLibs dir
  let label = T.unpack (metaName meta)
  case parseProgram src of
    Left e -> expectationFailure (label <> ": parse error: " <> show e)
    Right prog -> case evalProgram libs ctx prog of
      Left e -> expectationFailure (label <> ": eval error: " <> show e)
      Right (ONode n) | metaKind meta == "document" ->
        encode (nodeToJson n) `shouldBe` (encode expected :: BL.ByteString)
      Right (OValue v) | metaKind meta == "expression" ->
        encode v `shouldBe` (encode expected :: BL.ByteString)
      Right (ONode _) -> expectationFailure (label <> ": expected a value, got a document")
      Right (OValue _) -> expectationFailure (label <> ": expected a document, got a value")
