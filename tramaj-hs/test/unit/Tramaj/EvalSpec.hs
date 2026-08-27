-- | End-to-end evaluation: parse a program, run it against a context, check
-- what it produced.
--
-- The suite is organised by what each group is actually protecting, because
-- most of these behaviours are decisions rather than consequences and a
-- failure should say which decision broke. See @../specs/decisions.md@.
module Tramaj.EvalSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import Test.Hspec
import Tramaj.Ast (Program)
import Tramaj.Eval
import Tramaj.Node
import Tramaj.Parser

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
run :: Text -> Value -> Either String Output
run src ctx = case parseProgram src of
  Left e -> Left ("parse error: " <> show e)
  Right prog -> either (Left . show) Right (evalProgram libs ctx prog)

-- | The document a program produced, as its normative JSON -- what a host
-- receives, rather than the internal representation.
doc :: Text -> Value -> Either String Value
doc src ctx =
  run src ctx >>= \case
    ONode n -> Right (nodeToJson n)
    OValue v -> Left ("expected a document, got the value " <> show v)

val :: Text -> Value -> Either String Value
val src ctx =
  run src ctx >>= \case
    OValue v -> Right v
    ONode _ -> Left "expected a value, got a document"

failsWith :: (EvalError -> Bool) -> Text -> Value -> Bool
failsWith p src ctx = case parseProgram src of
  Left _ -> False
  Right prog -> either p (const False) (evalProgram libs ctx prog)

-- | Expected-node builders, matching @specs/node-json.md@.
elemJ :: Text -> [Value] -> [Value] -> Value -> Value
elemJ tag attrs children value =
  object
    [ "type" .= ("element" :: Text)
    , "tag" .= tag
    , "attributes" .= attrs
    , "value" .= value
    , "children" .= children
    , "annotations" .= object []
    ]

el :: Text -> [Value] -> Value
el tag children = elemJ tag [] children Null

-- | A JSON array, spelled as a list at the call site.
arr :: [Value] -> Value
arr = Array . V.fromList

textJ :: Value -> Value
textJ v = object ["type" .= ("text" :: Text), "value" .= v, "annotations" .= object []]

fragJ :: [Value] -> Value
fragJ children = object ["type" .= ("fragment" :: Text), "children" .= children, "annotations" .= object []]

attrJ :: Text -> Value -> Value
attrJ name v = object ["kind" .= ("attribute" :: Text), "name" .= name, "value" .= v]

actionJ :: Text -> Text -> Value -> Value
actionJ event key payload =
  object ["kind" .= ("action" :: Text), "event" .= event, "key" .= key, "payload" .= payload]

items :: [Text] -> Value
items names = object ["items" .= [object ["name" .= n] | n <- names]]

-- Documents -------------------------------------------------------------------

documentSpec :: Spec
documentSpec = describe "documents" $ do
  it "builds a nested element tree" $
    doc ".div(.p(\"Hello\"))" Null `shouldBe` Right (el "div" [el "p" [textJ (String "Hello")]])

  it "puts attributes and children in source order" $
    doc ".div(class: \"panel\", \"data-id\": 7, .h1(\"T\"), .p(\"B\"))" Null
      `shouldBe` Right
        ( elemJ
            "div"
            [attrJ "class" (String "panel"), attrJ "data-id" (Number 7)]
            [el "h1" [textJ (String "T")], el "p" [textJ (String "B")]]
            Null
        )

  it "keeps an attribute value as a value rather than a display string" $
    doc ".div(count: $ctx.n, tags: [1, 2], on: true)" (object ["n" .= (3 :: Int)])
      `shouldBe` Right
        ( elemJ
            "div"
            [attrJ "count" (Number 3), attrJ "tags" (arr [Number 1, Number 2]), attrJ "on" (Bool True)]
            []
            Null
        )

  it "fills the element value slot, defaulting to null" $ do
    doc ".Replicas(value($ctx.n))" (object ["n" .= (3 :: Int)]) `shouldBe` Right (elemJ "Replicas" [] [] (Number 3))
    doc ".Replicas()" Null `shouldBe` Right (elemJ "Replicas" [] [] Null)

  it "splices a document held in a binding rather than stringifying it" $
    doc "@header=.header(.h1(\"T\"))\n.main($header)" Null
      `shouldBe` Right (el "main" [el "header" [el "h1" [textJ (String "T")]]])

  it "renders a document returned from a lambda" $
    doc "@row=(x) => .li($x)\n.ul($row(\"a\"), $row(\"b\"))" Null
      `shouldBe` Right (el "ul" [el "li" [textJ (String "a")], el "li" [textJ (String "b")]])

  -- End to end, because the grammar checks in 'Tramaj.ParserSpec' cannot say
  -- that a stripped comment leaves the *output* alone -- and that a `--`
  -- inside a string reaches it intact.
  it "strips comments and keeps a `--` inside a string as text" $
    doc "-- a heading\n@n=cardinality($ctx.items) -- how many\n.p(\"`$n` -- so far\")"
      (object ["items" .= arr [String "a", String "b"]])
      `shouldBe` Right (el "p" [textJ (String "2 -- so far")])

