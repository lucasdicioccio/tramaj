-- | End-to-end evaluation: parse a program, run it against a context, check
-- what it produced.
--
-- The suite is organised by what each group is actually protecting, because
-- most of these behaviours are decisions rather than consequences and a
-- failure should say which decision broke. See @../specs/decisions.md@.
module Tramaj.EvalSpec (spec) where

import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec
import Tramaj.Ast (Expr (..), Program (..))
import Tramaj.Eval
import Tramaj.Json (Json (..))
import Tramaj.Node
import Tramaj.Parser
import Tramaj.TestJson (ToJ (..), object, (.=))
import Tramaj.Types (TypeError (..))

spec :: Spec
spec = do
  documentSpec
  scalarSpec
  displayStringSpec
  fragmentSpec
  actionSpec
  bindingSpec
  concatSpec
  branchSpec
  collectionSpec
  importSpec
  adaptSpec
  errorSpec
  typeSpec
  arithmeticSpec
  sortSpec

-- Helpers -------------------------------------------------------------------

libs :: LibraryTable
libs =
  Map.fromList
    [ ("button", lib "@label=\"go: `$ctx.name`\"\n.button(action(\"on-click\", \"deploy\", {\"n\": $ctx.name}), $label)")
    , ("panel", lib "@n=$ctx.replicas\n.section(.h2($ctx.name), .p($n))")
    , ("two-actions", lib ".div(.b(action(\"on-click\", \"save\", {})), .b(action(\"on-click\", \"delete\", {})))")
    , ("data", lib "@a=1\n{\"a\": $a, \"b\": $ctx.b}")
    , ("wrapper", lib ".div(import(\"button\", {\"name\": \"inner\"}).rendered)")
    , ("loopy", lib ".div(import(\"loopy\", {}).rendered)")
    ]
  where
    lib :: Text -> Program
    lib src = either (\e -> error ("library fixture does not parse: " <> show e)) id (parseProgram src)

-- | Parse and evaluate, flattening a parse failure into the same 'Either' so
-- a fixture that stops parsing fails loudly instead of being skipped.
run :: Text -> Json -> Either String Output
run src ctx = case parseProgram src of
  Left e -> Left ("parse error: " <> show e)
  Right prog -> either (Left . show) Right (evalProgram Concrete libs ctx prog)

-- | The document a program produced, as its normative JSON -- what a host
-- receives, rather than the internal representation.
doc :: Text -> Json -> Either String Json
doc src ctx =
  run src ctx >>= \case
    ONode n -> Right (nodeToJson n)
    OValue v -> Left ("expected a document, got the value " <> show v)

val :: Text -> Json -> Either String Json
val src ctx =
  run src ctx >>= \case
    OValue v -> Right v
    ONode _ -> Left "expected a value, got a document"

failsWith :: (EvalError -> Bool) -> Text -> Json -> Bool
failsWith p src ctx = case parseProgram src of
  Left _ -> False
  Right prog -> either p (const False) (evalProgram Concrete libs ctx prog)

-- | Expected-node builders, matching @specs/node-json.md@.
elemJ :: Text -> [Json] -> [Json] -> Json -> Json
elemJ tag attrs children value =
  object
    [ "type" .= ("element" :: Text)
    , "tag" .= tag
    , "attributes" .= attrs
    , "value" .= value
    , "children" .= children
    , "annotations" .= object []
    ]

el :: Text -> [Json] -> Json
el tag children = elemJ tag [] children JNull

-- | A JSON array, spelled as a list at the call site.
arr :: [Json] -> Json
arr = JArray

textJ :: Json -> Json
textJ v = object ["type" .= ("text" :: Text), "value" .= v, "annotations" .= object []]

fragJ :: [Json] -> Json
fragJ children = object ["type" .= ("fragment" :: Text), "children" .= children, "annotations" .= object []]

attrJ :: Text -> Json -> Json
attrJ name v = object ["kind" .= ("attribute" :: Text), "name" .= name, "value" .= v]

actionJ :: Text -> Text -> Json -> Json
actionJ event key payload =
  object ["kind" .= ("action" :: Text), "event" .= event, "key" .= key, "payload" .= payload]

items :: [Text] -> Json
items names = object ["items" .= [object ["name" .= n] | n <- names]]

-- Documents -------------------------------------------------------------------

