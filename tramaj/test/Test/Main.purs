-- | Runs the `Test.Fixtures` corpus end to end — parse, evaluate,
-- | serialize — and checks the result against the normative
-- | `specs/node-json.md` representation, plus the parser, analysis and
-- | round-trip checks the fixture shape cannot express.
-- |
-- | A bare-`Effect` runner that `throw`s on the first failure, rather than
-- | a spec-runner dependency: the same convention v1 used.
-- |
-- | This mirrors the Haskell suites (`ParserSpec`, `EvalSpec`,
-- | `AnalysisSpec`, `NodeJsonSpec`). Because both sides now assert against
-- | the same normative JSON, a fixture here and its Haskell counterpart can
-- | be compared by reading them — the natural next step being a single
-- | shared corpus both runners read, which is the "no cross-language
-- | conformance runner" gap the README has carried since v1.
module Test.Main where

import Prelude

import Data.Argonaut.Core (Json, jsonNull, stringify)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Class.Console (log)
import Effect.Exception (throw)
import Test.Fixtures (Fixture, Kind(..), fixtures)
import Tramaj.Analysis (contextHoles, deepActionKeys, deepContextHoles, staticActionKeys, staticImportNames, transitiveImportNames)
import Tramaj.Ast (ActionAdaptation(..), Expr(..), ParamValue(..), Program)
import Tramaj.Eval (LibraryTable, Output(..), evalProgram)
import Tramaj.Node (Node(..), NodeAttribute(..), noAnnotations, nodeFromJson, nodeToJson)
import Tramaj.Parser (parseExpr, parseProgram)

main :: Effect Unit
main = do
  runFixtures
  runParserChecks
  runLibraryChecks
  runAnalysisChecks
  runNodeJsonChecks
  log "All tramaj checks passed."

-- Fixtures --------------------------------------------------------------

runFixtures :: Effect Unit
runFixtures = do
  traverse_ runFixture fixtures
  log ("ok - " <> show (Array.length fixtures) <> " fixtures")

runFixture :: Fixture -> Effect Unit
runFixture f = do
  ctx <- mustParseJson (f.name <> " (ctx)") f.ctx
  expected <- mustParseJson (f.name <> " (expected)") f.expected
  program <- mustParse f.name f.template
  case evalProgram Map.empty ctx program of
    Left err -> throw (f.name <> ": eval failed: " <> show err)
    Right output -> do
      actual <- case output, f.kind of
        ONode n, Document -> pure (nodeToJson n)
        OValue v, Expression -> pure v
        ONode _, Expression -> throw (f.name <> ": expected a value, got a document")
        OValue v, Document -> throw (f.name <> ": expected a document, got the value " <> stringify v)
      if actual == expected then pure unit
      else
        throw
          ( f.name <> ": mismatch\n  expected: " <> stringify expected
              <> "\n  actual:   "
              <> stringify actual
          )

-- Parser ---------------------------------------------------------------