-- Scalars ------------------------------------------------------------------------

-- | The decision that scalars survive evaluation: v1 stringified every child.
scalarSpec :: Spec
scalarSpec = describe "scalar children" $ do
  it "keeps a number child a number" $
    doc ".td($ctx.count)" (object ["count" .= (3 :: Int)]) `shouldBe` Right (el "td" [textJ (Number 3)])

  it "keeps booleans, null and objects unconverted" $
    doc ".div(true, null, {\"a\": 1})" Null
      `shouldBe` Right
        (el "div" [textJ (Bool True), textJ Null, textJ (object ["a" .= (1 :: Int)])])

  -- An array in child position is a sibling sequence, not one value: this is
  -- the same rule that lets map(...) produce repeated children, applied
  -- uniformly. An array wanted as data belongs in an attribute or the value
  -- slot, which is what those are for.
  it "splices an array child into siblings rather than nesting it as one value" $
    doc ".div([1, \"a\"])" Null `shouldBe` Right (el "div" [textJ (Number 1), textJ (String "a")])

  it "converts only where the source asks, through interpolation" $
    doc ".p(\"n is `$ctx.n`\")" (object ["n" .= (3 :: Int)])
      `shouldBe` Right (el "p" [textJ (String "n is 3")])

  it "renders a whole number without a trailing .0 when interpolated" $
    val "\"`$ctx.n`\"" (object ["n" .= (3 :: Int)]) `shouldBe` Right (String "3")

  it "resolves escape sequences" $
    val "\"a\\tb\\nc\\u{1F600}\"" Null `shouldBe` Right (String "a\tb\nc\128512")

-- | How @str@ -- and therefore string interpolation -- renders each kind of
-- value. This is a normative rendering that both implementations must
-- produce character for character, so every case here is pinned exactly
-- rather than described loosely; the numbers follow ECMAScript's
-- @Number::toString@, which is simply what a number's text is on the
-- PureScript implementation's host.
displayStringSpec :: Spec
displayStringSpec = describe "str" $ do
  let renders :: Text -> Text -> Spec
      renders src expected =
        it (T.unpack src <> " -> " <> show expected) $
          val ("str(" <> src <> ")") Null `shouldBe` Right (String expected)

  renders "\"hi\"" "hi"
  renders "null" ""
  renders "true" "true"
  renders "false" "false"

  renders "3" "3"
  renders "1.5" "1.5"
  renders "0.05" "0.05"
  renders "123456789" "123456789"

  -- v1 rendered this as "100000000000.0" on the PureScript side, whose
  -- integrality test went through a 32-bit Int.
  renders "100000000000" "100000000000"

  -- The thresholds where ECMAScript switches to scientific notation.
  renders "1000000000000000000000" "1e+21"
  renders "0.0000001" "1e-7"

  -- v1 rendered these through Haskell's own Show, leaking
  -- "Array [Number 1.0,Number 2.0]" into template output.
  renders "[1, 2]" "[1,2]"
  renders "{\"a\": 1}" "{\"a\":1}"

  -- Keys are sorted: object key order is not semantically significant, so
  -- it must not be observable here either.
  renders "{\"b\": 2, \"a\": [1, {\"c\": true}]}" "{\"a\":[1,{\"c\":true}],\"b\":2}"

  it "renders a nested string with JSON escaping, but a bare one raw" $ do
    val "str([\"a\\\"b\"])" Null `shouldBe` Right (String "[\"a\\\"b\"]")
    val "str(\"a\\\"b\")" Null `shouldBe` Right (String "a\"b")

  it "is what string interpolation uses" $
    val "\"n=`$ctx.xs`\"" (object ["xs" .= ([1, 2] :: [Int])]) `shouldBe` Right (String "n=[1,2]")