documentSpec :: Spec
documentSpec = describe "documents" $ do
  it "builds a nested element tree" $
    doc ".div(.p(\"Hello\"))" JNull `shouldBe` Right (el "div" [el "p" [textJ (JString "Hello")]])

  it "puts attributes and children in source order" $
    doc ".div(class: \"panel\", \"data-id\": 7, .h1(\"T\"), .p(\"B\"))" JNull
      `shouldBe` Right
        ( elemJ
            "div"
            [attrJ "class" (JString "panel"), attrJ "data-id" (JInt 7)]
            [el "h1" [textJ (JString "T")], el "p" [textJ (JString "B")]]
            JNull
        )

  it "keeps an attribute value as a value rather than a display string" $
    doc ".div(count: $ctx.n, tags: [1, 2], on: true)" (object ["n" .= (3 :: Int)])
      `shouldBe` Right
        ( elemJ
            "div"
            [attrJ "count" (JInt 3), attrJ "tags" (arr [JInt 1, JInt 2]), attrJ "on" (JBool True)]
            []
            JNull
        )

  it "fills the element value slot, defaulting to null" $ do
    doc ".Replicas(value($ctx.n))" (object ["n" .= (3 :: Int)]) `shouldBe` Right (elemJ "Replicas" [] [] (JInt 3))
    doc ".Replicas()" JNull `shouldBe` Right (elemJ "Replicas" [] [] JNull)

  it "splices a document held in a binding rather than stringifying it" $
    doc "@header=.header(.h1(\"T\"))\n.main($header)" JNull
      `shouldBe` Right (el "main" [el "header" [el "h1" [textJ (JString "T")]]])

  it "renders a document returned from a lambda" $
    doc "@row=(x) => .li($x)\n.ul($row(\"a\"), $row(\"b\"))" JNull
      `shouldBe` Right (el "ul" [el "li" [textJ (JString "a")], el "li" [textJ (JString "b")]])

  -- End to end, because the grammar checks in 'Tramaj.ParserSpec' cannot say
  -- that a stripped comment leaves the *output* alone -- and that a `--`
  -- inside a string reaches it intact.
  it "strips comments and keeps a `--` inside a string as text" $
    doc "-- a heading\n@n=cardinality($ctx.items) -- how many\n.p(\"`$n` -- so far\")"
      (object ["items" .= arr [JString "a", JString "b"]])
      `shouldBe` Right (el "p" [textJ (JString "2 -- so far")])

-- Scalars ------------------------------------------------------------------------

-- | The decision that scalars survive evaluation: v1 stringified every child.
scalarSpec :: Spec
scalarSpec = describe "scalar children" $ do
  it "keeps a number child a number" $
    doc ".td($ctx.count)" (object ["count" .= (3 :: Int)]) `shouldBe` Right (el "td" [textJ (JInt 3)])

  it "keeps booleans, null and objects unconverted" $
    doc ".div(true, null, {\"a\": 1})" JNull
      `shouldBe` Right
        (el "div" [textJ (JBool True), textJ JNull, textJ (object ["a" .= (1 :: Int)])])

  -- An array in child position is a sibling sequence, not one value: this is
  -- the same rule that lets map(...) produce repeated children, applied
  -- uniformly. An array wanted as data belongs in an attribute or the value
  -- slot, which is what those are for.
  it "splices an array child into siblings rather than nesting it as one value" $
    doc ".div([1, \"a\"])" JNull `shouldBe` Right (el "div" [textJ (JInt 1), textJ (JString "a")])

  it "converts only where the source asks, through interpolation" $
    doc ".p(\"n is `$ctx.n`\")" (object ["n" .= (3 :: Int)])
      `shouldBe` Right (el "p" [textJ (JString "n is 3")])

  it "renders a whole number without a trailing .0 when interpolated" $
    val "\"`$ctx.n`\"" (object ["n" .= (3 :: Int)]) `shouldBe` Right (JString "3")

  it "resolves escape sequences" $
    val "\"a\\tb\\nc\\u{1F600}\"" JNull `shouldBe` Right (JString "a\tb\nc\128512")

-- | How @str@ -- and therefore string interpolation -- renders each kind of
-- value. This is a normative rendering that both implementations must
-- produce character for character, so every case here is pinned exactly
-- rather than described loosely; a float follows ECMAScript's
-- @Number::toString@, which is simply what a number's text is on the
-- PureScript implementation's host, with @.0@ appended when that text has
-- neither a fraction nor an exponent.
displayStringSpec :: Spec
displayStringSpec = describe "str" $ do
  let renders :: Text -> Text -> Spec
      renders src expected =
        it (T.unpack src <> " -> " <> show expected) $
          val ("str(" <> src <> ")") JNull `shouldBe` Right (JString expected)

  renders "\"hi\"" "hi"
  renders "null" ""
  renders "true" "true"
  renders "false" "false"

  -- An integer is its digits; a float always carries a fraction or an
  -- exponent, so @str@ keeps the two apart (reference.md \S6).
  renders "3" "3"
  renders "-7" "-7"
  renders "123456789" "123456789"
  renders "9223372036854775807" "9223372036854775807"
  renders "3.0" "3.0"
  renders "0.0" "0.0"
  renders "-0.0" "0.0"
  renders "1.5" "1.5"
  renders "0.05" "0.05"

  -- v1 rendered this as "100000000000.0" on the PureScript side, whose
  -- integrality test went through a 32-bit Int. It is now what the float
  -- of that value renders as, and the integer renders without it.
  renders "100000000000" "100000000000"
  renders "100000000000.0" "100000000000.0"

  -- The thresholds where ECMAScript switches to scientific notation.
  renders "1000000000000000000000.0" "1e+21"
  renders "100000000000000000000.0" "100000000000000000000.0"
  renders "0.0000001" "1e-7"
  renders "0.000001" "0.000001"

  -- v1 rendered these through Haskell's own Show, leaking
  -- "Array [JInt 1.0,JInt 2.0]" into template output.
  renders "[1, 2]" "[1,2]"
  renders "[1, 1.0]" "[1,1.0]"
  renders "{\"a\": 1}" "{\"a\":1}"

  -- Keys are sorted: object key order is not semantically significant, so
  -- it must not be observable here either.
  renders "{\"b\": 2, \"a\": [1, {\"c\": true}]}" "{\"a\":[1,{\"c\":true}],\"b\":2}"

  it "renders a nested string with JSON escaping, but a bare one raw" $ do
    val "str([\"a\\\"b\"])" JNull `shouldBe` Right (JString "[\"a\\\"b\"]")
    val "str(\"a\\\"b\")" JNull `shouldBe` Right (JString "a\"b")

  it "is what string interpolation uses" $
    val "\"n=`$ctx.xs`\"" (object ["xs" .= ([1, 2] :: [Int])]) `shouldBe` Right (JString "n=[1,2]")

