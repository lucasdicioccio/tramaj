-- | Runs the shared `corpus/cases` corpus end to end — parse, evaluate,
-- | serialize — and checks the result against the normative
-- | `specs/node-json.md` representation, plus the parser, analysis and
-- | round-trip checks the corpus shape cannot express.
-- |
-- | A bare-`Effect` runner that `throw`s on the first failure, rather than
-- | a spec-runner dependency: the same convention v1 used.
-- |
-- | This mirrors the Haskell suites (`ParserSpec`, `EvalSpec`,
-- | `AnalysisSpec`, `NodeJsonSpec`, `CorpusSpec`). See `corpus/README.md`.
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
import Test.Corpus (runCorpus)
import Tramaj.Analysis (constraintKinds, contextHoles, contextReads, deepActionKeys, deepConstraintKinds, deepContextHoles, deepSymbolDemands, staticActionKeys, staticImportNames, symbolDemands, symbolSites, transitiveImportNames, unsuppliedParams)
import Tramaj.Ast (ActionAdaptation(..), Expr(..), ParamValue(..), Program)
import Tramaj.Eval (EvalError(..), LibraryTable, Mode(..), Output(..), evalProgram)
import Tramaj.Node (Node(..), NodeAttribute(..), noAnnotations, nodeFromJson, nodeToJson)
import Tramaj.Parser (parseExpr, parseProgram)

main :: Effect Unit
main = do
  runCorpus
  runParserChecks
  runCommentChecks
  runLibraryChecks
  runAnalysisChecks
  runNodeJsonChecks
  log "All tramaj checks passed."

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

-- Comments --------------------------------------------------------------