-- Fragments ---------------------------------------------------------------------

fragmentSpec :: Spec
fragmentSpec = describe "fragments" $ do
  it "introduces siblings with no wrapper element" $
    doc ".(.p(\"one\"), .p(\"two\"))" Null
      `shouldBe` Right (fragJ [el "p" [textJ (String "one")], el "p" [textJ (String "two")]])

  it "survives as a real node when nested, rather than being flattened" $
    doc ".div(.(.p(\"a\")))" Null `shouldBe` Right (el "div" [fragJ [el "p" [textJ (String "a")]]])

  -- The JSX-children case, and the reason documents had to become values.
  it "can be bound and passed to a lambda as an ordinary argument" $
    doc "@kids=.(.p(\"a\"), .p(\"b\"))\n@panel=(t, c) => .section(.h2($t), $c)\n$panel(\"T\", $kids)" Null
      `shouldBe` Right
        ( el
            "section"
            [ el "h2" [textJ (String "T")]
            , fragJ [el "p" [textJ (String "a")], el "p" [textJ (String "b")]]
            ]
        )

  it "can be returned from a lambda over a mapped collection" $
    doc "@bs=(xs) => .(map($xs, (x) => .button($x.name)))\n$bs($ctx.items)" (items ["a", "b"])
      `shouldBe` Right (fragJ [el "button" [textJ (String "a")], el "button" [textJ (String "b")]])

-- Actions -------------------------------------------------------------------------

actionSpec :: Spec
actionSpec = describe "actions" $ do
  it "carries structured event, key and payload" $
    doc ".b(action(\"on-click\", \"deploy\", {\"id\": $ctx.id}), \"Go\")" (object ["id" .= (1 :: Int)])
      `shouldBe` Right
        ( elemJ
            "b"
            [actionJ "on-click" "deploy" (object ["id" .= (1 :: Int)])]
            [textJ (String "Go")]
            Null
        )

  -- v1 allowed at most one action per element.
  it "allows several on one element, in source order alongside attributes" $
    doc ".b(class: \"c\", action(\"on-click\", \"a\", {}), action(\"on-key\", \"b\", {}))" Null
      `shouldBe` Right
        ( elemJ
            "b"
            [attrJ "class" (String "c"), actionJ "on-click" "a" (object []), actionJ "on-key" "b" (object [])]
            []
            Null
        )

-- Bindings ----------------------------------------------------------------------------

bindingSpec :: Spec
bindingSpec = describe "bindings and closures" $ do
  it "evaluates in declaration order, each seeing the earlier ones" $
    val "@a=1\n@b=$a\n{\"b\": $b}" Null `shouldBe` Right (object ["b" .= (1 :: Int)])

  it "does not let a binding see a later one" $
    val "@a=$b\n@b=1\n$a" Null `shouldSatisfy` isLeftWith "UnboundName"

  it "captures the environment at the point the lambda is created" $
    val "@t=10\n@big=(x) => gt($x, $t)\n@t2=$big(42)\n$t2" Null `shouldBe` Right (Bool True)

  -- Not an accident: a binding's value is inserted only after it is
  -- evaluated, so nothing in the language can recurse.
  it "does not let a lambda call itself by its own binding name" $
    val "@f=(x) => $f($x)\n$f(1)" Null `shouldSatisfy` isLeftWith "UnboundName"

  it "allows kebab-case names" $
    val "@my-var=1\n$my-var" Null `shouldBe` Right (Number 1)

  it "passes a builtin by reference" $
    val "map($ctx.xs, $not)" (object ["xs" .= [True, False]]) `shouldBe` Right (arr [Bool False, Bool True])
  where
    isLeftWith needle = either (\e -> needle `elem` words (map (\c -> if c == '"' then ' ' else c) e)) (const False)