-- Fragments ---------------------------------------------------------------------

fragmentSpec :: Spec
fragmentSpec = describe "fragments" $ do
  it "introduces siblings with no wrapper element" $
    doc ".(.p(\"one\"), .p(\"two\"))" JNull
      `shouldBe` Right (fragJ [el "p" [textJ (JString "one")], el "p" [textJ (JString "two")]])

  it "survives as a real node when nested, rather than being flattened" $
    doc ".div(.(.p(\"a\")))" JNull `shouldBe` Right (el "div" [fragJ [el "p" [textJ (JString "a")]]])

  -- The JSX-children case, and the reason documents had to become values.
  it "can be bound and passed to a lambda as an ordinary argument" $
    doc "@kids=.(.p(\"a\"), .p(\"b\"))\n@panel=(t, c) => .section(.h2($t), $c)\n$panel(\"T\", $kids)" JNull
      `shouldBe` Right
        ( el
            "section"
            [ el "h2" [textJ (JString "T")]
            , fragJ [el "p" [textJ (JString "a")], el "p" [textJ (JString "b")]]
            ]
        )

  it "can be returned from a lambda over a mapped collection" $
    doc "@bs=(xs) => .(map($xs, (x) => .button($x.name)))\n$bs($ctx.items)" (items ["a", "b"])
      `shouldBe` Right (fragJ [el "button" [textJ (JString "a")], el "button" [textJ (JString "b")]])

-- Actions -------------------------------------------------------------------------

actionSpec :: Spec
actionSpec = describe "actions" $ do
  it "carries structured event, key and payload" $
    doc ".b(action(\"on-click\", \"deploy\", {\"id\": $ctx.id}), \"Go\")" (object ["id" .= (1 :: Int)])
      `shouldBe` Right
        ( elemJ
            "b"
            [actionJ "on-click" "deploy" (object ["id" .= (1 :: Int)])]
            [textJ (JString "Go")]
            JNull
        )

  -- v1 allowed at most one action per element.
  it "allows several on one element, in source order alongside attributes" $
    doc ".b(class: \"c\", action(\"on-click\", \"a\", {}), action(\"on-key\", \"b\", {}))" JNull
      `shouldBe` Right
        ( elemJ
            "b"
            [attrJ "class" (JString "c"), actionJ "on-click" "a" (object []), actionJ "on-key" "b" (object [])]
            []
            JNull
        )

-- Bindings ----------------------------------------------------------------------------

bindingSpec :: Spec
bindingSpec = describe "bindings and closures" $ do
  it "evaluates in declaration order, each seeing the earlier ones" $
    val "@a=1\n@b=$a\n{\"b\": $b}" JNull `shouldBe` Right (object ["b" .= (1 :: Int)])

  it "does not let a binding see a later one" $
    val "@a=$b\n@b=1\n$a" JNull `shouldSatisfy` isLeftWith "UnboundName"

  it "captures the environment at the point the lambda is created" $
    val "@t=10\n@big=(x) => gt($x, $t)\n@t2=$big(42)\n$t2" JNull `shouldBe` Right (JBool True)

  -- Not an accident: a binding's value is inserted only after it is
  -- evaluated, so nothing in the language can recurse.
  it "does not let a lambda call itself by its own binding name" $
    val "@f=(x) => $f($x)\n$f(1)" JNull `shouldSatisfy` isLeftWith "UnboundName"

  it "allows kebab-case names" $
    val "@my-var=1\n$my-var" JNull `shouldBe` Right (JInt 1)

  it "passes a builtin by reference" $
    val "map($ctx.xs, $not)" (object ["xs" .= [True, False]]) `shouldBe` Right (arr [JBool False, JBool True])
  where
    isLeftWith needle = either (\e -> needle `elem` words (map (\c -> if c == '"' then ' ' else c) e)) (const False)

-- Concat --------------------------------------------------------------------------------

concatSpec :: Spec
concatSpec = describe "concat" $ do
  it "joins strings" $ val "\"a\" <> \"b\"" JNull `shouldBe` Right (JString "ab")
  it "appends arrays" $ val "[1, 2] <> [3]" JNull `shouldBe` Right (arr [JInt 1, JInt 2, JInt 3])

  it "merges objects right-biased" $
    val "{\"a\": 1, \"b\": 2} <> {\"b\": 3, \"c\": 4}" JNull
      `shouldBe` Right (object ["a" .= (1 :: Int), "b" .= (3 :: Int), "c" .= (4 :: Int)])

  it "rejects mixed types rather than coercing" $
    ("\"a\" <> [1]" `failsWith'` \case ConcatMismatch _ _ -> True; _ -> False) `shouldBe` True

  it "is associative over a chain" $
    val "\"a\" <> \"b\" <> \"c\"" JNull `shouldBe` Right (JString "abc")

  it "has the natural identity for each type" $ do
    val "\"a\" <> \"\"" JNull `shouldBe` Right (JString "a")
    val "[1] <> []" JNull `shouldBe` Right (arr [JInt 1])
    val "{\"a\": 1} <> {}" JNull `shouldBe` Right (object ["a" .= (1 :: Int)])
  where
    failsWith' src p = failsWith p src JNull

