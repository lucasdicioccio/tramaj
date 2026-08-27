-- | The three analyses @../specs/laws.md@ asks to be cheap: which imports a
-- program uses, which actions it can emit, and which context values it still
-- needs.
--
-- Every case here answers its question from the AST alone -- no context, no
-- library evaluation, no host code. That is the property being protected: if
-- one of these ever needed to run a program to answer, a static position in
-- the grammar has been given up somewhere.
module Tramaj.AnalysisSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Test.Hspec
import Tramaj.Analysis
import Tramaj.Ast (Program)
import Tramaj.Parser

spec :: Spec
spec = do
  importSpec
  actionSpec
  holeSpec

prog :: Text -> Program
prog src = either (\e -> error ("analysis fixture does not parse: " <> show e)) id (parseProgram src)

libs :: Map.Map Text Program
libs =
  Map.fromList
    [ ("button", prog ".button(action(\"on-click\", \"deploy\", {}))")
    , ("row", prog ".tr(action(\"on-click\", \"select\", {}), import(\"button\", {}).rendered)")
    , ("needs", prog "@p=import(\"button\", {name: ctx(inner.name)})\n$p({}).rendered")
    , ("panel", prog "@n=$ctx.replicas\n.section(.h2($ctx.name), .p($n))")
    , ("loopy", prog ".div(import(\"loopy\", {}).rendered)")
    ]

importSpec :: Spec
importSpec = describe "imports" $ do
  it "finds every directly imported name" $
    staticImportNames (prog "@a=import(\"x\", {})\n.div(import(\"y\", {}).rendered)")
      `shouldBe` Set.fromList ["x", "y"]

  it "finds names inside lambdas, branches and unreached arms alike" $
    staticImportNames (prog "@f=(z) => import(\"deep\", {}).rendered\n.div(branch(.p(\"a\"), false, import(\"unreached\", {}).rendered))")
      `shouldBe` Set.fromList ["deep", "unreached"]

  it "finds none in a program that imports nothing" $
    staticImportNames (prog ".div(\"plain\")") `shouldBe` Set.empty

  it "follows imports transitively" $
    transitiveImportNames libs (prog ".div(import(\"row\", {}).rendered)")
      `shouldBe` Set.fromList ["row", "button"]

  it "reports an imported name that the table cannot resolve" $
    transitiveImportNames libs (prog ".div(import(\"missing\", {}).rendered)") `shouldBe` Set.fromList ["missing"]

  it "terminates on a cycle" $
    transitiveImportNames libs (prog ".div(import(\"loopy\", {}).rendered)") `shouldBe` Set.fromList ["loopy"]

actionSpec :: Spec
actionSpec = describe "action keys" $ do
  it "finds every key an element declares" $
    staticActionKeys (prog ".div(.b(action(\"on-click\", \"save\", {})), .b(action(\"on-key\", \"delete\", {})))")
      `shouldBe` Set.fromList ["save", "delete"]

  it "finds keys under an unreached branch arm, since the analysis approximates upward" $
    staticActionKeys (prog ".div(branch(.p(\"a\"), false, .b(action(\"on-click\", \"never\", {}))))")
      `shouldBe` Set.fromList ["never"]

  -- The payoff of restricting adaptation to identity-or-prefix: the analysis
  -- applies the very same rewrite the evaluator will.
  it "applies a prefix adaptation to the keys of its target" $
    staticActionKeys (prog "adapt-actions(.div(.b(action(\"on-click\", \"save\", {})), .b(action(\"on-click\", \"delete\", {}))), prefix(\"user:\"))")
      `shouldBe` Set.fromList ["user:save", "user:delete"]

  it "composes nested adaptations the way evaluation does" $
    staticActionKeys (prog "adapt-actions(adapt-actions(.b(action(\"on-click\", \"k\", {})), prefix(\"a:\")), prefix(\"b:\"))")
      `shouldBe` Set.fromList ["b:a:k"]

  it "leaves keys alone under the identity adaptation" $
    staticActionKeys (prog "adapt-actions(.b(action(\"on-click\", \"k\", {})), identity)") `shouldBe` Set.fromList ["k"]

  it "does not reach into a library on its own" $
    staticActionKeys (prog ".div(import(\"button\", {}).rendered)") `shouldBe` Set.empty

  it "reaches into a library when given the table" $
    deepActionKeys libs (prog ".div(import(\"button\", {}).rendered)") `shouldBe` Set.fromList ["deploy"]

  it "adapts keys that come from a library" $
    deepActionKeys libs (prog "adapt-actions(import(\"button\", {}).rendered, prefix(\"deployment:\"))")
      `shouldBe` Set.fromList ["deployment:deploy"]

  it "follows imports through several levels" $
    deepActionKeys libs (prog ".div(import(\"row\", {}).rendered)") `shouldBe` Set.fromList ["select", "deploy"]

  it "cuts a cycle rather than looping" $
    deepActionKeys libs (prog ".div(import(\"loopy\", {}).rendered)") `shouldBe` Set.empty

holeSpec :: Spec
holeSpec = describe "context holes" $ do
  it "finds the paths written as ctx(...)" $
    contextHoles (prog "@p=import(\"dep\", {\"name\": \"web\", \"replicas\": ctx(spec.replicas)})\n$p({}).rendered")
      `shouldBe` Set.fromList [["spec", "replicas"]]

  it "finds several holes across several imports" $
    contextHoles (prog "@a=import(\"x\", {n: ctx(one)})\n@b=import(\"y\", {m: ctx(two.deep)})\n.div($a({}).rendered, $b({}).rendered)")
      `shouldBe` Set.fromList [["one"], ["two", "deep"]]

  -- The same read, spelled as an ordinary path. It is a context read, but
  -- not a declared hole -- which is the whole reason @ctx(...)@ is a
  -- separate node when it evaluates identically.
  it "does not count a parameter read as $ctx.path" $
    contextHoles (prog "import(\"dep\", {\"replicas\": $ctx.spec.replicas}).rendered") `shouldBe` Set.empty

  it "finds none in a program with no imports" $
    contextHoles (prog ".div(\"plain\")") `shouldBe` Set.empty

  it "bubbles up the holes of imported libraries" $
    deepContextHoles libs (prog ".div(import(\"needs\", {}).rendered)")
      `shouldBe` Set.fromList [["inner", "name"]]

  it "counts both spellings as context reads" $
    contextReads (prog "@a=$ctx.x\nimport(\"dep\", {r: ctx(spec.replicas)}).rendered")
      `shouldBe` Set.fromList [["x"], ["spec", "replicas"]]

  it "counts a bare $ctx as reading the whole context" $
    contextReads (prog "$ctx") `shouldBe` Set.fromList [[]]

  -- What a library reads and the import never supplies: the parameters
  -- that have to arrive by a later call, without running anything.
  it "finds the parameters an import has not supplied" $
    unsuppliedParams libs (prog "import(\"panel\", {\"name\": \"web\"}).rendered")
      `shouldBe` [("panel", Set.fromList [["replicas"]])]

  it "finds nothing unsupplied when every read is covered" $
    unsuppliedParams libs (prog "import(\"panel\", {name: ctx(n), \"replicas\": 3}).rendered")
      `shouldBe` [("panel", Set.empty)]

  it "reports nothing unsupplied for a library outside the table" $
    unsuppliedParams libs (prog "import(\"nope\", {}).rendered") `shouldBe` [("nope", Set.empty)]