runParserChecks :: Effect Unit
runParserChecks = do
  traverse_ (uncurry rejects)
    [ Tuple "an attribute after a child" ".div(.p(\"hi\"), class: \"a\")"
    , Tuple "an action after a child" ".div(.p(\"hi\"), action(\"on-click\", \"a\", {}))"
    , Tuple "a value slot after a child" ".div(.p(\"hi\"), value(1))"
    , Tuple "more than one value slot" ".div(value(1), value(2))"
    , Tuple "a computed import name" "@l=import($ctx.name, {})\n.div($l.rendered)"
    , Tuple "an interpolated import name" "@l=import(\"a`$x`\", {})\n.div($l.rendered)"
    , Tuple "a computed action key" ".b(action(\"on-click\", $ctx.key, {}))"
    , Tuple "a computed action event" ".b(action($ctx.evt, \"save\", {}))"
    , Tuple "a computed adaptation prefix" "adapt-actions($x, prefix($ctx.ns))"
    , Tuple "an arbitrary function as an adaptation" "adapt-actions($x, (a) => $a)"
    , Tuple "an unknown adaptation" "adapt-actions($x, replace(\"a\", \"b\"))"
    , Tuple "a malformed import" "import(\"lib\")"
    , Tuple "a malformed map" "map($xs)"
    , Tuple "import parameters that are not a parameter list" "import(\"lib\", $ctx)"
    , Tuple "an unknown escape sequence" "\"a\\qb\""
    , Tuple "trailing input after the root" ".div() .span()"
    ]
  traverse_ (uncurry accepts)
    [ Tuple "an empty fragment" ".()"
    , Tuple "an element with no arguments" ".hr()"
    , Tuple "a call on a dotted path" "$lib.vals.fn(1)"
    , Tuple "a lambda with no parameters" "() => 1"
    , Tuple "a trailing comma in element arguments" ".div(\"a\", \"b\",)"
    , Tuple "a '.' starting the next line, not a field access" "@x=1\n.div(\"`$x`\")"
    ]
  -- The desugarings, stated as source-to-AST equalities: surface on the
  -- left, core constructors on the right, nothing in between. Compared
  -- structurally rather than by `show`, since `Data.Tuple`'s Show does not
  -- parenthesise its second field and the expectations would encode that
  -- quirk instead of the desugaring.
  traverse_ (uncurry desugarsTo)
    [ Tuple "\"hello\"" (StringLit "hello")
    , Tuple "\"n: `$x`!\""
        (Concat (Concat (StringLit "n: ") (Call (Path "str" []) [ Path "x" [] ])) (StringLit "!"))
    , Tuple "{foo, bar: 1}"
        (ObjectLit [ Tuple "foo" (Path "foo" []), Tuple "bar" (NumberLit 1.0) ])
    , Tuple "branch(0, $a, 1)" (Branch (Path "a" []) (NumberLit 1.0) (NumberLit 0.0))
    , Tuple "$a <> $b <> $c" (Concat (Concat (Path "a" []) (Path "b" [])) (Path "c" []))
    , Tuple "$a.b.c" (Path "a" [ "b", "c" ])
    , Tuple ".div()" (Element "div" [] NullLit [])
    , Tuple "import(\"dep\", {\"n\": \"w\", \"r\": ctx(spec.replicas)})"
        ( Import "dep"
            [ Tuple "n" (PExpr (StringLit "w"))
            , Tuple "r" (PFromContext [ "spec", "replicas" ])
            ]
        )
    , Tuple "adapt-actions($x, prefix(\"ns:\"))"
        (AdaptActions (Path "x" []) (Prefix "ns:") Nothing)
    ]
  log "ok - parser acceptance, rejection and desugaring"
  where
  rejects label src = case parseProgram src of
    Left _ -> pure unit
    Right p -> throw ("expected a parse error for " <> label <> ", got: " <> show p)

  accepts label src = case parseProgram src of
    Left err -> throw ("expected " <> label <> " to parse, got: " <> show err)
    Right _ -> pure unit

  desugarsTo :: String -> Expr -> Effect Unit
  desugarsTo src expected = case parseExpr src of
    Left err -> throw ("expected " <> src <> " to parse, got: " <> show err)
    Right e ->
      if e == expected then pure unit
      else throw (src <> " desugared to\n  " <> show e <> "\nexpected\n  " <> show expected)

-- Libraries -------------------------------------------------------------

libs :: LibraryTable
libs = Map.fromFoldable (map (\(Tuple n src) -> Tuple n (unsafeParse src)) sources)
  where
  sources =
    [ Tuple "button" "@label=\"go: `$ctx.name`\"\n.button(action(\"on-click\", \"deploy\", {\"n\": $ctx.name}), $label)"
    , Tuple "panel" "@n=$ctx.replicas\n.section(.h2($ctx.name), .p($n))"
    , Tuple "two-actions" ".div(.b(action(\"on-click\", \"save\", {})), .b(action(\"on-click\", \"delete\", {})))"
    , Tuple "data" "@a=1\n{\"a\": $a, \"b\": $ctx.b}"
    , Tuple "wrapper" ".div(import(\"button\", {\"name\": \"inner\"}).rendered)"
    , Tuple "loopy" ".div(import(\"loopy\", {}).rendered)"
    , Tuple "needs" "@p=import(\"button\", {name: ctx(inner.name)})\n$p({})"
    , Tuple "row" ".tr(action(\"on-click\", \"select\", {}), import(\"button\", {}).rendered)"
    ]