-- Branch ----------------------------------------------------------------------------------

-- | Uniformly lazy, in every position -- decisions.md #3.
branchSpec :: Spec
branchSpec = describe "branch" $ do
  it "selects a value by the first true predicate" $
    val "branch(\"unknown\", eq($ctx.s, \"ready\"), \"ready\", eq($ctx.s, \"err\"), \"error\")" (object ["s" .= ("err" :: Text)])
      `shouldBe` Right (JString "error")

  it "falls back when no predicate holds" $
    val "branch(\"unknown\", false, \"a\")" JNull `shouldBe` Right (JString "unknown")

  it "selects a document in a child position" $
    doc ".div(branch(.p(\"fallback\"), eq($ctx.s, \"ready\"), .p(\"ready\")))" (object ["s" .= ("ready" :: Text)])
      `shouldBe` Right (el "div" [el "p" [textJ (JString "ready")]])

  it "does not evaluate the arm it does not select, so its errors never surface" $
    val "branch(\"fallback\", false, $nope.deeply.broken)" JNull `shouldBe` Right (JString "fallback")

  it "does not evaluate a later predicate once one has matched" $
    val "branch(\"fallback\", true, \"first\", $nope, \"second\")" JNull `shouldBe` Right (JString "first")

  it "requires its condition to be a boolean" $
    ("branch(\"f\", \"not a bool\", \"a\")" `failsWithT` \case TypeMismatch _ -> True; _ -> False) `shouldBe` True
  where
    failsWithT src p = failsWith p src JNull

-- Collections -------------------------------------------------------------------------------

collectionSpec :: Spec
collectionSpec = describe "collections" $ do
  it "maps to repeated children when its function returns documents" $
    doc ".ul(map($ctx.items, (i) => .li($i.name)))" (items ["a", "b"])
      `shouldBe` Right (el "ul" [el "li" [textJ (JString "a")], el "li" [textJ (JString "b")]])

  -- One map, two uses: the array is the value; splicing is the child rule.
  it "maps to an array when used as a value" $
    val "map($ctx.items, (i) => $i.name)" (items ["a", "b"]) `shouldBe` Right (arr [JString "a", JString "b"])

  it "splices a mapped array among ordinary siblings" $
    doc ".ul(.li(\"first\"), map($ctx.items, (i) => .li($i.name)), .li(\"last\"))" (items ["a"])
      `shouldBe` Right
        (el "ul" [el "li" [textJ (JString "first")], el "li" [textJ (JString "a")], el "li" [textJ (JString "last")]])

  it "filters" $
    val "filter($ctx.xs, (x) => gt($x, 1))" (object ["xs" .= ([1, 2, 3] :: [Int])])
      `shouldBe` Right (arr [JInt 2, JInt 3])

  it "scans, keeping the initial accumulator and every step" $
    val "scan($ctx.xs, 0, (a, x) => $x)" (object ["xs" .= ([1, 2] :: [Int])])
      `shouldBe` Right (arr [JInt 0, JInt 1, JInt 2])

  it "folds, keeping only the final accumulator" $
    val "fold($ctx.xs, 0, (a, x) => $x)" (object ["xs" .= ([1, 2] :: [Int])]) `shouldBe` Right (JInt 2)

  it "scopes the lambda parameter to its own body" $
    val "@r=map($ctx.xs, (x) => $x)\n$x" (object ["xs" .= ([1] :: [Int])])
      `shouldBe` Left "UnboundName \"x\""

-- Imports ---------------------------------------------------------------------------------------

