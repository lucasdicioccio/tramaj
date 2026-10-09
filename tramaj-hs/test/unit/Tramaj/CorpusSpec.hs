-- | Runs the shared cross-implementation corpus at @corpus/cases@ (see
-- @corpus/README.md@), the counterpart of @tramaj/test/Test/Main.purs@'s
-- @runCorpus@. A case here is byte-equality between two independently
-- written implementations, not merely "this implementation agrees with
-- itself" -- see @roadmap-to-v4@ Phase 0.
module Tramaj.CorpusSpec (spec) where

import Control.Monad (filterM, forM, forM_, when)
import Data.Aeson (FromJSON (..), eitherDecodeStrict, withObject, (.:), (.:?))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson (Parser)
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString as BS
import Data.List (isSuffixOf, sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.Directory (canonicalizePath, doesDirectoryExist, listDirectory)
import System.FilePath (dropExtension, takeFileName, (</>))
import Test.Hspec
import Tramaj.Analysis
  ( arithmeticOps
  , contextHoles
  , contextReads
  , deepActionKeys
  , deepArithmeticOps
  , deepContextHoles
  , staticActionKeys
  , staticImportNames
  , transitiveImportNames
  )
import Tramaj.Ast (Program)
import Tramaj.Eval (EvalError, LibraryTable, Mode (..), Options (..), defaultOptions, runProgramWith)
import Tramaj.Json (Json, jsonParser, stringify)
import Tramaj.Parser (parseProgram)

-- | `"kind"` is part of the format (corpus/README.md) but not read here: a
-- successful run's shape is checked by comparing against @expected.json@
-- wholesale, via 'runProgramWith', which already reflects the mode and (once §4
-- lands) the kind in what it produces.
data CaseMeta = CaseMeta
  { metaName :: Text
  , metaMode :: Maybe Text
  -- ^ Absent in an @"expect": "analysis"@ case, which evaluates nothing.
  , metaExpect :: Text
  , metaErrorKind :: Maybe Text
  , metaProfiles :: [Text]
  , metaHasRequires :: Bool
  -- ^ The key @profiles@ replaced. A case that still has it is refused
  -- rather than run without its gate.
  }

instance FromJSON CaseMeta where
  parseJSON = withObject "meta.json" $ \o ->
    CaseMeta <$> o .: "name" <*> o .:? "mode"
      <*> (fromMaybe "success" <$> o .:? "expect")
      <*> o .:? "errorKind"
      <*> (fromMaybe [] <$> o .:? "profiles")
      <*> (isJust <$> (o .:? "requires" :: Aeson.Parser (Maybe Aeson.Value)))

-- | The profiles (@profiles@ in @meta.json@, see @corpus/README.md@) this
-- port can provide. A case naming any other one is skipped. @base@: the
-- language without any profile. @int-float@: integers and floats are two
-- types (a transition tag, not a profile). @int64@: an integer covers the
-- signed 64-bit range, so not @int53@. @arithmetic@: the arithmetic profile,
-- which is an option of each evaluation here ('optionsFromMeta'). @sort@,
-- @format-number@ and @round@: transition tags for the two sort forms, the
-- @format-number@ builtin and the tenth arithmetic name (decisions \S20).
providedProfiles :: [Text]
providedProfiles = ["base", "int-float", "int64", "arithmetic", "sort", "format-number", "round"]

-- | The profiles every port provides (@corpus/README.md@). A case naming one
-- that 'providedProfiles' lacks fails instead of being skipped.
requiredProfiles :: [Text]
requiredProfiles = ["int-float", "arithmetic"]

-- | The profiles a case names that this port does not provide.
missingProfiles :: CaseMeta -> [Text]
missingProfiles = filter (`notElem` providedProfiles) . metaProfiles

-- | The result of a static analysis, in the two shapes @analysis.json@
-- holds: a set of names, or a set of paths.
data AnalysisResult
  = Names (Set Text)
  | Paths (Set [Text])
  deriving (Eq, Show)

-- | The static analyses (reference.md \S9) this port provides to an
-- @"expect": "analysis"@ case, by the name @analysis.json@ gives them. A case
-- naming any other one is skipped.
providedAnalyses :: Map.Map Text (LibraryTable -> Program -> AnalysisResult)
providedAnalyses =
  Map.fromList
    [ ("staticImportNames", \_ p -> Names (staticImportNames p))
    , ("transitiveImportNames", \libs p -> Names (transitiveImportNames libs p))
    , ("staticActionKeys", \_ p -> Names (staticActionKeys p))
    , ("deepActionKeys", \libs p -> Names (deepActionKeys libs p))
    , ("contextHoles", \_ p -> Paths (contextHoles p))
    , ("deepContextHoles", \libs p -> Paths (deepContextHoles libs p))
    , ("contextReads", \_ p -> Paths (contextReads p))
    , ("arithmeticOps", \_ p -> Names (arithmeticOps p))
    , ("deepArithmeticOps", \libs p -> Names (deepArithmeticOps libs p))
    ]

-- | What 'checkCase' did with a case. A failing case throws instead.
data Outcome
  = Passed
  | -- | Not run: the case names these profiles (or, written
    -- @analysis \<name\>@, these analyses), which this port does not provide.
    Skipped [Text]
  deriving (Eq, Show)

spec :: Spec
spec = do
  root <- runIO findCorpusRoot
  cases <- runIO (loadCaseDirs root)
  describe "shared corpus" $
    mapM_ (\dir -> it (takeFileName dir) (runCase dir)) cases
  describe "a case naming a profile this port does not provide" $
    -- corpus/runner-checks/unsupported-profile would fail if it ran: its
    -- expected.json does not match what the template evaluates to.
    it "is skipped" $
      checkCase (root </> ".." </> "runner-checks" </> "unsupported-profile")
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

modeFromMeta :: FilePath -> Maybe Text -> IO Mode
modeFromMeta dir m = case m of
  Just "concrete" -> pure Concrete
  Just "symbolic" -> pure Symbolic
  Just other -> error (dir <> ": unknown mode " <> T.unpack other)
  Nothing -> error (dir <> ": meta.json has no mode")

-- | The options a case runs with: its mode, and the arithmetic profile only
-- if it lists @arithmetic@ in @profiles@. Every other case runs with the
-- profile off, as a host that never asked for it does, so the ten
-- arithmetic names are unbound there.
optionsFromMeta :: FilePath -> CaseMeta -> IO Options
optionsFromMeta dir meta = do
  mode <- modeFromMeta dir (metaMode meta)
  pure defaultOptions {optMode = mode, optArithmetic = "arithmetic" `elem` metaProfiles meta}

-- | A skipped case is reported as pending, which hspec counts and prints
-- apart from the passed ones.
runCase :: FilePath -> Expectation
runCase dir = do
  outcome <- checkCase dir
  case outcome of
    Passed -> pure ()
    Skipped missing -> pendingWith ("not provided: " <> T.unpack (T.intercalate ", " missing))

checkCase :: FilePath -> IO Outcome
checkCase dir = do
  meta <- (readJsonFile (dir </> "meta.json") :: IO CaseMeta)
  when (metaHasRequires meta) $
    error (dir <> ": \"requires\" was replaced by \"profiles\" (corpus/README.md)")
  case filter (`elem` requiredProfiles) (missingProfiles meta) of
    [] -> pure ()
    required -> error (dir <> ": not provided, but required of every port: " <> T.unpack (T.intercalate ", " required))
  if metaExpect meta == "analysis"
    then do
      -- The names are the keys of @analysis.json@, which holds no number, so
      -- reading it before deciding to skip is safe on every port.
      expected <- (readJsonFile (dir </> "analysis.json") :: IO (Map.Map Text Aeson.Value))
      let missingAnalyses = filter (`Map.notMember` providedAnalyses) (Map.keys expected)
      case missingProfiles meta <> map ("analysis " <>) missingAnalyses of
        [] -> Passed <$ checkAnalysisCase dir meta expected
        missing -> pure (Skipped missing)
    else case missingProfiles meta of
      [] -> Passed <$ checkSupportedCase dir meta
      missing -> pure (Skipped missing)

-- | An @"expect": "analysis"@ case: no context and no evaluation. Each named
-- analysis runs over the parsed template (and @libs/@, for a deep variant)
-- and its result is compared, as a set, with the array @analysis.json@ gives.
checkAnalysisCase :: FilePath -> CaseMeta -> Map.Map Text Aeson.Value -> Expectation
checkAnalysisCase dir meta expected = do
  src <- TE.decodeUtf8 <$> BS.readFile (dir </> "template.tramaj")
  libs <- readLibs dir
  let label = T.unpack (metaName meta)
  case parseProgram src of
    Left e -> expectationFailure (label <> ": parse error: " <> show e)
    Right prog -> forM_ (Map.toList expected) $ \(key, value) ->
      case Map.lookup key providedAnalyses of
        Nothing -> expectationFailure (label <> ": unknown analysis " <> T.unpack key)
        Just analysis ->
          let actual = analysis libs prog
           in case decodeExpected actual value of
                Left e -> expectationFailure (label <> ": analysis.json: " <> T.unpack key <> ": " <> e)
                Right want -> (key, actual) `shouldBe` (key, want)
  where
    -- Decoded in the shape of the actual result, since @[]@ alone does not
    -- say which of the two it is. A repeated element is refused: the file is
    -- a set.
    decodeExpected :: AnalysisResult -> Aeson.Value -> Either String AnalysisResult
    decodeExpected (Names _) v = Names <$> (distinct =<< parseEither parseJSON v)
    decodeExpected (Paths _) v = Paths <$> (distinct =<< parseEither parseJSON v)

    distinct :: (Ord a) => [a] -> Either String (Set a)
    distinct xs =
      let set = Set.fromList xs
       in if Set.size set == length xs then Right set else Left "an element is repeated"

checkSupportedCase :: FilePath -> CaseMeta -> Expectation
checkSupportedCase dir meta = do
  options <- optionsFromMeta dir meta
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
          -- 'runProgramWith', as for a success case and as corpus/README.md
          -- says of @mode@: in symbolic mode it also builds the envelope's
          -- @"types"@ table, which is where an annotation naming an
          -- undeclared type is refused. Every error 'evalProgramWith' raises
          -- is raised first by 'runProgramWith'.
          Right prog -> case runProgramWith options libs ctx prog of
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
        Right prog -> case runProgramWith options libs ctx prog of
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
