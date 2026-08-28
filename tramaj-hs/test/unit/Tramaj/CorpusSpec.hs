-- | Runs the shared cross-implementation corpus at @corpus/cases@ (see
-- @corpus/README.md@), the counterpart of @tramaj/test/Test/Main.purs@'s
-- @runCorpus@. A case here is byte-equality between two independently
-- written implementations, not merely "this implementation agrees with
-- itself" -- see @roadmap-to-v4@ Phase 0.
module Tramaj.CorpusSpec (spec) where

import Control.Monad (filterM, forM)
import Data.Aeson (FromJSON (..), Value (..), eitherDecodeStrict, encode, withObject, (.:), (.:?))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.List (isSuffixOf, sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (doesDirectoryExist, listDirectory, makeAbsolute)
import System.FilePath (dropExtension, takeFileName, (</>))
import Test.Hspec
import Tramaj.Eval (EvalError, LibraryTable, Mode (..), evalProgram, runProgram)
import Tramaj.Parser (parseProgram)

-- | `"kind"` is part of the format (corpus/README.md) but not read here: a
-- successful run's shape is checked by comparing against @expected.json@
-- wholesale, via 'runProgram', which already reflects the mode and (once §4
-- lands) the kind in what it produces.
data CaseMeta = CaseMeta
  { metaName :: Text
  , metaMode :: Text
  , metaExpect :: Text
  , metaErrorKind :: Maybe Text
  }

instance FromJSON CaseMeta where
  parseJSON = withObject "meta.json" $ \o ->
    CaseMeta <$> o .: "name" <*> o .: "mode"
      <*> (fromMaybe "success" <$> o .:? "expect")
      <*> o .:? "errorKind"

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

modeFromMeta :: FilePath -> Text -> IO Mode
modeFromMeta dir m = case m of
  "concrete" -> pure Concrete
  "symbolic" -> pure Symbolic
  other -> error (dir <> ": unknown mode " <> T.unpack other)

runCase :: FilePath -> Expectation
runCase dir = do
  meta <- (readJsonFile (dir </> "meta.json") :: IO CaseMeta)
  mode <- modeFromMeta dir (metaMode meta)
  src <- TE.decodeUtf8 <$> BS.readFile (dir </> "template.tramaj")
  libs <- readLibs dir
  let label = T.unpack (metaName meta)
  case metaExpect meta of
    "parse-error" -> case parseProgram src of
      Left _ -> pure ()
      Right _ -> expectationFailure (label <> ": expected a parse error, but the template parsed")
    "eval-error" -> case metaErrorKind meta of
      Nothing -> expectationFailure (label <> ": eval-error case needs errorKind")
      Just errorKind -> do
        ctx <- (readJsonFile (dir </> "ctx.json") :: IO Value)
        case parseProgram src of
          Left e -> expectationFailure (label <> ": parse error: " <> show e)
          Right prog -> case evalProgram mode libs ctx prog of
            Right _ -> expectationFailure (label <> ": expected eval error " <> T.unpack errorKind <> ", but evaluation succeeded")
            Left e ->
              let actualKind = errorConstructor e
               in if actualKind == errorKind
                    then pure ()
                    else expectationFailure (label <> ": expected eval error " <> T.unpack errorKind <> ", got " <> T.unpack actualKind <> " (" <> show e <> ")")
    "success" -> do
      ctx <- (readJsonFile (dir </> "ctx.json") :: IO Value)
      expected <- (readJsonFile (dir </> "expected.json") :: IO Value)
      case parseProgram src of
        Left e -> expectationFailure (label <> ": parse error: " <> show e)
        Right prog -> case runProgram mode libs ctx prog of
          Left e -> expectationFailure (label <> ": eval error: " <> show e)
          Right actual -> encode actual `shouldBe` (encode expected :: BL.ByteString)
    other -> expectationFailure (label <> ": unknown expect " <> T.unpack other)

-- | The constructor name an 'EvalError''s 'Show' instance leads with -- every
-- constructor is written as @Name arg1 arg2 ...@, so the first
-- whitespace-delimited word is unambiguous. Kept to this rather than a
-- dedicated projection so a new 'EvalError' constructor needs no matching
-- addition here.
errorConstructor :: EvalError -> Text
errorConstructor e = case T.words (T.pack (show e)) of
  (w : _) -> w
  [] -> ""
