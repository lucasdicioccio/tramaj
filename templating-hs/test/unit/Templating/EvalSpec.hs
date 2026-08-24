-- | End-to-end (parse then eval) fixtures ported one-for-one from
-- @../templating/test/Test/Fixtures.purs@ -- same template strings, same
-- input contexts, same expected 'Node' trees, to confirm this Haskell port
-- and the PureScript original agree on the language's actual behavior, not
-- just its grammar.
module Templating.EvalSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Either (isLeft)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Vector as V
import Templating.Ast
import Templating.Eval (EvalError (..), LibrarySource (..), LibraryTable, evalJsonProgram, evalProgram)
import Templating.Parser (parseJsonProgram, parseProgram)
import Test.Hspec

elem_ :: Text -> [Node] -> Node
elem_ tag children = NElement {neTag = tag, neAttrs = Map.empty, neAction = Nothing, neChildren = children}

itemNamed :: Text -> Value
itemNamed n = object ["name" .= n]

itemTitled :: Text -> Value
itemTitled t = object ["title" .= t]

run :: Text -> Value -> Either String Node
run template ctx = case parseProgram template of
  Left e -> Left ("parse error: " <> show e)
  Right prog -> case evalProgram Map.empty ctx prog of
    Left e -> Left ("eval error: " <> show e)
    Right n -> Right n

-- | 'run''s counterpart for expression-rooted programs, keeping the eval
-- error rather than flattening it, since the JSON-mode fixtures below
-- assert on one.
runJson :: Text -> Value -> Either String (Either EvalError Value)
runJson template ctx = case parseJsonProgram template of
  Left e -> Left ("parse error: " <> show e)
  Right prog -> Right (evalJsonProgram Map.empty ctx prog)

spec :: Spec
spec = do
  templateSpec
  jsonSpec
  librarySpec

-- | JSON mode ('evalJsonProgram') is Haskell-only -- these fixtures have no
-- counterpart in @../templating/test/Test/Fixtures.purs@, so unlike
-- 'templateSpec' they are not held to cross-language agreement. Everything
-- they exercise below the root (bindings, closures, builtins, map/filter) is
-- the shared expression language, though, so a divergence there would still
-- show up in 'templateSpec'.
jsonSpec :: Spec
jsonSpec = describe "expression-rooted programs (JSON mode, Haskell-only)" $ do
  it "an object literal root keeps numbers as numbers, not display strings" $
    runJson
      "@n=cardinality($ctx.items)\n{\"count\": $n, \"first\": $ctx.items}"
      (object ["items" .= (["a", "b"] :: [Text])])
      `shouldBe` Right (Right (object ["count" .= (2 :: Int), "first" .= (["a", "b"] :: [Text])]))

  it "an array literal root, with a nested object preserved structurally" $
    runJson
      "[$ctx.who, {\"nested\": {\"deep\": true}}]"
      (object ["who" .= ("me" :: Text)])
      `shouldBe` Right (Right (Array (V.fromList [String "me", object ["nested" .= object ["deep" .= True]]])))

  it "map(...) as the root produces an array of objects" $
    runJson
      "map($ctx.items, (i) => {\"title\": $i.title})"
      (object ["items" .= [itemTitled "Alpha", itemTitled "Beta"]])
      `shouldBe` Right (Right (Array (V.fromList [itemTitled "Alpha", itemTitled "Beta"])))

  it "filter(...) and a bound lambda work the same as in template mode" $
    runJson
      "@is-big=(n) => $gt($n, 10)\nfilter($ctx.ns, $is-big)"
      (object ["ns" .= ([3, 20, 7, 40] :: [Int])])
      `shouldBe` Right (Right (Array (V.fromList [Number 20, Number 40])))

  it "a plain interpolated string root evaluates to a JSON string" $
    runJson "\"there are `cardinality($ctx.items)` item(s)\"" (object ["items" .= ([1, 2, 3] :: [Int])])
      `shouldBe` Right (Right (String "there are 3 item(s)"))

  it "an unbound name in the root is an eval error, not a parse error" $
    runJson "{\"x\": $nope}" Null
      `shouldBe` Right (Left (UnboundName "nope"))

  it "an element root is rejected -- that is template mode, not JSON mode" $
    case runJson ".div(\"hi\")" Null of
      Left _ -> pure ()
      Right r -> expectationFailure ("expected a parse error, got " <> show r)