importSpec :: Spec
importSpec = describe "imports" $ do
  it "renders a complete import" $
    doc "import(\"panel\", {\"name\": \"web\", \"replicas\": 3}).rendered" JNull
      `shouldBe` Right (el "section" [el "h2" [textJ (JString "web")], el "p" [textJ (JInt 3)]])

  it "exposes an expression-rooted library's result" $
    val "import(\"data\", {\"b\": 2}).rendered" JNull
      `shouldBe` Right (object ["a" .= (1 :: Int), "b" .= (2 :: Int)])

  it "exposes the library's top-level bindings as .vals" $
    val "import(\"data\", {\"b\": 2}).vals.a" JNull `shouldBe` Right (JInt 1)

  -- decisions.md #10: ctx(path) reads the importing program's own context,
  -- where the import is written -- the same value @$ctx.path@ would give.
  it "substitutes a ctx(path) parameter from the importing context" $
    doc
      "import(\"panel\", {name: ctx(n), replicas: ctx(spec.replicas)}).rendered"
      (object ["n" .= ("web" :: Text), "spec" .= object ["replicas" .= (3 :: Int)]])
      `shouldBe` Right (el "section" [el "h2" [textJ (JString "web")], el "p" [textJ (JInt 3)]])

  -- ... and omission, not ctx(...), is what leaves a parameter for later.
  it "saturates an omitted parameter by calling the import" $
    doc "@p=import(\"panel\", {\"name\": \"web\"})\n$p({\"replicas\": 3}).rendered" JNull
      `shouldBe` Right (el "section" [el "h2" [textJ (JString "web")], el "p" [textJ (JInt 3)]])

  it "accumulates parameters across calls, one at a time" $
    doc "@p=import(\"panel\", {})\n@half=$p({\"name\": \"web\"})\n$half({\"replicas\": 2}).rendered" JNull
      `shouldBe` Right (el "section" [el "h2" [textJ (JString "web")], el "p" [textJ (JInt 2)]])

  it "lets a later call override an earlier parameter" $
    doc "@p=import(\"panel\", {name: ctx(n), \"replicas\": 3})\n$p({\"name\": \"web\"}).rendered" (object ["n" .= ("stale" :: Text)])
      `shouldBe` Right (el "section" [el "h2" [textJ (JString "web")], el "p" [textJ (JInt 3)]])

  -- The point of running a library on field access rather than where the
  -- import is written: one wired-up import, reused per iteration.
  it "reuses one import with different parameters" $
    val "@p=import(\"data\", {})\nmap([1, 2], (b) => $p({\"b\": $b}).rendered.b)" JNull
      `shouldBe` Right (JArray [JInt 1, JInt 2])

  it "reports a parameter nobody supplied as the library's own missing path" $
    run "import(\"panel\", {\"name\": \"web\"}).rendered" JNull
      `shouldBe` Left (show (InLibrary "panel" (PathNotFound ["ctx", "replicas"])))

  it "reports a ctx(path) the importing context lacks, at the import" $
    run "import(\"panel\", {name: ctx(nope), \"replicas\": 3}).rendered" (object ["name" .= ("web" :: Text)])
      `shouldBe` Left (show (PathNotFound ["ctx", "nope"]))

  it "refuses to use an import that has not been run" $
    (".div(\"data-x\": import(\"data\", {\"b\": 1}))" `failsWithN` \case TypeMismatch _ -> True; _ -> False)
      `shouldBe` True

  it "refuses to saturate an import with anything but an object" $
    ("@p=import(\"panel\", {})\n$p(3).rendered" `failsWithN` \case TypeMismatch _ -> True; _ -> False)
      `shouldBe` True

  it "detects an import cycle instead of looping" $
    ("import(\"loopy\", {}).rendered" `failsWithN` \case InLibrary _ (ImportCycle _) -> True; _ -> False) `shouldBe` True

  it "reports an unknown library" $
    ("import(\"nope\", {}).rendered" `failsWithN` \case UnknownLibrary _ -> True; _ -> False) `shouldBe` True

  it "passes a document into a library as an ordinary parameter" $
    val "import(\"data\", {\"b\": 2}).vals.a" JNull `shouldBe` Right (JInt 1)
  where
    failsWithN src p = failsWith p src JNull

-- Action adaptation ------------------------------------------------------------------------------

adaptSpec :: Spec
adaptSpec = describe "adapt-actions" $ do
  it "prefixes every action key in the subtree" $
    doc "adapt-actions(import(\"two-actions\", {}).rendered, prefix(\"user:\"))" JNull
      `shouldBe` Right
        ( el
            "div"
            [ elemJ "b" [actionJ "on-click" "user:save" (object [])] [] JNull
            , elemJ "b" [actionJ "on-click" "user:delete" (object [])] [] JNull
            ]
        )

  it "composes, outermost prefix last" $
    val "cardinality({})" JNull `shouldBe` Right (JInt 0)

  it "composes two adaptations as b:a:key" $
    doc "adapt-actions(adapt-actions(import(\"button\", {\"name\": \"w\"}).rendered, prefix(\"a:\")), prefix(\"b:\"))" JNull
      `shouldBe` Right
        ( elemJ
            "button"
            [actionJ "on-click" "b:a:deploy" (object ["n" .= ("w" :: Text)])]
            [textJ (JString "go: w")]
            JNull
        )

  it "leaves keys alone under the identity adaptation" $
    doc "adapt-actions(import(\"button\", {\"name\": \"w\"}).rendered, identity)" JNull
      `shouldBe` Right
        ( elemJ
            "button"
            [actionJ "on-click" "deploy" (object ["n" .= ("w" :: Text)])]
            [textJ (JString "go: w")]
            JNull
        )

  -- The closure sees the already-prefixed action and may change only the
  -- event type and payload; a key it returns is ignored, which is what keeps
  -- the vocabulary statically knowable.
  it "lets the closure rewrite the event type and payload but not the key" $
    doc "adapt-actions(import(\"button\", {\"name\": \"w\"}).rendered, prefix(\"x:\"), (a) => {\"eventType\": \"on-tap\", \"key\": \"ignored\", \"payload\": {\"orig\": $a.key}})" JNull
      `shouldBe` Right
        ( elemJ
            "button"
            [actionJ "on-tap" "x:deploy" (object ["orig" .= ("x:deploy" :: Text)])]
            [textJ (JString "go: w")]
            JNull
        )

  it "reaches actions inside a nested import" $
    doc "adapt-actions(import(\"wrapper\", {}).rendered, prefix(\"w:\"))" JNull
      `shouldBe` Right
        ( el
            "div"
            [ elemJ
                "button"
                [actionJ "on-click" "w:deploy" (object ["n" .= ("inner" :: Text)])]
                [textJ (JString "go: inner")]
                JNull
            ]
        )

  it "queues on an import that has not run and applies to its result" $
    doc "@p=import(\"button\", {})\n@a=adapt-actions($p, prefix(\"q:\"))\n$a({\"name\": \"w\"}).rendered" JNull
      `shouldBe` Right
        ( elemJ
            "button"
            [actionJ "on-click" "q:deploy" (object ["n" .= ("w" :: Text)])]
            [textJ (JString "go: w")]
            JNull
        )

  it "leaves ordinary attributes and the value slot untouched" $
    doc "adapt-actions(.b(class: \"c\", value(1), action(\"on-click\", \"k\", {})), prefix(\"p:\"))" JNull
      `shouldBe` Right
        (elemJ "b" [attrJ "class" (JString "c"), actionJ "on-click" "p:k" (object [])] [] (JInt 1))

  it "passes through a value that has no actions at all" $
    val "adapt-actions(\"plain\", prefix(\"p:\"))" JNull `shouldBe` Right (JString "plain")