-- Concat --------------------------------------------------------------------------------

concatSpec :: Spec
concatSpec = describe "concat" $ do
  it "joins strings" $ val "\"a\" <> \"b\"" Null `shouldBe` Right (String "ab")
  it "appends arrays" $ val "[1, 2] <> [3]" Null `shouldBe` Right (arr [Number 1, Number 2, Number 3])

  it "merges objects right-biased" $
    val "{\"a\": 1, \"b\": 2} <> {\"b\": 3, \"c\": 4}" Null
      `shouldBe` Right (object ["a" .= (1 :: Int), "b" .= (3 :: Int), "c" .= (4 :: Int)])

  it "rejects mixed types rather than coercing" $
    ("\"a\" <> [1]" `failsWith'` \case ConcatMismatch _ _ -> True; _ -> False) `shouldBe` True

  it "is associative over a chain" $
    val "\"a\" <> \"b\" <> \"c\"" Null `shouldBe` Right (String "abc")

  it "has the natural identity for each type" $ do
    val "\"a\" <> \"\"" Null `shouldBe` Right (String "a")
    val "[1] <> []" Null `shouldBe` Right (arr [Number 1])
    val "{\"a\": 1} <> {}" Null `shouldBe` Right (object ["a" .= (1 :: Int)])
  where
    failsWith' src p = failsWith p src Null

-- Branch ----------------------------------------------------------------------------------

-- | Uniformly lazy, in every position -- decisions.md #3.
branchSpec :: Spec
branchSpec = describe "branch" $ do
  it "selects a value by the first true predicate" $
    val "branch(\"unknown\", eq($ctx.s, \"ready\"), \"ready\", eq($ctx.s, \"err\"), \"error\")" (object ["s" .= ("err" :: Text)])
      `shouldBe` Right (String "error")

  it "falls back when no predicate holds" $
    val "branch(\"unknown\", false, \"a\")" Null `shouldBe` Right (String "unknown")

  it "selects a document in a child position" $
    doc ".div(branch(.p(\"fallback\"), eq($ctx.s, \"ready\"), .p(\"ready\")))" (object ["s" .= ("ready" :: Text)])
      `shouldBe` Right (el "div" [el "p" [textJ (String "ready")]])

  it "does not evaluate the arm it does not select, so its errors never surface" $
    val "branch(\"fallback\", false, $nope.deeply.broken)" Null `shouldBe` Right (String "fallback")

  it "does not evaluate a later predicate once one has matched" $
    val "branch(\"fallback\", true, \"first\", $nope, \"second\")" Null `shouldBe` Right (String "first")

  it "requires its condition to be a boolean" $
    ("branch(\"f\", \"not a bool\", \"a\")" `failsWithT` \case TypeMismatch _ -> True; _ -> False) `shouldBe` True
  where
    failsWithT src p = failsWith p src Null

-- Collections -------------------------------------------------------------------------------

collectionSpec :: Spec
collectionSpec = describe "collections" $ do
  it "maps to repeated children when its function returns documents" $
    doc ".ul(map($ctx.items, (i) => .li($i.name)))" (items ["a", "b"])
      `shouldBe` Right (el "ul" [el "li" [textJ (String "a")], el "li" [textJ (String "b")]])

  -- One map, two uses: the array is the value; splicing is the child rule.
  it "maps to an array when used as a value" $
    val "map($ctx.items, (i) => $i.name)" (items ["a", "b"]) `shouldBe` Right (arr [String "a", String "b"])

  it "splices a mapped array among ordinary siblings" $
    doc ".ul(.li(\"first\"), map($ctx.items, (i) => .li($i.name)), .li(\"last\"))" (items ["a"])
      `shouldBe` Right
        (el "ul" [el "li" [textJ (String "first")], el "li" [textJ (String "a")], el "li" [textJ (String "last")]])

  it "filters" $
    val "filter($ctx.xs, (x) => gt($x, 1))" (object ["xs" .= ([1, 2, 3] :: [Int])])
      `shouldBe` Right (arr [Number 2, Number 3])

  it "scans, keeping the initial accumulator and every step" $
    val "scan($ctx.xs, 0, (a, x) => $x)" (object ["xs" .= ([1, 2] :: [Int])])
      `shouldBe` Right (arr [Number 0, Number 1, Number 2])

  it "folds, keeping only the final accumulator" $
    val "fold($ctx.xs, 0, (a, x) => $x)" (object ["xs" .= ([1, 2] :: [Int])]) `shouldBe` Right (Number 2)

  it "scopes the lambda parameter to its own body" $
    val "@r=map($ctx.xs, (x) => $x)\n$x" (object ["xs" .= ([1] :: [Int])])
      `shouldBe` Left "UnboundName \"x\""