-- | Comments: `--` to the end of the line, single-line only.
-- |
-- | The load-bearing check is `leavesNoTrace` — a commented program and the
-- | same program with the comments deleted must parse to the *same* AST.
-- | Anything weaker would pass while comments quietly became a node, or
-- | shifted what the parser saw around them.
-- |
-- | Mirrors `commentSpec` in the Haskell `ParserSpec`.
runCommentChecks :: Effect Unit
runCommentChecks = do
  traverse_ (uncurry accepts)
    [ Tuple "a whole-line comment above the bindings" "-- a heading\n@n=1\n.p($n)"
    , Tuple "a comment trailing a binding" "@n=1 -- how many\n.p($n)"
    , Tuple "a comment inside an element's arguments"
        ".div(\n  class: \"a\", -- the class\n  .p(\"hi\")\n)"
    , Tuple "a comment between two children" ".div(\n  .p(\"a\"),\n  -- and then\n  .p(\"b\")\n)"
    , Tuple "a comment as the last line, with no newline after it" ".p(\"hi\")\n-- done"
    , Tuple "a comment directly after the root, on the same line" ".p(\"hi\") -- done"
    , Tuple "a file that is comments and one expression" "-- one\n-- two\n1"
    , Tuple "an empty comment" ".p(\"hi\") --"
    , Tuple "a second -- inside a comment, which does not nest or close it" "1 -- a -- b"
    ]
  -- A hyphen is a name character only between two others, which is what
  -- leaves `--` free to start a comment right after a name.
  traverse_ (uncurry rejects)
    [ Tuple "a binding name ending in a hyphen" "@a-=1\n$a"
    , Tuple "a tag ending in a hyphen" ".div-()"
    ]
  traverse_ leavesNoTrace
    [ { label: "a comment on its own line, and one trailing a binding"
      , commented: "-- the count\n@n=cardinality($ctx.items) -- how many\n.p(\"`$n`\")"
      , plain: "@n=cardinality($ctx.items)\n.p(\"`$n`\")"
      }
    , { label: "comments interleaved with an element's arguments"
      , commented: ".div(class: \"a\", -- attrs first\n  .p(\"hi\") -- then children\n)"
      , plain: ".div(class: \"a\", .p(\"hi\"))"
      }
    -- A comment is whitespace, and whitespace before a `.` is exactly what
    -- separates a new element from a field access on the call that just
    -- closed. So the v1 regression stays fixed with a comment in between.
    , { label: "a comment between a closing ')' and a '.' beginning the next line"
      , commented: "@x=cardinality($ctx.items) -- a count\n.div(\"`$x`\")"
      , plain: "@x=cardinality($ctx.items)\n.div(\"`$x`\")"
      }
    ]
  traverse_ (uncurry desugarsTo)
    -- A string is read character by character and never passes through the
    -- whitespace lexer, so `--` inside one is ordinary text.
    [ Tuple "\"a -- b\"" (StringLit "a -- b")
    , Tuple "adapt-actions($x, prefix(\"a--b:\"))"
        (AdaptActions (Path "x" []) (Prefix "a--b:") Nothing)
    -- The name stops at the hyphen pair rather than swallowing it, so this
    -- is a read of `x` followed by a comment — not a read of a name `x--`.
    , Tuple "$x-- note" (Path "x" [])
    , Tuple "$my-var-2" (Path "my-var-2" [])
    ]
  log "ok - comments"
  where
  accepts label src = case parseProgram src of
    Left err -> throw ("expected " <> label <> " to parse, got: " <> show err)
    Right _ -> pure unit

  rejects label src = case parseProgram src of
    Left _ -> pure unit
    Right p -> throw ("expected a parse error for " <> label <> ", got: " <> show p)

  leavesNoTrace :: { label :: String, commented :: String, plain :: String } -> Effect Unit
  leavesNoTrace c = case parseProgram c.commented, parseProgram c.plain of
    Right a, Right b ->
      if a == b then pure unit
      else throw (c.label <> ": the comments changed the AST\n  " <> show a <> "\nexpected\n  " <> show b)
    Left err, _ -> throw (c.label <> ": the commented program failed to parse: " <> show err)
    _, Left err -> throw (c.label <> ": the plain program failed to parse: " <> show err)

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
    , Tuple "needs" "@p=import(\"button\", {name: ctx(inner.name)})\n$p({}).rendered"
    , Tuple "row" ".tr(action(\"on-click\", \"select\", {}), import(\"button\", {}).rendered)"
    , Tuple "typed" "!constraint(\"has-type\", $ctx, \"Deployment\")\n1"
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
  -- The three ways a parameter is supplied -- an expression, a `ctx(path)`
  -- hole read from the importing program's own context, and omission
  -- saturated by a later call -- rendering the same library the same way.
  traverse_ okWithLibs
    [ { label: "parameters given as expressions"
      , ctx: "null"
      , template: "import(\"panel\", {\"name\": \"web\", \"replicas\": 3}).rendered"
      , expected: panel "\"web\"" "3"
      }
    , { label: "parameters given as ctx(path) holes"
      , ctx: "{\"n\": \"web\", \"spec\": {\"replicas\": 3}}"
      , template: "import(\"panel\", {name: ctx(n), replicas: ctx(spec.replicas)}).rendered"
      , expected: panel "\"web\"" "3"
      }
    , { label: "an omitted parameter saturated by calling the import"
      , ctx: "null"
      , template: "@p=import(\"panel\", {\"name\": \"web\"})\n$p({\"replicas\": 3}).rendered"
      , expected: panel "\"web\"" "3"
      }
    , { label: "parameters accumulating across two calls"
      , ctx: "null"
      , template: "@p=import(\"panel\", {})\n@half=$p({\"name\": \"web\"})\n$half({\"replicas\": 3}).rendered"
      , expected: panel "\"web\"" "3"
      }
    , { label: "a later call overriding an earlier parameter"
      , ctx: "{\"n\": \"stale\"}"
      , template: "@p=import(\"panel\", {name: ctx(n), \"replicas\": 3})\n$p({\"name\": \"web\"}).rendered"
      , expected: panel "\"web\"" "3"
      }
    -- One wired-up import, reused across a `map` with each iteration
    -- supplying its own parameter. This is the pattern that pays for
    -- running a library on field access rather than where it is written.
    , { label: "one import reused with different parameters"
      , ctx: "null"
      , template: "@p=import(\"data\", {})\nmap([1, 2], (b) => $p({\"b\": $b}).rendered.b)"
      , expected: "[1,2]"
      }
    , { label: "an expression-rooted library's .vals"
      , ctx: "null"
      , template: "import(\"data\", {\"b\": 2}).vals.a"
      , expected: "1"
      }
    , { label: "adapt-actions prefixes every key in the subtree"
      , ctx: "null"
      , template: "adapt-actions(import(\"two-actions\", {}).rendered, prefix(\"user:\"))"
      , expected: "{\"type\":\"element\",\"tag\":\"div\",\"attributes\":[],\"value\":null,\"children\":[{\"type\":\"element\",\"tag\":\"b\",\"attributes\":[{\"kind\":\"action\",\"event\":\"on-click\",\"key\":\"user:save\",\"payload\":{}}],\"value\":null,\"children\":[],\"annotations\":{}},{\"type\":\"element\",\"tag\":\"b\",\"attributes\":[{\"kind\":\"action\",\"event\":\"on-click\",\"key\":\"user:delete\",\"payload\":{}}],\"value\":null,\"children\":[],\"annotations\":{}}],\"annotations\":{}}"
      }
    , { label: "adaptations compose as b:a:key"
      , ctx: "null"
      , template: "adapt-actions(adapt-actions(import(\"two-actions\", {}).rendered, prefix(\"a:\")), prefix(\"b:\"))"
      , expected: "{\"type\":\"element\",\"tag\":\"div\",\"attributes\":[],\"value\":null,\"children\":[{\"type\":\"element\",\"tag\":\"b\",\"attributes\":[{\"kind\":\"action\",\"event\":\"on-click\",\"key\":\"b:a:save\",\"payload\":{}}],\"value\":null,\"children\":[],\"annotations\":{}},{\"type\":\"element\",\"tag\":\"b\",\"attributes\":[{\"kind\":\"action\",\"event\":\"on-click\",\"key\":\"b:a:delete\",\"payload\":{}}],\"value\":null,\"children\":[],\"annotations\":{}}],\"annotations\":{}}"
      }
    -- Adapting an import before it has run: nothing has actions yet, so
    -- the adaptation waits for the result rather than passing through.
    , { label: "an adaptation queued on an import that has not run"
      , ctx: "null"
      , template: "@p=import(\"button\", {})\n@a=adapt-actions($p, prefix(\"q:\"))\n$a({\"name\": \"w\"}).rendered"
      , expected: "{\"type\":\"element\",\"tag\":\"button\",\"attributes\":[{\"kind\":\"action\",\"event\":\"on-click\",\"key\":\"q:deploy\",\"payload\":{\"n\":\"w\"}}],\"value\":null,\"children\":[{\"type\":\"text\",\"value\":\"go: w\",\"annotations\":{}}],\"annotations\":{}}"
      }
    ]
  -- A parameter nobody supplied is not a declared hole and not a special
  -- value: it is the library reading a path its context lacks, which is an
  -- ordinary PathNotFound wearing the name of the library that raised it.
  traverse_ failsWithLibs
    [ { label: "a parameter the import never supplies"
      , ctx: "null"
      , template: "import(\"panel\", {\"name\": \"web\"}).rendered"
      , expected: InLibrary "panel" (PathNotFound [ "ctx", "replicas" ])
      }
    , { label: "a ctx(path) the importing context lacks"
      , ctx: "{\"name\": \"web\"}"
      , template: "import(\"panel\", {name: ctx(nope), \"replicas\": 3}).rendered"
      , expected: PathNotFound [ "ctx", "nope" ]
      }
    , { label: "an import cycle"
      , ctx: "null"
      , template: "import(\"loopy\", {}).rendered"
      , expected: InLibrary "loopy" (ImportCycle "loopy")
      }
    , { label: "an unknown library"
      , ctx: "null"
      , template: "import(\"nope\", {}).rendered"
      , expected: UnknownLibrary "nope"
      }
    ]
  traverse_ (uncurry rejectsWithLibs)
    [ Tuple "an import used where a plain value is expected"
        ".div(\"data-x\": import(\"data\", {\"b\": 1}))"
    , Tuple "an import saturated with something that is not an object"
        "@p=import(\"panel\", {})\n$p(3).rendered"
    , Tuple "an import saturated with more than one argument"
        "@p=import(\"panel\", {})\n$p({}, {}).rendered"
    ]
  log "ok - imports and action adaptation"
  where
  -- What the `panel` library renders, written once: the checks above
  -- differ in how its two parameters arrived, never in the result.
  panel name replicas =
    "{\"type\":\"element\",\"tag\":\"section\",\"attributes\":[],\"value\":null,\"children\":[{\"type\":\"element\",\"tag\":\"h2\",\"attributes\":[],\"value\":null,\"children\":[{\"type\":\"text\",\"value\":"
      <> name
      <> ",\"annotations\":{}}],\"annotations\":{}},{\"type\":\"element\",\"tag\":\"p\",\"attributes\":[],\"value\":null,\"children\":[{\"type\":\"text\",\"value\":"
      <> replicas
      <> ",\"annotations\":{}}],\"annotations\":{}}],\"annotations\":{}}"

  rejectsWithLibs label template = do
    program <- mustParse label template
    case evalProgram Concrete libs jsonNull program of
      Left _ -> pure unit
      Right _ -> throw ("expected an eval error for " <> label)

  failsWithLibs f = do
    ctx <- mustParseJson (f.label <> " (ctx)") f.ctx
    program <- mustParse f.label f.template
    case evalProgram Concrete libs ctx program of
      Left err | err == f.expected -> pure unit
      Left err -> throw (f.label <> ": expected " <> show f.expected <> ", got " <> show err)
      Right _ -> throw ("expected an eval error for " <> f.label)

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
  check "context holes are the paths written as ctx(...)"
    (Set.toUnfoldable (contextHoles (unsafeParse "@p=import(\"dep\", {\"r\": ctx(spec.replicas)})\n$p({}).rendered")))
    [ [ "spec", "replicas" ] ]
  -- The same read, spelled as an ordinary path. It is a context read, but
  -- not a declared hole -- which is the whole reason `ctx(...)` exists as
  -- a separate node when it evaluates identically.
  check "a parameter read as $ctx.path is not a hole"
    (Set.toUnfoldable (contextHoles (unsafeParse "import(\"dep\", {\"r\": $ctx.spec.replicas}).rendered")))
    ([] :: Array (Array String))
  check "holes bubble up from imported libraries"
    (Set.toUnfoldable (deepContextHoles libs (unsafeParse ".div(import(\"needs\", {}).rendered)")))
    [ [ "inner", "name" ] ]
  check "context reads count both spellings"
    (Set.toUnfoldable (contextReads (unsafeParse "@a=$ctx.x\nimport(\"dep\", {r: ctx(spec.replicas)}).rendered")))
    [ [ "spec", "replicas" ], [ "x" ] ]
  check "a bare $ctx reads the whole context"
    (Set.toUnfoldable (contextReads (unsafeParse "$ctx")))
    [ [] ]
  -- What a library reads and the import never supplies: the parameters
  -- that must arrive by a later call, computed without running anything.
  check "unsupplied parameters of an import"
    (map (\(Tuple name missing) -> Tuple name (Set.toUnfoldable missing :: Array (Array String)))
      (unsuppliedParams libs (unsafeParse "import(\"panel\", {\"name\": \"web\"}).rendered")))
    [ Tuple "panel" [ [ "replicas" ] ] ]
  check "an import supplying everything has nothing unsupplied"
    (map (\(Tuple name missing) -> Tuple name (Set.toUnfoldable missing :: Array (Array String)))
      (unsuppliedParams libs (unsafeParse "import(\"panel\", {name: ctx(n), \"replicas\": 3}).rendered")))
    [ Tuple "panel" [] ]
  check "a library outside the table reports nothing unsupplied"
    (map (\(Tuple name missing) -> Tuple name (Set.toUnfoldable missing :: Array (Array String)))
      (unsuppliedParams libs (unsafeParse "import(\"nope\", {}).rendered")))
    [ Tuple "nope" [] ]
  check "every constraint name a program can emit"
    (Set.toUnfoldable (constraintKinds (unsafeParse "!constraint(\"gte\", 1, 0)\n!constraint(\"lte\", 1, 10)\n1")))
    [ "gte", "lte" ]
  check "a kind emitted only under an unreached branch arm, since the analysis approximates upward"
    (Set.toUnfoldable (constraintKinds (unsafeParse "!branch(constraint(\"never\"), true, 1)\n1")))
    [ "never" ]
  check "none in a program that emits nothing"
    (Set.toUnfoldable (constraintKinds (unsafeParse "1")))
    ([] :: Array String)
  check "a library's constraints are not reached without the table"
    (Set.toUnfoldable (constraintKinds (unsafeParse "import(\"typed\", {}).rendered")))
    ([] :: Array String)
  check "a library's constraints are reached with the table"
    (Set.toUnfoldable (deepConstraintKinds libs (unsafeParse "import(\"typed\", {}).rendered")))
    [ "has-type" ]
  check "a cycle terminates for constraint kinds too"
    (Set.toUnfoldable (deepConstraintKinds libs (unsafeParse ".div(import(\"loopy\", {}).rendered)")))
    ([] :: Array String)
  check "every allocation site a program contains"
    (Set.toUnfoldable (symbolSites (unsafeParse "[?(\"a\"), ?(\"b\")]")))
    [ 0, 1 ]
  check "none in a program that allocates nothing"
    (Set.toUnfoldable (symbolSites (unsafeParse "1")))
    ([] :: Array Int)
  check "a site inside a lambda"
    (Set.toUnfoldable (symbolSites (unsafeParse "map($ctx.xs, (x) => ?($x))")))
    [ 0 ]
  check "every ?ctx.path demand directly"
    (Set.toUnfoldable (symbolDemands (unsafeParse "[?ctx.a, ?ctx.b.c]")))
    [ [ "a" ], [ "b", "c" ] ]
  check "none in a program with no demand"
    (Set.toUnfoldable (symbolDemands (unsafeParse "$ctx.a")))
    ([] :: Array (Array String))
  check "does not reach into a library on its own"
    (Set.toUnfoldable (symbolDemands (unsafeParse "import(\"withDemand\", {}).rendered")))
    ([] :: Array (Array String))
  check "bubbles up demands from an imported library"
    (Set.toUnfoldable (deepSymbolDemands (Map.insert "withDemand" (unsafeParse "?ctx.threshold") libs) (unsafeParse "import(\"withDemand\", {}).rendered")))
    [ [ "threshold" ] ]
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

okWithLibs :: { label :: String, ctx :: String, template :: String, expected :: String } -> Effect Unit
okWithLibs f = do
  ctx <- mustParseJson (f.label <> " (ctx)") f.ctx
  expected <- mustParseJson (f.label <> " (expected)") f.expected
  program <- mustParse f.label f.template
  case evalProgram Concrete libs ctx program of
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