-- Errors ----------------------------------------------------------------------------------------------

errorSpec :: Spec
errorSpec = describe "errors" $ do
  it "reports an unbound name" $
    (failsWith (\case UnboundName _ -> True; _ -> False) "$nope" JNull) `shouldBe` True

  it "reports a missing field with the path as written" $
    (failsWith (\case PathNotFound ["ctx", "a", "b"] -> True; _ -> False) "$ctx.a.b" (object ["a" .= object []]) )
      `shouldBe` True

  it "refuses a function used where a value is expected" $
    (failsWith (\case TypeMismatch _ -> True; _ -> False) "@f=(x) => $x\n[$f, 1]" JNull) `shouldBe` True

  it "accepts the same function once it is called" $
    val "@f=(x) => $x\n[$f(1), 2]" JNull `shouldBe` Right (arr [JInt 1, JInt 2])

  it "refuses a document used where a plain value is expected" $
    (failsWith (\case TypeMismatch _ -> True; _ -> False) ".div(class: .p(\"x\"))" JNull) `shouldBe` True

  it "reports a closure applied to the wrong number of arguments" $
    (failsWith (\case TypeMismatch _ -> True; _ -> False) "@f=(x, y) => $x\n$f(1)" JNull) `shouldBe` True

  it "reports a non-array given to map" $
    (failsWith (\case TypeMismatch _ -> True; _ -> False) "map(1, (x) => $x)" JNull) `shouldBe` True

-- Types (v4-types, roadmap Phases 11-13) ---------------------------------------------------------------

-- | 'runProgram' over 'libs', for a given mode -- what a host actually
-- serializes, rather than the internal 'Output'.
runMode :: Mode -> Text -> Json -> Either String Json
runMode mode src ctx = case parseProgram src of
  Left e -> Left ("parse error: " <> show e)
  Right prog -> either (Left . show) Right (runProgram mode libs ctx prog)

typeSpec :: Spec
typeSpec = describe "types" $ do
  it "erasure invariant (\\S8): a concrete-mode run is byte-identical to the same program with its annotation deleted" $
    runMode Concrete "@d : string = \"x\"\n$d" JNull
      `shouldBe` runMode Concrete "@d = \"x\"\n$d" JNull

  it "an annotated binding emits a has-type constraint carrying the erased $type tag (\\S7)" $
    case runMode Symbolic "type Deployment = { replicas : int }\n@d : Deployment = {\"replicas\": 3}\n$d" JNull of
      Right (JObject o) ->
        Map.lookup "constraints" o
          `shouldBe` Just
            ( JArray
                [ object
                    [ "name" .= ("has-type" :: Text)
                    , "arguments"
                        .= [ object ["replicas" .= (3 :: Int)]
                           , object ["$type" .= ("root:Deployment" :: Text)]
                           ]
                    ]
                ]
            )
      other -> expectationFailure ("expected a symbolic envelope object, got " <> show other)

  it "the \"types\" table carries the referenced type's own definition, closed over its fields" $
    case runMode Symbolic "type Deployment = { replicas : int }\n@d : Deployment = {\"replicas\": 3}\n$d" JNull of
      Right (JObject o) ->
        Map.lookup "types" o
          `shouldBe` Just
            ( JArray
                [ object
                    [ "id" .= ("root:Deployment" :: Text)
                    , "definition"
                        .= object
                          [ "kind" .= ("record" :: Text)
                          , "fields" .= [object ["name" .= ("replicas" :: Text), "type" .= object ["kind" .= ("prim" :: Text), "name" .= ("int" :: Text)]]]
                          ]
                    ]
                ]
            )
      other -> expectationFailure ("expected a symbolic envelope object, got " <> show other)

  it "a !type-constraint appears in \"type-constraints\", resolved, and never in \"constraints\"" $
    case runMode Symbolic "type Json = string\n!type-constraint(\"has-default\", %Json)\ntrue" JNull of
      Right (JObject o) -> do
        Map.lookup "type-constraints" o
          `shouldBe` Just (JArray [object ["name" .= ("has-default" :: Text), "arguments" .= [object ["$type" .= ("root:Json" :: Text)]]]])
        Map.lookup "constraints" o `shouldBe` Just (JArray [])
      other -> expectationFailure ("expected a symbolic envelope object, got " <> show other)

  it "a symbol-free, type-free program's envelope carries empty \"types\" and \"type-constraints\" (\\S8: a v3 consumer sees nothing new)" $
    case runMode Symbolic "1" JNull of
      Right (JObject o) -> do
        Map.lookup "types" o `shouldBe` Just (JArray [])
        Map.lookup "type-constraints" o `shouldBe` Just (JArray [])
      other -> expectationFailure ("expected a symbolic envelope object, got " <> show other)

  it "an annotation whose type is still partial is a static PartialType error (\\S4), not an evaluation one" $
    let libsHere = Map.fromList [("message", either (\e -> error (show e)) id (parseProgram "type Envelope = { payload : %ctx.payload }\ntrue"))]
        p = either (\e -> error (show e)) id (parseProgram "@msg=import(\"message\", {})\n@m : $msg.types.Envelope = 1\ntrue")
     in case runProgram Concrete libsHere JNull p of
          Left (TypeErr (PartialType _ _)) -> pure ()
          other -> expectationFailure ("expected a PartialType error, got " <> show other)