templateSpec :: Spec
templateSpec = describe "Templating end-to-end fixtures (ported from the PureScript templating package)" $ do
  it "plain nested element tree" $
    run ".div(.p(\"Hello\"))" Null
      `shouldBe` Right (elem_ "div" [elem_ "p" [NText "Hello"]])

  it "@-defined computation-block binding via backtick interpolation" $
    run
      "@count=cardinality($ctx.items)\n.p(\"there are `$count` item(s)\")"
      (object ["items" .= (["a", "b", "c"] :: [Text])])
      `shouldBe` Right (elem_ "p" [NText "there are 3 item(s)"])

  it "bare $path value as a child" $
    run ".td($ctx.title)" (object ["title" .= ("Widget" :: Text)])
      `shouldBe` Right (elem_ "td" [NText "Widget"])

  it "functional map(...) in the template block produces repeated children" $
    run
      ".ul(map($ctx.items, (item) => .li($item.name)))"
      (object ["items" .= [itemNamed "a", itemNamed "b"]])
      `shouldBe` Right (elem_ "ul" [elem_ "li" [NText "a"], elem_ "li" [NText "b"]])

  it "action(...) resolves to Node's structured action field" $
    run
      ".button(action(\"on-click\", \"select\", {\"itemId\": $ctx.itemId}), \"Select\")"
      (object ["itemId" .= ("abc123" :: Text)])
      `shouldBe` Right
        ( NElement
            { neTag = "button"
            , neAttrs = Map.empty
            , neAction = Just (ActionPayload {apEventType = "on-click", apKey = "select", apPayload = object ["itemId" .= ("abc123" :: Text)]})
            , neChildren = [NText "Select"]
            }
        )

  it "action(...)'s event type is a general expr, not just a literal keyword" $
    run
      ".button(action($ctx.eventName, \"select\", {}), \"Select\")"
      (object ["eventName" .= ("on-click" :: Text)])
      `shouldBe` Right
        ( NElement
            { neTag = "button"
            , neAttrs = Map.empty
            , neAction = Just (ActionPayload {apEventType = "on-click", apKey = "select", apPayload = object []})
            , neChildren = [NText "Select"]
            }
        )

  it "action(...)'s event type is passed through verbatim, whatever it says" $
    run
      ".input(action(\"on-whatever-the-host-calls-it\", \"select\", {}), \"Select\")"
      Null
      `shouldBe` Right
        ( NElement
            { neTag = "input"
            , neAttrs = Map.empty
            , neAction = Just (ActionPayload {apEventType = "on-whatever-the-host-calls-it", apKey = "select", apPayload = object []})
            , neChildren = [NText "Select"]
            }
        )

  -- an *unrecognized* event type is no longer a thing: only the "must be a
  -- string" shape is still checked, the vocabulary is the host's
  it "action(...) rejects a non-string event type" $
    run ".button(action(42, \"a\", {}))" Null
      `shouldSatisfy` isLeft

  it "kebab-case binding name with a $-prefixed builtin call" $
    run
      "@my-var=$cardinality($ctx.items)\n.p(\"`$my-var`\")"
      (object ["items" .= (["a", "b", "c", "d", "e"] :: [Text])])
      `shouldBe` Right (elem_ "p" [NText "5"])

  it "quoted attribute key + $name(...) call value, attrs before children" $
    run
      ".foo(\"attr-kebab-case\": $cardinality($ctx.items), \"bar\": \"baz\", .p(\"hi\"))"
      (object ["items" .= (["a", "b", "c"] :: [Text])])
      `shouldBe` Right
        ( NElement
            { neTag = "foo"
            , neAttrs = Map.fromList [("attr-kebab-case", "3"), ("bar", "baz")]
            , neAction = Nothing
            , neChildren = [elem_ "p" [NText "hi"]]
            }
        )

  it "array- and object-literal bindings compose with $ctx paths" $
    run
      "@nums=[1,2,3]\n@wrapped={\"items\": $ctx.items}\n.div(\n  .p(\"`$cardinality($nums)`\"),\n  .p(\"`$cardinality($wrapped.items)`\")\n)"
      (object ["items" .= (["a", "b"] :: [Text])])
      `shouldBe` Right (elem_ "div" [elem_ "p" [NText "3"], elem_ "p" [NText "2"]])

  it "boolean literal + not/and/or/comparison predicates" $
    run
      "@is-big=$gt($ctx.count, 10)\n@both=$and(true, $is-big)\n@either=$or(false, $not($is-big))\n.div(\n  .p(\"`$both`\"),\n  .p(\"`$either`\")\n)"
      (object ["count" .= (20 :: Int)])
      `shouldBe` Right (elem_ "div" [elem_ "p" [NText "true"], elem_ "p" [NText "false"]])

  it "eq builtin for deep equality" $
    run ".p(\"`$eq($ctx.status, \"open\")`\")" (object ["status" .= ("open" :: Text)])
      `shouldBe` Right (elem_ "p" [NText "true"])

  it "has builtin is a tolerant presence/absence predicate" $
    run
      "@present=$has($ctx, \"title\")\n@absent=$has($ctx, \"nope\")\n@arr-in-range=$has($ctx.items, 1)\n@arr-out-of-range=$has($ctx.items, 5)\n.div(\n  .p(\"`$present`\"),\n  .p(\"`$absent`\"),\n  .p(\"`$arr-in-range`\"),\n  .p(\"`$arr-out-of-range`\")\n)"
      (object ["title" .= ("Widget" :: Text), "items" .= (["a", "b", "c"] :: [Text])])
      `shouldBe` Right
        ( elem_
            "div"
            [ elem_ "p" [NText "true"]
            , elem_ "p" [NText "false"]
            , elem_ "p" [NText "true"]
            , elem_ "p" [NText "false"]
            ]
        )

  it "lookup builtin for dynamic object/array access, with fallback" $
    run
      "@key=\"title\"\n@idx=1\n.div(\n  .p(\"`$lookup($ctx, $key, \"N/A\")`\"),\n  .p(\"`$lookup($ctx.items, $idx, \"N/A\")`\"),\n  .p(\"`$lookup($ctx, \"missing\", \"fallback-value\")`\"),\n  .p(\"`$lookup($ctx.items, 99, \"fallback-value\")`\")\n)"
      (object ["title" .= ("Widget" :: Text), "items" .= (["a", "b", "c"] :: [Text])])
      `shouldBe` Right
        ( elem_
            "div"
            [ elem_ "p" [NText "Widget"]
            , elem_ "p" [NText "b"]
            , elem_ "p" [NText "fallback-value"]
            , elem_ "p" [NText "fallback-value"]
            ]
        )

  it "branch builtin encodes if/elif/else as a value expression" $
    run
      "@size=$branch(\"large\", $lt($ctx.count, 5), \"small\", $lt($ctx.count, 20), \"medium\")\n.p(\"`$size`\")"
      (object ["count" .= (12 :: Int)])
      `shouldBe` Right (elem_ "p" [NText "medium"])

  it "branch builtin falls back when no predicate matches" $
    run
      "@size=$branch(\"large\", $lt($ctx.count, 5), \"small\", $lt($ctx.count, 20), \"medium\")\n.p(\"`$size`\")"
      (object ["count" .= (99 :: Int)])
      `shouldBe` Right (elem_ "p" [NText "large"])

  it "expr-level map(...) composes with the template's functional map(...)" $
    run
      "@titles=map($ctx.items, (item) => $lookup($item, \"title\", \"?\"))\n.ul(map($titles, (t) => .li($t)))"
      (object ["items" .= [itemTitled "Alpha", itemTitled "Beta"]])
      `shouldBe` Right (elem_ "ul" [elem_ "li" [NText "Alpha"], elem_ "li" [NText "Beta"]])

  it "expr-level filter(...) keeps only matching items" $
    run
      "@big=filter($ctx.nums, (n) => $gt($n, 5))\n.p(\"`$cardinality($big)`\")"
      (object ["nums" .= ([1, 10, 3, 8] :: [Int])])
      `shouldBe` Right (elem_ "p" [NText "2"])

  it "expr-level scan(...) is an accumulative fold (scanl semantics: seed first)" $
    run
      "@flags=scan($ctx.nums, false, (acc, n) => $or($acc, $gt($n, 5)))\n.ul(map($flags, (f) => .li($f)))"
      (object ["nums" .= ([1, 2, 8, 3] :: [Int])])
      `shouldBe` Right
        ( elem_
            "ul"
            [ elem_ "li" [NText "false"]
            , elem_ "li" [NText "false"]
            , elem_ "li" [NText "false"]
            , elem_ "li" [NText "true"]
            , elem_ "li" [NText "true"]
            ]
        )

  it "expr-level fold(...) reduces to a single final value (same step as scan, last only)" $
    run
      "@any-big=fold($ctx.nums, false, (acc, n) => $or($acc, $gt($n, 5)))\n.p(\"`$any-big`\")"
      (object ["nums" .= ([1, 2, 8, 3] :: [Int])])
      `shouldBe` Right (elem_ "p" [NText "true"])

  it "expr-level fold(...) over an empty array returns the seed unchanged" $
    run
      "@any-big=fold($ctx.nums, false, (acc, n) => $or($acc, $gt($n, 5)))\n.p(\"`$any-big`\")"
      (object ["nums" .= ([] :: [Int])])
      `shouldBe` Right (elem_ "p" [NText "false"])

  it "concat(...) joins multiple arrays in order" $
    run
      "@all=concat($ctx.a, $ctx.b, [5, 6])\n.ul(map($all, (n) => .li($n)))"
      (object ["a" .= ([1, 2] :: [Int]), "b" .= ([3, 4] :: [Int])])
      `shouldBe` Right
        ( elem_
            "ul"
            [ elem_ "li" [NText "1"]
            , elem_ "li" [NText "2"]
            , elem_ "li" [NText "3"]
            , elem_ "li" [NText "4"]
            , elem_ "li" [NText "5"]
            , elem_ "li" [NText "6"]
            ]
        )

  it "append(...) adds a single element at the end of an array" $
    run
      "@grown=append($ctx.items, \"new\")\n.p(\"`$cardinality($grown)`\")"
      (object ["items" .= (["a", "b"] :: [Text])])
      `shouldBe` Right (elem_ "p" [NText "3"])

  it "template-block branch(...) selects a matching node" $
    run
      "@is-admin=$eq($ctx.role, \"admin\")\n.div(branch(.p(\"guest\"), $is-admin, .p(\"admin!\")))"
      (object ["role" .= ("admin" :: Text)])
      `shouldBe` Right (elem_ "div" [elem_ "p" [NText "admin!"]])

  it "template-block branch(...) falls back to the fallback node" $
    run
      "@is-admin=$eq($ctx.role, \"admin\")\n.div(branch(.p(\"guest\"), $is-admin, .p(\"admin!\")))"
      (object ["role" .= ("user" :: Text)])
      `shouldBe` Right (elem_ "div" [elem_ "p" [NText "guest"]])

  it "a bound lambda is called by name, like a builtin" $
    run
      "@is-big=(n) => $gt($n, 10)\n.div(\n  .p(\"`$is-big(3)`\"),\n  .p(\"`$is-big(20)`\")\n)"
      Null
      `shouldBe` Right (elem_ "div" [elem_ "p" [NText "false"], elem_ "p" [NText "true"]])

  it "a bound lambda is passed to map(...) by reference, not just inline" $
    run
      "@get-title=(item) => $lookup($item, \"title\", \"?\")\n@titles=map($ctx.items, $get-title)\n.ul(map($titles, (t) => .li($t)))"
      (object ["items" .= [itemTitled "Alpha", itemTitled "Beta"]])
      `shouldBe` Right (elem_ "ul" [elem_ "li" [NText "Alpha"], elem_ "li" [NText "Beta"]])

  it "a closure captures its defining environment (lexical scoping)" $
    run
      "@threshold=5\n@is-big=(n) => $gt($n, $threshold)\n.p(\"`$is-big(10)`\")"
      Null
      `shouldBe` Right (elem_ "p" [NText "true"])

  it "a closure can be passed as an argument to another closure (higher-order)" $
    run
      "@apply=(f, x) => $f($x)\n@is-huge=(n) => $gt($n, 100)\n.p(\"`$apply($is-huge, 200)`\")"
      Null
      `shouldBe` Right (elem_ "p" [NText "true"])

  it "nodeToJson renders the action field as null when absent" $
    case run ".p(\"hi\")" Null of
      Left e -> expectationFailure e
      Right node ->
        nodeToJson node `shouldBe` object ["type" .= ("element" :: Text), "tag" .= ("p" :: Text), "attrs" .= object [], "action" .= Null, "children" .= V.fromList [object ["type" .= ("text" :: Text), "text" .= ("hi" :: Text)]]]

