-- | Runs the shared cross-implementation corpus at @corpus/cases@ (see
-- @corpus/README.md@), the counterpart of @tramaj/test/Test/Main.purs@'s
-- @runCorpus@. A case here is byte-equality between two independently
-- written implementations, not merely "this implementation agrees with
-- itself" -- see @roadmap-to-v4@ Phase 0.
module Tramaj.CorpusSpec (spec) where

import Control.Monad (filterM, forM)
import Data.Aeson (FromJSON (..), eitherDecodeStrict, withObject, (.:), (.:?))
import qualified Data.ByteString as BS
import Data.List (isSuffixOf, sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (canonicalizePath, doesDirectoryExist, listDirectory)
import System.FilePath (dropExtension, takeFileName, (</>))
import Test.Hspec
import Tramaj.Eval (EvalError, LibraryTable, Mode (..), runProgram)
import Tramaj.Json (Json, jsonParser, stringify)
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
  , metaRequires :: [Text]
  }

instance FromJSON CaseMeta where
  parseJSON = withObject "meta.json" $ \o ->
    CaseMeta <$> o .: "name" <*> o .: "mode"
      <*> (fromMaybe "success" <$> o .:? "expect")
      <*> o .:? "errorKind"
      <*> (fromMaybe [] <$> o .:? "requires")

-- | The requirement names (@requires@ in @meta.json@, see
-- @corpus/README.md@) this port declares. A case naming any other one is
-- skipped. @int-float@: integers and floats are two types. @int64@: an
-- integer covers the signed 64-bit range. The arithmetic builtins are not
-- implemented, so a case that also names @arithmetic@ stays skipped.
supportedRequirements :: [Text]
supportedRequirements = ["int-float", "int64"]

-- | The requirements a case names that this port does not declare.
missingRequirements :: CaseMeta -> [Text]
missingRequirements = filter (`notElem` supportedRequirements) . metaRequires

-- | What 'checkCase' did with a case. A failing case throws instead.
data Outcome
  = Passed
  | -- | Not run: the case names these requirements, which this port does
    -- not declare.
    Skipped [Text]
  deriving (Eq, Show)

spec :: Spec
spec = do
  root <- runIO findCorpusRoot
  cases <- runIO (loadCaseDirs root)
  describe "shared corpus" $
    mapM_ (\dir -> it (takeFileName dir) (runCase dir)) cases
  describe "a case naming an undeclared requirement" $
    -- corpus/runner-checks/unsupported-requirement would fail if it ran: its
    -- expected.json does not match what the template evaluates to.
    it "is skipped" $
      checkCase (root </> ".." </> "runner-checks" </> "unsupported-requirement")
        `shouldReturn` Skipped ["never-declared"]

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
          -- `makeAbsolute` only prepends the cwd and normalises separators;
          -- it does not collapse `..` segments, so comparing its output
          -- against one accumulated `..` deeper never converges and this
          -- loop spun forever once corpus/cases was unreachable (e.g.
          -- running the test suite from a standalone sdist, which does not
          -- include the repo-root corpus/ directory). `canonicalizePath`
          -- resolves `..` (and symlinks) against the real filesystem, so
          -- `absHere == absUp` actually fires at the real root.
          absHere <- canonicalizePath dir
          absUp <- canonicalizePath (dir </> "..")
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

-- | Reads @ctx.json@ or @expected.json@ with the reader that types a number
-- by its text (@corpus/README.md@): @3@ is an integer and @3.0@ a float, and
-- an integer keeps its digits whatever its size. aeson's own decoder would
-- make the two one number, and no fixture could then catch a result of the
-- wrong type.
readTypedJsonFile :: FilePath -> IO Json
readTypedJsonFile path = do
  bytes <- BS.readFile path
  either (\e -> error (path <> ": " <> e)) pure (jsonParser (TE.decodeUtf8 bytes))

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

-- | A skipped case is reported as pending, which hspec counts and prints
-- apart from the passed ones.
runCase :: FilePath -> Expectation
runCase dir = do
  outcome <- checkCase dir
  case outcome of
    Passed -> pure ()
    Skipped missing -> pendingWith ("requires " <> T.unpack (T.intercalate ", " missing))

checkCase :: FilePath -> IO Outcome
checkCase dir = do
  meta <- (readJsonFile (dir </> "meta.json") :: IO CaseMeta)
  case missingRequirements meta of
    [] -> Passed <$ checkSupportedCase dir meta
    missing -> pure (Skipped missing)

checkSupportedCase :: FilePath -> CaseMeta -> Expectation
checkSupportedCase dir meta = do
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
        ctx <- readTypedJsonFile (dir </> "ctx.json")
        case parseProgram src of
          Left e -> expectationFailure (label <> ": parse error: " <> show e)
          -- 'runProgram', as for a success case and as corpus/README.md says
          -- of @mode@: in symbolic mode it also builds the envelope's
          -- @"types"@ table, which is where an annotation naming an
          -- undeclared type is refused. Every error 'evalProgram' raises is
          -- raised first by 'runProgram'.
          Right prog -> case runProgram mode libs ctx prog of
            Right _ -> expectationFailure (label <> ": expected eval error " <> T.unpack errorKind <> ", but evaluation succeeded")
            Left e ->
              let actualKind = errorConstructor e
               in if actualKind == errorKind
                    then pure ()
                    else expectationFailure (label <> ": expected eval error " <> T.unpack errorKind <> ", got " <> T.unpack actualKind <> " (" <> show e <> ")")
    "success" -> do
      ctx <- readTypedJsonFile (dir </> "ctx.json")
      expected <- readTypedJsonFile (dir </> "expected.json")
      case parseProgram src of
        Left e -> expectationFailure (label <> ": parse error: " <> show e)
        Right prog -> case runProgram mode libs ctx prog of
          Left e -> expectationFailure (label <> ": eval error: " <> show e)
          -- Typed values, so an integer @1@ against an expected float @1.0@
          -- is a failure: the text of every number is compared, up to the
          -- spelling of one value of one type (@1.0@ and @1e0@ are the same
          -- float). Object key order is not compared.
          --
          -- The result goes through the writer and the reader first, since
          -- the text is what a host receives: a float written without its
          -- fraction would read back as an integer and fail here.
          Right actual -> jsonParser (stringify actual) `shouldBe` Right expected
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