-- Imports ---------------------------------------------------------------------------------------

importSpec :: Spec
importSpec = describe "imports" $ do
  it "renders a complete import" $
    doc "import(\"panel\", {\"name\": \"web\", \"replicas\": 3}).rendered" Null
      `shouldBe` Right (el "section" [el "h2" [textJ (String "web")], el "p" [textJ (Number 3)]])

  it "exposes an expression-rooted library's result" $
    val "import(\"data\", {\"b\": 2}).rendered" Null
      `shouldBe` Right (object ["a" .= (1 :: Int), "b" .= (2 :: Int)])

  it "exposes the library's top-level bindings as .vals" $
    val "import(\"data\", {\"b\": 2}).vals.a" Null `shouldBe` Right (Number 1)

  -- decisions.md #2: partiality is declared by ctx(...), not discovered.
  it "completes a deferred parameter from the supplied context" $
    doc "@p=import(\"panel\", {\"name\": \"web\", \"replicas\": ctx(spec.replicas)})\n$p({\"spec\": {\"replicas\": 3}}).rendered" Null
      `shouldBe` Right (el "section" [el "h2" [textJ (String "web")], el "p" [textJ (Number 3)]])

  it "completes progressively, one parameter at a time" $
    doc "@p=import(\"panel\", {name: ctx(n), replicas: ctx(r)})\n@half=$p({\"n\": \"web\"})\n$half({\"r\": 2}).rendered" Null
      `shouldBe` Right (el "section" [el "h2" [textJ (String "web")], el "p" [textJ (Number 2)]])

  it "refuses to use an import that is still waiting on a parameter" $
    ("@p=import(\"panel\", {name: ctx(n), replicas: ctx(r)})\n$p({\"n\": \"web\"})" `failsWithN` \case TypeMismatch _ -> True; _ -> False)
      `shouldBe` True

  -- v1 read a missing parameter as "this import must be partial"; now it is
  -- the error it always was.
  it "reports a genuinely missing parameter rather than suspending" $
    ("import(\"panel\", {\"name\": \"web\"}).rendered" `failsWithN` \case PathNotFound _ -> True; _ -> False)
      `shouldBe` True

  it "detects an import cycle instead of looping" $
    ("import(\"loopy\", {}).rendered" `failsWithN` \case ImportCycle _ -> True; _ -> False) `shouldBe` True

  it "reports an unknown library" $
    ("import(\"nope\", {}).rendered" `failsWithN` \case UnknownLibrary _ -> True; _ -> False) `shouldBe` True

  it "passes a document into a library as an ordinary parameter" $
    val "import(\"data\", {\"b\": 2}).vals.a" Null `shouldBe` Right (Number 1)
  where
    failsWithN src p = failsWith p src Null

-- Action adaptation ------------------------------------------------------------------------------