-- | @import@\/@partial-import@\/@remap-actions@ fixtures, ported one-for-one
-- from @../templating/test/Test/Main.purs@\'s @runImportTests@ -- same
-- library fixtures and the same ~25 cases.
librarySpec :: Spec
librarySpec = describe "import/partial-import/remap-actions" $ do
  it "import(...): .rendered is the library's evaluated template, spliced via nodeToJson" $
    runJsonWithLibs "@bar=import(\"greeter\", {\"name\": \"World\"})\n$bar.rendered" Null
      `shouldBe` Right (divWithText "hello World")

  it ".vals exposes the library's own bindings" $
    runJsonWithLibs "@bar=import(\"greeter\", {\"name\": \"World\"})\n$bar.vals.greeting" Null
      `shouldBe` Right (String "hello World")

  it "import(...) with an unknown library name is an eval error" $
    runJsonWithLibs "import(\"nope\", {})" Null `shouldSatisfy` isLeft

  it "import(...) with an unknown library name is an eval error (via bound name)" $
    runJsonWithLibs "@bar=import(\"nope\", {})\n$bar.rendered" Null `shouldSatisfy` isLeft

  it "a self-importing library fails as an import cycle, not a stack overflow" $
    runJsonWithLibs "@bar=import(\"cyclic\", {})\n$bar.rendered" Null `shouldSatisfy` isLeft

  it "a whole import result (VEnv) can't be used where a Json value is required" $
    runJsonWithLibs "@bar=import(\"greeter\", {\"name\": \"World\"})\n$bar" Null `shouldSatisfy` isLeft

  it "partial-import(...) with already-complete params matches import(...) with the same params" $
    runJsonWithLibs
      "@a=import(\"one-arg\", {\"arg0\": \"foo\"})\n@b=partial-import(\"one-arg\", {\"arg0\": \"foo\"})\n[$a.rendered, $b.rendered]"
      Null
      `shouldBe` Right (Array (V.fromList [divWithText "foo", divWithText "foo"]))

  it "an incomplete partial-import(...) can't be used where a Json value is required" $
    runJsonWithLibs "@p=partial-import(\"one-arg\", {})\n$p" Null `shouldSatisfy` isLeft

  it "completing a partial-import(...) by calling it matches a direct import(...) with the merged params" $
    runJsonWithLibs
      "@direct=import(\"one-arg\", {\"arg0\": \"foo\"})\n@p=partial-import(\"one-arg\", {})\n@done=$p({\"arg0\": \"foo\"})\n[$direct.rendered, $done.rendered]"
      Null
      `shouldBe` Right (Array (V.fromList [divWithText "foo", divWithText "foo"]))

  it "partial-import(...) currying two missing params one at a time matches supplying both up front" $
    runJsonWithLibs
      "@direct=import(\"two-arg\", {\"a\": \"x\", \"b\": \"y\"})\n@p=partial-import(\"two-arg\", {})\n@p2=$p({\"a\": \"x\"})\n@done=$p2({\"b\": \"y\"})\n[$direct.rendered, $done.rendered]"
      Null
      `shouldBe` Right (Array (V.fromList [divWithText "x-y", divWithText "x-y"]))

  it "partial-import(...) still hard-errors for a reason unrelated to missing ctx params" $
    runJsonWithLibs "partial-import(\"nope\", {})" Null `shouldSatisfy` isLeft

  it "completing a partial-import(...) and chaining .rendered directly, no intermediate binding" $
    runJsonWithLibs "@p=partial-import(\"one-arg\", {})\n$p({\"arg0\": \"foo\"}).rendered" Null
      `shouldBe` Right (divWithText "foo")

  it "completing a partial-import(...) and chaining .rendered as a bare child, in the template block" $
    runTemplateWithLibs "@p=partial-import(\"one-arg\", {})\n.div($p({\"arg0\": \"foo\"}).rendered)" Null
      `shouldBe` Right (elem_ "div" [elem_ "div" [NText "foo"]])

  it "remap-actions(...) rewrites an action's key (string-interpolation prefix) and passes the payload through" $
    runJsonWithLibs
      "@bar=import(\"btn\", {\"n\": 5})\n@remapped=remap-actions($bar.rendered, (a) => {\"eventType\": $a.eventType, \"key\": \"ns-`$a.key`\", \"payload\": $a.payload})\n$remapped"
      Null
      `shouldBe` Right (buttonNode "ns-foo" (object ["n" .= (5 :: Int)]) "click")

  it "remap-actions(...)'s function can rewrite the payload as a function of the original key and payload" $
    runJsonWithLibs
      "@bar=import(\"btn\", {\"n\": 5})\n@remapped=remap-actions($bar.rendered, (a) => {\"eventType\": $a.eventType, \"key\": $a.key, \"payload\": {\"from\": $a.key, \"orig\": $a.payload}})\n$remapped"
      Null
      `shouldBe` Right (buttonNode "foo" (object ["from" .= ("foo" :: Text), "orig" .= object ["n" .= (5 :: Int)]]) "click")

  it "remap-actions(...) recurses through every action in the subtree, not just the root" $
    runJsonWithLibs
      "@bar=import(\"two-actions\", {})\n@remapped=remap-actions($bar.rendered, (a) => {\"eventType\": $a.eventType, \"key\": \"ns-`$a.key`\", \"payload\": $a.payload})\n$remapped"
      Null
      `shouldBe` Right
        ( object
            [ "type" .= ("element" :: Text)
            , "tag" .= ("div" :: Text)
            , "attrs" .= object []
            , "action" .= Null
            , "children" .= V.fromList [button2 "ns-a" (1 :: Int) "A", button2 "ns-b" (2 :: Int) "B"]
            ]
        )

  it "remap-actions(...) is a no-op (and never calls the function) on a node with no action anywhere" $
    runJsonWithLibs
      "@bar=import(\"greeter\", {\"name\": \"World\"})\n@remapped=remap-actions($bar.rendered, (a) => $nonexistent)\n$remapped"
      Null
      `shouldBe` Right (divWithText "hello World")

  it "remap-actions(...) on something that isn't a rendered node (a plain Json value) is a clear error" $
    runJsonWithLibs "remap-actions(5, (a) => $a)" Null `shouldSatisfy` isLeft

  it "remap-actions(...)'s function returning a malformed record (missing key) is a clear error, not a silently-dropped action" $
    runJsonWithLibs
      "@bar=import(\"btn\", {\"n\": 5})\n@remapped=remap-actions($bar.rendered, (a) => {\"eventType\": $a.eventType, \"payload\": $a.payload})\n$remapped"
      Null
      `shouldSatisfy` isLeft

  it "remap-actions(...) accepts an import(...) result directly (no .rendered projection needed), remapping in place and keeping .vals" $
    runJsonWithLibs
      "@bar=import(\"btn\", {\"n\": 5})\n@remapped=remap-actions($bar, (a) => {\"eventType\": $a.eventType, \"key\": \"ns-`$a.key`\", \"payload\": $a.payload})\n$remapped.rendered"
      Null
      `shouldBe` Right (buttonNode "ns-foo" (object ["n" .= (5 :: Int)]) "click")

  it "remap-actions(...) accepts a partial-import(...) result directly, once completed" $
    runJsonWithLibs
      "@p=partial-import(\"btn\", {})\n@remapped=remap-actions($p({\"n\": 5}), (a) => {\"eventType\": $a.eventType, \"key\": \"ns-`$a.key`\", \"payload\": $a.payload})\n$remapped.rendered"
      Null
      `shouldBe` Right (buttonNode "ns-foo" (object ["n" .= (5 :: Int)]) "click")

  it "remap-actions(...) on an import(...) result still surfaces .vals unchanged alongside the remapped .rendered" $
    runJsonWithLibs "@bar=import(\"greeter\", {\"name\": \"World\"})\n@remapped=remap-actions($bar, (a) => $a)\n$remapped.vals.greeting" Null
      `shouldBe` Right (String "hello World")

  it "remap-actions(...) on a JSON-mode import's result (whose \"rendered\" is plain Json, not a node) is a no-op, not an error" $
    runJsonWithLibs "@bar=import(\"json-lib\", {\"n\": 5})\n@remapped=remap-actions($bar, (a) => $a)\n$remapped.rendered" Null
      `shouldBe` Right (object ["n" .= (5 :: Int)])

  it "remap-actions(...) recurses into .vals too, reaching a sub-import's action even when it isn't spliced into the outer .rendered" $
    runJsonWithLibs
      "@bar=import(\"wraps-btn-in-vals\", {})\n@remapped=remap-actions($bar, (a) => {\"eventType\": $a.eventType, \"key\": \"ns-`$a.key`\", \"payload\": $a.payload})\n$remapped.vals.sub.rendered"
      Null
      `shouldBe` Right (buttonNode "ns-foo" (object ["n" .= (9 :: Int)]) "click")

  it "remap-actions(...) works as a bare $-prefixed child directly in the template block, no @-binding needed" $
    runTemplateWithLibs
      "@btn=partial-import(\"one-arg\", {})\n.div(remap-actions($btn({\"arg0\": \"foo\"}).rendered, (a) => $a))"
      Null
      `shouldBe` Right (elem_ "div" [elem_ "div" [NText "foo"]])

  it "remap-actions(...) can wrap a still-incomplete partial-import(...) before it's completed, and the remap still applies once it is" $
    runJsonWithLibs
      "@p=partial-import(\"btn\", {})\n@p2=remap-actions($p, (a) => {\"eventType\": $a.eventType, \"key\": \"ns-`$a.key`\", \"payload\": $a.payload})\n$p2({\"n\": 5}).rendered"
      Null
      `shouldBe` Right (buttonNode "ns-foo" (object ["n" .= (5 :: Int)]) "click")

  it "remap-actions(...) queued on a partial survives currying it one param at a time, applying once it's finally complete" $
    runJsonWithLibs
      "@p=partial-import(\"two-arg-btn\", {})\n@p2=remap-actions($p, (a) => {\"eventType\": $a.eventType, \"key\": \"ns-`$a.key`\", \"payload\": $a.payload})\n@p3=$p2({\"a\": 1})\n@p4=$p3({\"b\": 2})\n$p4.rendered"
      Null
      `shouldBe` Right (buttonNode "ns-foo" (object ["a" .= (1 :: Int), "b" .= (2 :: Int)]) "click")

  it "remap-actions(...) called twice on the same partial-import(...) queues both fns, applied in order once complete" $
    runJsonWithLibs
      "@p=partial-import(\"btn\", {})\n@p2=remap-actions($p, (a) => {\"eventType\": $a.eventType, \"key\": \"inner-`$a.key`\", \"payload\": $a.payload})\n@p3=remap-actions($p2, (a) => {\"eventType\": $a.eventType, \"key\": \"outer-`$a.key`\", \"payload\": $a.payload})\n$p3({\"n\": 5}).rendered"
      Null
      `shouldBe` Right (buttonNode "outer-inner-foo" (object ["n" .= (5 :: Int)]) "click")

  it "a remap-actions(...)-wrapped partial that's still incomplete can't be used where a Json value is required, same as a plain partial" $
    runJsonWithLibs "@p=partial-import(\"btn\", {})\n@p2=remap-actions($p, (a) => $a)\n$p2" Null `shouldSatisfy` isLeft
  where
    divWithText :: Text -> Value
    divWithText t =
      object
        [ "type" .= ("element" :: Text)
        , "tag" .= ("div" :: Text)
        , "attrs" .= object []
        , "action" .= Null
        , "children" .= V.fromList [object ["type" .= ("text" :: Text), "text" .= t]]
        ]

    buttonNode :: Text -> Value -> Text -> Value
    buttonNode key payload label =
      object
        [ "type" .= ("element" :: Text)
        , "tag" .= ("button" :: Text)
        , "attrs" .= object []
        , "action" .= object ["eventType" .= ("on-click" :: Text), "key" .= key, "payload" .= payload]
        , "children" .= V.fromList [object ["type" .= ("text" :: Text), "text" .= label]]
        ]

    button2 :: Text -> Int -> Text -> Value
    button2 key v label = buttonNode key (object ["v" .= v]) label

    buildLibraryTable :: LibraryTable
    buildLibraryTable =
      Map.fromList
        [ ("greeter", ProgramSource (mustParseProgram "@greeting=\"hello `$ctx.name`\"\n.div(\"`$greeting`\")"))
        , ("cyclic", ProgramSource (mustParseProgram "@self=import(\"cyclic\", {})\n.div(\"x\")"))
        , ("one-arg", ProgramSource (mustParseProgram ".div(\"`$ctx.arg0`\")"))
        , ("two-arg", ProgramSource (mustParseProgram ".div(\"`$ctx.a`-`$ctx.b`\")"))
        , ("btn", ProgramSource (mustParseProgram ".button(action(\"on-click\", \"foo\", {\"n\": $ctx.n}), \"click\")"))
        , ("two-actions", ProgramSource (mustParseProgram ".div(.button(action(\"on-click\", \"a\", {\"v\": 1}), \"A\"), .button(action(\"on-click\", \"b\", {\"v\": 2}), \"B\"))"))
        , ("json-lib", JsonSource (mustParseJsonProgram "{\"n\": $ctx.n}"))
        , ("wraps-btn-in-vals", ProgramSource (mustParseProgram "@sub=import(\"btn\", {\"n\": 9})\n.div(\"just text\")"))
        , ("two-arg-btn", ProgramSource (mustParseProgram ".button(action(\"on-click\", \"foo\", {\"a\": $ctx.a, \"b\": $ctx.b}), \"click\")"))
        ]

    mustParseProgram :: Text -> Program
    mustParseProgram src = case parseProgram src of
      Left e -> error ("library fixture failed to parse: " <> show e)
      Right p -> p

    mustParseJsonProgram :: Text -> JsonProgram
    mustParseJsonProgram src = case parseJsonProgram src of
      Left e -> error ("library fixture failed to parse: " <> show e)
      Right p -> p

    runJsonWithLibs :: Text -> Value -> Either String Value
    runJsonWithLibs template ctx = case parseJsonProgram template of
      Left e -> Left ("parse error: " <> show e)
      Right prog -> case evalJsonProgram buildLibraryTable ctx prog of
        Left e -> Left ("eval error: " <> show e)
        Right v -> Right v

    runTemplateWithLibs :: Text -> Value -> Either String Node
    runTemplateWithLibs template ctx = case parseProgram template of
      Left e -> Left ("parse error: " <> show e)
      Right prog -> case evalProgram buildLibraryTable ctx prog of
        Left e -> Left ("eval error: " <> show e)
        Right n -> Right n