-- | The arithmetic profile as an option of one evaluation (reference.md
-- \S11, v3-symbols \S5.5). What the builtins compute is the shared
-- corpus's business; here is what it has no shape for: the option, its
-- default, and the ends of the 64-bit range in integer division.
arithmeticSpec :: Spec
arithmeticSpec = describe "the arithmetic profile" $ do
  let on mode = defaultOptions {optMode = mode, optArithmetic = True}
      parsed src = either (\e -> error ("fixture does not parse: " <> show e)) id (parseProgram src)
      withOptions options libsHere src ctx = runProgramWith options libsHere ctx (parsed src)
      arith src = withOptions (on Concrete) Map.empty src JNull
      isUnbound name = \case
        Left (UnboundName n) -> n == name
        _ -> False
      isTypeMismatch = \case
        Left (TypeMismatch _) -> True
        _ -> False
      isNotRepresentable = \case
        Left (NotRepresentable _) -> True
        _ -> False
      symS = object ["$sym" .= ("#ctx.s" :: Text), "path" .= ([] :: [Text])]
      termS = object ["$term" .= ("sum" :: Text), "arguments" .= [symS, toJ (1 :: Int)]]
      adds = Map.fromList [("adds", parsed "@total=sum($ctx.a, 1)\n$total")]

  it "is off by default: concrete mode, no arithmetic" $
    defaultOptions `shouldBe` Options {optMode = Concrete, optArithmetic = False}

  it "leaves the names unbound through evalProgram and runProgram" $ do
    evalProgram Concrete Map.empty JNull (parsed "sum(1, 2)") `shouldSatisfy` isUnbound "sum"
    runProgram Concrete Map.empty JNull (parsed "sum(1, 2)") `shouldSatisfy` isUnbound "sum"
    runProgram Symbolic Map.empty JNull (parsed "map([1.5], $floor)") `shouldSatisfy` isUnbound "floor"

  it "leaves them unbound with the option off, and binds them with it on" $ do
    withOptions defaultOptions Map.empty "sum(1, 2)" JNull `shouldSatisfy` isUnbound "sum"
    withOptions (on Concrete) Map.empty "sum(1, 2)" JNull `shouldBe` Right (JInt 3)
    evalProgramWith (on Concrete) Map.empty JNull (parsed "sum(1, 2)") `shouldBe` Right (OValue (JInt 3))

  it "keeps a program that binds one of the names working with the option off" $
    runProgram Concrete Map.empty JNull (parsed "@sum=(a, b) => $a\n$sum(1, 2)") `shouldBe` Right (JInt 1)

  it "runs a library with the profile of the evaluation that reached it" $ do
    withOptions (on Concrete) adds "import(\"adds\", {a: 2}).vals.total" JNull `shouldBe` Right (JInt 3)
    withOptions defaultOptions adds "import(\"adds\", {a: 2}).vals.total" JNull
      `shouldBe` Left (InLibrary "adds" (UnboundName "sum"))

  it "accepts a seeded term in symbolic mode with the profile on, and hands it back" $
    case withOptions (on Symbolic) Map.empty "$ctx.t" (object ["t" .= termS]) of
      Right (JObject o) -> Map.lookup "root" o `shouldBe` Just termS
      other -> expectationFailure ("expected a symbolic envelope object, got " <> show other)

  it "refuses every seeded term with the profile off, read or not" $ do
    runProgram Symbolic Map.empty (object ["t" .= termS]) (parsed "$ctx.t") `shouldSatisfy` isTypeMismatch
    runProgram Symbolic Map.empty (object ["t" .= termS]) (parsed "1") `shouldSatisfy` isTypeMismatch

  it "refuses the reserved \"$term\" key in concrete mode whatever the profile" $ do
    withOptions (on Concrete) Map.empty "1" (object ["t" .= termS]) `shouldSatisfy` isTypeMismatch
    withOptions defaultOptions Map.empty "1" (object ["$term" .= (1 :: Int)]) `shouldSatisfy` isTypeMismatch

  it "keeps the two number types with the profile off" $
    runProgram Concrete Map.empty JNull (parsed "[eq(1, 1.0), 1, 1.0]")
      `shouldBe` Right (JArray [JBool False, JInt 1, JFloat 1.0])

  it "builds a term over a seeded symbol only with the profile on" $ do
    case withOptions (on Symbolic) Map.empty "sum($ctx.s, 1)" (object ["s" .= symS]) of
      Right (JObject o) -> Map.lookup "root" o `shouldBe` Just termS
      other -> expectationFailure ("expected a symbolic envelope object, got " <> show other)
    runProgram Symbolic Map.empty (object ["s" .= symS]) (parsed "sum($ctx.s, 1)") `shouldSatisfy` isUnbound "sum"

  it "divides exactly at the ends of the 64-bit range" $ do
    arith "floor-quotient(9223372036854775807, 2)" `shouldBe` Right (JInt 4611686018427387903)
    arith "floor-quotient(-9223372036854775808, 2)" `shouldBe` Right (JInt (-4611686018427387904))
    arith "floor-quotient(-9223372036854775808, 1)" `shouldBe` Right (JInt (-9223372036854775808))
    arith "floor-quotient(9223372036854775807, -1)" `shouldBe` Right (JInt (-9223372036854775807))
    arith "floor-quotient(-9223372036854775807, 9223372036854775807)" `shouldBe` Right (JInt (-1))
    arith "floor-quotient(9223372036854775807, -9223372036854775808)" `shouldBe` Right (JInt (-1))
    arith "modulo(9223372036854775807, -9223372036854775808)" `shouldBe` Right (JInt (-1))
    arith "modulo(-9223372036854775808, 9223372036854775807)" `shouldBe` Right (JInt 9223372036854775806)
    arith "modulo(-9223372036854775807, 2)" `shouldBe` Right (JInt 1)

  it "never wraps: a product or a sum that leaves the 64-bit range is an error at that step" $ do
    arith "product(-9223372036854775808, -1)" `shouldSatisfy` isNotRepresentable
    arith "product(4294967296, 4294967296, 0)" `shouldSatisfy` isNotRepresentable
    arith "product(3037000500, 3037000500)" `shouldSatisfy` isNotRepresentable
    arith "sum(-9223372036854775808, -9223372036854775808, 9223372036854775807)" `shouldSatisfy` isNotRepresentable
    arith "sum(-9223372036854775808, 9223372036854775807, 1)" `shouldBe` Right (JInt 0)

  it "folds floats left to right, one rounding at a time" $ do
    arith "sum(0.1, 0.2, 0.3)" `shouldBe` Right (JFloat 0.6000000000000001)
    arith "sum(1e16, 1.0, 1.0)" `shouldBe` Right (JFloat 1.0e16)
    arith "sum(1.0, 1.0, 1e16)" `shouldBe` Right (JFloat 1.0000000000000002e16)
    arith "product(49.0, inverse(49.0))" `shouldBe` Right (JFloat 0.9999999999999999)

