-- | End-to-end (parse then eval) fixtures ported one-for-one from
-- @../templating/test/Test/Fixtures.purs@ -- same template strings, same
-- input contexts, same expected 'Node' trees, to confirm this Haskell port
-- and the PureScript original agree on the language's actual behavior, not
-- just its grammar.
module Templating.EvalSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Vector as V
import Templating.Ast
import Templating.Eval (evalProgram)
import Templating.Parser (parseProgram)
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
  Right prog -> case evalProgram ctx prog of
    Left e -> Left ("eval error: " <> show e)
    Right n -> Right n

spec :: Spec
spec = describe "Templating end-to-end fixtures (ported from the PureScript templating package)" $ do
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