-- | A fixture that does not parse is a bug in the fixture, not a test
-- | outcome, so this is allowed to be partial — `runLibraryChecks` would
-- | fail loudly on the resulting nonsense anyway.
unsafeParse :: String -> Program
unsafeParse src = case parseProgram src of
  Right p -> p
  Left _ -> unsafeParse "null"

runLibraryChecks :: Effect Unit
runLibraryChecks = do
  traverse_ okWithLibs
    [ { label: "a complete import renders"
      , template: "import(\"panel\", {\"name\": \"web\", \"replicas\": 3}).rendered"
      , expected: "{\"type\":\"element\",\"tag\":\"section\",\"attributes\":[],\"value\":null,\"children\":[{\"type\":\"element\",\"tag\":\"h2\",\"attributes\":[],\"value\":null,\"children\":[{\"type\":\"text\",\"value\":\"web\",\"annotations\":{}}],\"annotations\":{}},{\"type\":\"element\",\"tag\":\"p\",\"attributes\":[],\"value\":null,\"children\":[{\"type\":\"text\",\"value\":3,\"annotations\":{}}],\"annotations\":{}}],\"annotations\":{}}"
      }
    , { label: "an expression-rooted library's .vals"
      , template: "import(\"data\", {\"b\": 2}).vals.a"
      , expected: "1"
      }
    , { label: "a deferred parameter completed from the supplied context"
      , template: "@p=import(\"panel\", {name: ctx(n), replicas: ctx(r)})\n@half=$p({\"n\": \"web\"})\n$half({\"r\": 2}).rendered"
      , expected: "{\"type\":\"element\",\"tag\":\"section\",\"attributes\":[],\"value\":null,\"children\":[{\"type\":\"element\",\"tag\":\"h2\",\"attributes\":[],\"value\":null,\"children\":[{\"type\":\"text\",\"value\":\"web\",\"annotations\":{}}],\"annotations\":{}},{\"type\":\"element\",\"tag\":\"p\",\"attributes\":[],\"value\":null,\"children\":[{\"type\":\"text\",\"value\":2,\"annotations\":{}}],\"annotations\":{}}],\"annotations\":{}}"
      }
    , { label: "adapt-actions prefixes every key in the subtree"
      , template: "adapt-actions(import(\"two-actions\", {}).rendered, prefix(\"user:\"))"
      , expected: "{\"type\":\"element\",\"tag\":\"div\",\"attributes\":[],\"value\":null,\"children\":[{\"type\":\"element\",\"tag\":\"b\",\"attributes\":[{\"kind\":\"action\",\"event\":\"on-click\",\"key\":\"user:save\",\"payload\":{}}],\"value\":null,\"children\":[],\"annotations\":{}},{\"type\":\"element\",\"tag\":\"b\",\"attributes\":[{\"kind\":\"action\",\"event\":\"on-click\",\"key\":\"user:delete\",\"payload\":{}}],\"value\":null,\"children\":[],\"annotations\":{}}],\"annotations\":{}}"
      }
    , { label: "adaptations compose as b:a:key"
      , template: "adapt-actions(adapt-actions(import(\"two-actions\", {}).rendered, prefix(\"a:\")), prefix(\"b:\"))"
      , expected: "{\"type\":\"element\",\"tag\":\"div\",\"attributes\":[],\"value\":null,\"children\":[{\"type\":\"element\",\"tag\":\"b\",\"attributes\":[{\"kind\":\"action\",\"event\":\"on-click\",\"key\":\"b:a:save\",\"payload\":{}}],\"value\":null,\"children\":[],\"annotations\":{}},{\"type\":\"element\",\"tag\":\"b\",\"attributes\":[{\"kind\":\"action\",\"event\":\"on-click\",\"key\":\"b:a:delete\",\"payload\":{}}],\"value\":null,\"children\":[],\"annotations\":{}}],\"annotations\":{}}"
      }
    ]
  traverse_ (uncurry rejectsWithLibs)
    [ Tuple "an import still waiting on a parameter"
        "@p=import(\"panel\", {name: ctx(n), replicas: ctx(r)})\n$p({\"n\": \"web\"})"
    , Tuple "a genuinely missing parameter, rather than suspending"
        "import(\"panel\", {\"name\": \"web\"}).rendered"
    , Tuple "an import cycle" "import(\"loopy\", {}).rendered"
    , Tuple "an unknown library" "import(\"nope\", {}).rendered"
    ]
  log "ok - imports and action adaptation"
  where
  rejectsWithLibs label template = do
    program <- mustParse label template
    case evalProgram libs jsonNull program of
      Left _ -> pure unit
      Right _ -> throw ("expected an eval error for " <> label)