-- | Sorting (reference.md \S11). What a sort gives is the shared corpus's
-- business; here is what no program can observe and the corpus therefore
-- cannot state: how many times the key function is applied. The key
-- function below emits one constraint each time it runs. A lambda written
-- in a template cannot do that, so the program is built as an AST, and
-- 'emittedConstraintCount' counts the emissions before equal ones are made
-- one.
sortSpec :: Spec
sortSpec = describe "the key function of a sort" $ do
  let row :: Int -> Expr
      row k = ObjectLit [("k", IntLit (fromIntegral k))]
      -- (x) => { !constraint("applied"); $x.k }
      counting = Lambda ["x"] (Emit (Constrain "applied" []) (Path "x" ["k"]))
      -- (x) => { !constraint("applied", $x.k); $x.k }
      tracing = Lambda ["x"] (Emit (Constrain "applied" [Path "x" ["k"]]) (Path "x" ["k"]))
      sorting descending keys fn = ExpressionProgram (SortBy descending (ArrayLit (map row keys)) fn)
      applications descending keys = emittedConstraintCount defaultOptions Map.empty JNull (sorting descending keys counting)
      shuffled = [5, 3, 9, 1, 7, 3, 8, 2, 6, 4, 0, 5] :: [Int]

  it "is applied exactly once per element, whatever the order of the keys" $ do
    applications False shuffled `shouldBe` Right (length shuffled)
    applications False [1 .. 16] `shouldBe` Right 16
    applications False (reverse [1 .. 16]) `shouldBe` Right 16
    applications False (replicate 9 4) `shouldBe` Right 9

  it "is applied exactly once per element by the descending sort" $ do
    applications True shuffled `shouldBe` Right (length shuffled)
    applications True [1 .. 16] `shouldBe` Right 16

  it "is applied once to a single element, and not at all to an empty list" $ do
    applications False [7] `shouldBe` Right 1
    applications False [] `shouldBe` Right 0
    applications True [] `shouldBe` Right 0

  it "is applied in index order, not in the order of the result" $
    case runProgramWith defaultOptions {optMode = Symbolic} Map.empty JNull (sorting False [3, 1, 2] tracing) of
      Right (JObject o) -> do
        Map.lookup "root" o `shouldBe` Just (arr [object ["k" .= (1 :: Int)], object ["k" .= (2 :: Int)], object ["k" .= (3 :: Int)]])
        Map.lookup "constraints" o
          `shouldBe` Just (arr [object ["name" .= ("applied" :: Text), "arguments" .= [k]] | k <- [3, 1, 2 :: Int]])
      other -> expectationFailure ("expected a symbolic envelope object, got " <> show other)

  it "is not applied past the first element whose key is refused" $
    emittedConstraintCount
      defaultOptions
      Map.empty
      JNull
      (ExpressionProgram (SortBy False (ArrayLit [row 1, ObjectLit [("k", NullLit)], row 2]) counting))
      `shouldSatisfy` \case
        Left (TypeMismatch _) -> True
        _ -> False