adaptSpec :: Spec
adaptSpec = describe "adapt-actions" $ do
  it "prefixes every action key in the subtree" $
    doc "adapt-actions(import(\"two-actions\", {}).rendered, prefix(\"user:\"))" Null
      `shouldBe` Right
        ( el
            "div"
            [ elemJ "b" [actionJ "on-click" "user:save" (object [])] [] Null
            , elemJ "b" [actionJ "on-click" "user:delete" (object [])] [] Null
            ]
        )

  it "composes, outermost prefix last" $
    val "cardinality({})" Null `shouldBe` Right (Number 0)

  it "composes two adaptations as b:a:key" $
    doc "adapt-actions(adapt-actions(import(\"button\", {\"name\": \"w\"}).rendered, prefix(\"a:\")), prefix(\"b:\"))" Null
      `shouldBe` Right
        ( elemJ
            "button"
            [actionJ "on-click" "b:a:deploy" (object ["n" .= ("w" :: Text)])]
            [textJ (String "go: w")]
            Null
        )

  it "leaves keys alone under the identity adaptation" $
    doc "adapt-actions(import(\"button\", {\"name\": \"w\"}).rendered, identity)" Null
      `shouldBe` Right
        ( elemJ
            "button"
            [actionJ "on-click" "deploy" (object ["n" .= ("w" :: Text)])]
            [textJ (String "go: w")]
            Null
        )

  -- The closure sees the already-prefixed action and may change only the
  -- event type and payload; a key it returns is ignored, which is what keeps
  -- the vocabulary statically knowable.
  it "lets the closure rewrite the event type and payload but not the key" $
    doc "adapt-actions(import(\"button\", {\"name\": \"w\"}).rendered, prefix(\"x:\"), (a) => {\"eventType\": \"on-tap\", \"key\": \"ignored\", \"payload\": {\"orig\": $a.key}})" Null
      `shouldBe` Right
        ( elemJ
            "button"
            [actionJ "on-tap" "x:deploy" (object ["orig" .= ("x:deploy" :: Text)])]
            [textJ (String "go: w")]
            Null
        )

  it "reaches actions inside a nested import" $
    doc "adapt-actions(import(\"wrapper\", {}).rendered, prefix(\"w:\"))" Null
      `shouldBe` Right
        ( el
            "div"
            [ elemJ
                "button"
                [actionJ "on-click" "w:deploy" (object ["n" .= ("inner" :: Text)])]
                [textJ (String "go: inner")]
                Null
            ]
        )

  it "queues on a partial import and applies once it is completed" $
    doc "@p=import(\"button\", {\"name\": ctx(who)})\n@a=adapt-actions($p, prefix(\"q:\"))\n$a({\"who\": \"w\"}).rendered" Null
      `shouldBe` Right
        ( elemJ
            "button"
            [actionJ "on-click" "q:deploy" (object ["n" .= ("w" :: Text)])]
            [textJ (String "go: w")]
            Null
        )

  it "leaves ordinary attributes and the value slot untouched" $
    doc "adapt-actions(.b(class: \"c\", value(1), action(\"on-click\", \"k\", {})), prefix(\"p:\"))" Null
      `shouldBe` Right
        (elemJ "b" [attrJ "class" (String "c"), actionJ "on-click" "p:k" (object [])] [] (Number 1))

  it "passes through a value that has no actions at all" $
    val "adapt-actions(\"plain\", prefix(\"p:\"))" Null `shouldBe` Right (String "plain")

-- Errors ----------------------------------------------------------------------------------------------

errorSpec :: Spec
errorSpec = describe "errors" $ do
  it "reports an unbound name" $
    (failsWith (\case UnboundName _ -> True; _ -> False) "$nope" Null) `shouldBe` True

  it "reports a missing field with the path as written" $
    (failsWith (\case PathNotFound ["ctx", "a", "b"] -> True; _ -> False) "$ctx.a.b" (object ["a" .= object []]) )
      `shouldBe` True

  it "refuses a function used where a value is expected" $
    (failsWith (\case TypeMismatch _ -> True; _ -> False) "@f=(x) => $x\n[$f, 1]" Null) `shouldBe` True

  it "accepts the same function once it is called" $
    val "@f=(x) => $x\n[$f(1), 2]" Null `shouldBe` Right (arr [Number 1, Number 2])

  it "refuses a document used where a plain value is expected" $
    (failsWith (\case TypeMismatch _ -> True; _ -> False) ".div(class: .p(\"x\"))" Null) `shouldBe` True

  it "reports a closure applied to the wrong number of arguments" $
    (failsWith (\case TypeMismatch _ -> True; _ -> False) "@f=(x, y) => $x\n$f(1)" Null) `shouldBe` True

  it "reports a non-array given to map" $
    (failsWith (\case TypeMismatch _ -> True; _ -> False) "map(1, (x) => $x)" Null) `shouldBe` True