runAnalysisChecks :: Effect Unit
runAnalysisChecks = do
  check "direct import names"
    (Set.toUnfoldable (staticImportNames (unsafeParse "@a=import(\"x\", {})\n.div(import(\"y\", {}).rendered)")))
    [ "x", "y" ]
  check "transitive import names"
    (Set.toUnfoldable (transitiveImportNames libs (unsafeParse ".div(import(\"row\", {}).rendered)")))
    [ "button", "row" ]
  check "a cycle terminates"
    (Set.toUnfoldable (transitiveImportNames libs (unsafeParse ".div(import(\"loopy\", {}).rendered)")))
    [ "loopy" ]
  check "action keys an element declares"
    (Set.toUnfoldable (staticActionKeys (unsafeParse ".div(.b(action(\"on-click\", \"save\", {})), .b(action(\"on-key\", \"delete\", {})))")))
    [ "delete", "save" ]
  check "a prefix adaptation is applied, not ignored"
    (Set.toUnfoldable (staticActionKeys (unsafeParse "adapt-actions(.b(action(\"on-click\", \"save\", {})), prefix(\"user:\"))")))
    [ "user:save" ]
  check "nested adaptations compose"
    (Set.toUnfoldable (staticActionKeys (unsafeParse "adapt-actions(adapt-actions(.b(action(\"on-click\", \"k\", {})), prefix(\"a:\")), prefix(\"b:\"))")))
    [ "b:a:k" ]
  check "a library's keys are not reached without the table"
    (Set.toUnfoldable (staticActionKeys (unsafeParse ".div(import(\"button\", {}).rendered)")))
    ([] :: Array String)
  check "a library's keys are reached with the table"
    (Set.toUnfoldable (deepActionKeys libs (unsafeParse ".div(import(\"button\", {}).rendered)")))
    [ "deploy" ]
  check "keys from a library are adapted too"
    (Set.toUnfoldable (deepActionKeys libs (unsafeParse "adapt-actions(import(\"button\", {}).rendered, prefix(\"deployment:\"))")))
    [ "deployment:deploy" ]
  check "context holes are the paths a deferred parameter reads"
    (Set.toUnfoldable (contextHoles (unsafeParse "@p=import(\"dep\", {\"r\": ctx(spec.replicas)})\n$p({})")))
    [ [ "spec", "replicas" ] ]
  check "a supplied parameter is not a hole"
    (Set.toUnfoldable (contextHoles (unsafeParse "import(\"dep\", {\"r\": $ctx.spec.replicas}).rendered")))
    ([] :: Array (Array String))
  check "holes bubble up from imported libraries"
    (Set.toUnfoldable (deepContextHoles libs (unsafeParse ".div(import(\"needs\", {}).rendered)")))
    [ [ "inner", "name" ] ]
  log "ok - static analyses"
  where
  check :: forall a. Eq a => Show a => String -> a -> a -> Effect Unit
  check label actual expected =
    if actual == expected then pure unit
    else throw (label <> ": expected " <> show expected <> ", got " <> show actual)

-- Node JSON --------------------------------------------------------------

runNodeJsonChecks :: Effect Unit
runNodeJsonChecks = do
  traverse_ roundTrips
    [ NText (unsafeJson "3") noAnnotations
    , NText (unsafeJson "\"hello\"") noAnnotations
    , NText (unsafeJson "null") noAnnotations
    , NElement "div" [] (unsafeJson "null") [] noAnnotations
    , NElement "b"
        [ NAttr "class" (unsafeJson "\"c\"")
        , NAction "on-click" "save" (unsafeJson "{\"id\":1}")
        , NAction "on-key" "open" (unsafeJson "null")
        ]
        (unsafeJson "2")
        [ NText (unsafeJson "\"Save\"") noAnnotations ]
        (Map.singleton "type" (unsafeJson "\"Button\""))
    , NFragment [ NText (unsafeJson "\"a\"") noAnnotations ] noAnnotations
    , NFragment [] noAnnotations
    ]
  traverse_ rejectsDecoding
    [ "{\"value\": 1, \"annotations\": {}}"
    , "{\"type\": \"comment\", \"annotations\": {}}"
    , "{\"type\": \"text\", \"annotations\": {}}"
    , "{\"type\": \"text\", \"value\": 1}"
    , "{\"type\": \"element\", \"tag\": \"p\", \"attributes\": [], \"children\": [], \"annotations\": {}}"
    , "{\"type\": \"fragment\", \"children\": [{\"type\": \"text\"}], \"annotations\": {}}"
    , "42"
    ]
  log "ok - node JSON round-trip and strict decoding"
  where
  roundTrips n = case nodeFromJson (nodeToJson n) of
    Right n' | n' == n -> pure unit
    Right n' -> throw ("round-trip changed the node:\n  before " <> show n <> "\n  after  " <> show n')
    Left err -> throw ("round-trip failed to decode: " <> err)

  rejectsDecoding src = do
    j <- mustParseJson "malformed node" src
    case nodeFromJson j of
      Left _ -> pure unit
      Right n -> throw ("expected " <> src <> " to be rejected, decoded to " <> show n)

-- Helpers ------------------------------------------------------------------

mustParse :: String -> String -> Effect Program
mustParse label src = case parseProgram src of
  Left err -> throw (label <> ": parse failed: " <> show err)
  Right p -> pure p

mustParseJson :: String -> String -> Effect Json
mustParseJson label src = case jsonParser src of
  Left err -> throw (label <> ": fixture is not valid JSON: " <> err)
  Right j -> pure j

-- | Only ever applied to literals written here, so a failure is a typo in
-- | this file rather than a runtime condition.
unsafeJson :: String -> Json
unsafeJson src = case jsonParser src of
  Right j -> j
  Left _ -> jsonNull

okWithLibs :: { label :: String, template :: String, expected :: String } -> Effect Unit
okWithLibs f = do
  expected <- mustParseJson (f.label <> " (expected)") f.expected
  program <- mustParse f.label f.template
  case evalProgram libs jsonNull program of
    Left err -> throw (f.label <> ": eval failed: " <> show err)
    Right output -> do
      let
        actual = case output of
          ONode n -> nodeToJson n
          OValue v -> v
      if actual == expected then pure unit
      else
        throw
          ( f.label <> ": mismatch\n  expected: " <> stringify expected
              <> "\n  actual:   "
              <> stringify actual
          )

traverse_ :: forall a. (a -> Effect Unit) -> Array a -> Effect Unit
traverse_ f = Array.foldl (\acc x -> acc *> f x) (pure unit)

uncurry :: forall a b c. (a -> b -> c) -> Tuple a b -> c
uncurry f (Tuple a b) = f a b
