-- | Fixture template/ctx/expected-`Node` triples, exercised end to end
-- | (parse then eval) by `Test.Main`. Covers, per
-- | `specs/templating-language.md`'s "Test suite shape" plus the
-- | 2026-07-17 language extensions: a plain nested element tree, an
-- | `@`-defined computation-block binding referenced via
-- | backtick-interpolation, a bare `$path` value used as a child, `.map`
-- | over an array producing repeated children, an `action:` named-arg
-- | producing `Node`'s `action` field, a kebab-case binding name, a
-- | quoted attribute key alongside a `$name(...)` call used directly as
-- | an attribute value (with attrs-before-children ordering), and array-
-- | /object-literal bindings composed with `$ctx` paths. The
-- | attrs-after-child ordering *rejection* is checked separately in
-- | `Test.Main` (it's a parse failure, not a success/expected-`Node`
-- | pair, so it doesn't fit this fixture shape).
module Test.Fixtures
  ( Fixture
  , fixtures
  ) where

import Prelude

import Data.Argonaut.Core (Json, fromArray, fromNumber, fromObject, fromString, jsonNull)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Foreign.Object as Object
import Templating.Ast (Node(..))

type Fixture =
  { name :: String
  , template :: String
  , ctx :: Json
  , expected :: Node
  }

elem_ :: String -> Array Node -> Node
elem_ tag children = NElement { tag, attrs: Map.empty, action: Nothing, children }

fixtures :: Array Fixture
fixtures =
  [ { name: "plain nested element tree"
    , template: ".div(.p(\"Hello\"))"
    , ctx: jsonNull
    , expected: elem_ "div" [ elem_ "p" [ NText "Hello" ] ]
    }
  , { name: "@-defined computation-block binding via backtick interpolation"
    , template: "@count=cardinality($ctx.items)\n.p(\"there are `$count` item(s)\")"
    , ctx: fromObject (Object.singleton "items" (fromArray (fromString <$> [ "a", "b", "c" ])))
    , expected: elem_ "p" [ NText "there are 3 item(s)" ]
    }
  , { name: "bare $path value as a child"
    , template: ".td($ctx.title)"
    , ctx: fromObject (Object.singleton "title" (fromString "Widget"))
    , expected: elem_ "td" [ NText "Widget" ]
    }
  , { name: "functional map(...) in the template block produces repeated children"
    , template: ".ul(map($ctx.items, (item) => .li($item.name)))"
    , ctx: fromObject (Object.singleton "items" (fromArray [ itemNamed "a", itemNamed "b" ]))
    , expected: elem_ "ul" [ elem_ "li" [ NText "a" ], elem_ "li" [ NText "b" ] ]
    }
  , { name: "action(...) resolves to Node's structured action field"
    , template: ".button(action(\"on-click\", \"select\", {\"itemId\": $ctx.itemId}), \"Select\")"
    , ctx: fromObject (Object.singleton "itemId" (fromString "abc123"))
    , expected: NElement
        { tag: "button"
        , attrs: Map.empty
        , action: Just
            { eventType: "on-click"
            , key: "select"
            , payload: fromObject (Object.singleton "itemId" (fromString "abc123"))
            }
        , children: [ NText "Select" ]
        }
    }
  , { name: "action(...)'s event type is a general expr, not just a literal keyword"
    , template: ".button(action($ctx.eventName, \"select\", {}), \"Select\")"
    , ctx: fromObject (Object.singleton "eventName" (fromString "on-click"))
    , expected: NElement
        { tag: "button"
        , attrs: Map.empty
        , action: Just
            { eventType: "on-click"
            , key: "select"
            , payload: fromObject Object.empty
            }
        , children: [ NText "Select" ]
        }
    }
  , { name: "action(...)'s event type is passed through verbatim, whatever it says"
    , template: ".input(action(\"on-whatever-the-host-calls-it\", \"select\", {}), \"Select\")"
    , ctx: jsonNull
    , expected: NElement
        { tag: "input"
        , attrs: Map.empty
        , action: Just
            { eventType: "on-whatever-the-host-calls-it"
            , key: "select"
            , payload: fromObject Object.empty
            }
        , children: [ NText "Select" ]
        }
    }
  , { name: "kebab-case binding name with a $-prefixed builtin call"
    , template: "@my-var=$cardinality($ctx.items)\n.p(\"`$my-var`\")"
    , ctx: fromObject (Object.singleton "items" (fromArray (fromString <$> [ "a", "b", "c", "d", "e" ])))
    , expected: elem_ "p" [ NText "5" ]
    }
  , { name: "quoted attribute key + $name(...) call value, attrs before children"
    , template: ".foo(\"attr-kebab-case\": $cardinality($ctx.items), \"bar\": \"baz\", .p(\"hi\"))"
    , ctx: fromObject (Object.singleton "items" (fromArray (fromString <$> [ "a", "b", "c" ])))
    , expected: NElement
        { tag: "foo"
        , attrs: Map.fromFoldable [ Tuple "attr-kebab-case" "3", Tuple "bar" "baz" ]
        , action: Nothing
        , children: [ elem_ "p" [ NText "hi" ] ]
        }
    }
  , { name: "array- and object-literal bindings compose with $ctx paths"
    , template:
        """@nums=[1,2,3]
@wrapped={"items": $ctx.items}
.div(
  .p("`$cardinality($nums)`"),
  .p("`$cardinality($wrapped.items)`")
)"""
    , ctx: fromObject (Object.singleton "items" (fromArray (fromString <$> [ "a", "b" ])))
    , expected: elem_ "div" [ elem_ "p" [ NText "3" ], elem_ "p" [ NText "2" ] ]
    }
  , { name: "boolean literal + not/and/or/comparison predicates"
    , template:
        """@is-big=$gt($ctx.count, 10)
@both=$and(true, $is-big)
@either=$or(false, $not($is-big))
.div(
  .p("`$both`"),
  .p("`$either`")
)"""
    , ctx: fromObject (Object.singleton "count" (fromNumber 20.0))
    , expected: elem_ "div" [ elem_ "p" [ NText "true" ], elem_ "p" [ NText "false" ] ]
    }
  , { name: "eq builtin for deep equality"
    , template: """.p("`$eq($ctx.status, "open")`")"""
    , ctx: fromObject (Object.singleton "status" (fromString "open"))
    , expected: elem_ "p" [ NText "true" ]
    }
  , { name: "has builtin is a tolerant presence/absence predicate"
    , template:
        """@present=$has($ctx, "title")
@absent=$has($ctx, "nope")
@arr-in-range=$has($ctx.items, 1)
@arr-out-of-range=$has($ctx.items, 5)
.div(
  .p("`$present`"),
  .p("`$absent`"),
  .p("`$arr-in-range`"),
  .p("`$arr-out-of-range`")
)"""
    , ctx: fromObject
        ( Object.fromFoldable
            [ Tuple "title" (fromString "Widget")
            , Tuple "items" (fromArray (fromString <$> [ "a", "b", "c" ]))
            ]
        )
    , expected: elem_ "div"
        [ elem_ "p" [ NText "true" ]
        , elem_ "p" [ NText "false" ]
        , elem_ "p" [ NText "true" ]
        , elem_ "p" [ NText "false" ]
        ]
    }
  , { name: "lookup builtin for dynamic object/array access, with fallback"
    , template:
        """@key="title"
@idx=1
.div(
  .p("`$lookup($ctx, $key, "N/A")`"),
  .p("`$lookup($ctx.items, $idx, "N/A")`"),
  .p("`$lookup($ctx, "missing", "fallback-value")`"),
  .p("`$lookup($ctx.items, 99, "fallback-value")`")
)"""
    , ctx: fromObject
        ( Object.fromFoldable
            [ Tuple "title" (fromString "Widget")
            , Tuple "items" (fromArray (fromString <$> [ "a", "b", "c" ]))
            ]
        )
    , expected: elem_ "div"
        [ elem_ "p" [ NText "Widget" ]
        , elem_ "p" [ NText "b" ]
        , elem_ "p" [ NText "fallback-value" ]
        , elem_ "p" [ NText "fallback-value" ]
        ]
    }
  , { name: "branch builtin encodes if/elif/else as a value expression"
    , template:
        """@size=$branch("large", $lt($ctx.count, 5), "small", $lt($ctx.count, 20), "medium")
.p("`$size`")"""
    , ctx: fromObject (Object.singleton "count" (fromNumber 12.0))
    , expected: elem_ "p" [ NText "medium" ]
    }
  , { name: "branch builtin falls back when no predicate matches"
    , template:
        """@size=$branch("large", $lt($ctx.count, 5), "small", $lt($ctx.count, 20), "medium")
.p("`$size`")"""
    , ctx: fromObject (Object.singleton "count" (fromNumber 99.0))
    , expected: elem_ "p" [ NText "large" ]
    }
  , { name: "expr-level map(...) composes with the template's functional map(...)"
    , template:
        """@titles=map($ctx.items, (item) => $lookup($item, "title", "?"))
.ul(map($titles, (t) => .li($t)))"""
    , ctx: fromObject (Object.singleton "items" (fromArray [ itemTitled "Alpha", itemTitled "Beta" ]))
    , expected: elem_ "ul" [ elem_ "li" [ NText "Alpha" ], elem_ "li" [ NText "Beta" ] ]
    }
  , { name: "expr-level filter(...) keeps only matching items"
    , template:
        """@big=filter($ctx.nums, (n) => $gt($n, 5))
.p("`$cardinality($big)`")"""
    , ctx: fromObject (Object.singleton "nums" (fromArray (fromNumber <$> [ 1.0, 10.0, 3.0, 8.0 ])))
    , expected: elem_ "p" [ NText "2" ]
    }
  , { name: "expr-level scan(...) is an accumulative fold (scanl semantics: seed first)"
    , template:
        """@flags=scan($ctx.nums, false, (acc, n) => $or($acc, $gt($n, 5)))
.ul(map($flags, (f) => .li($f)))"""
    , ctx: fromObject (Object.singleton "nums" (fromArray (fromNumber <$> [ 1.0, 2.0, 8.0, 3.0 ])))
    , expected: elem_ "ul"
        [ elem_ "li" [ NText "false" ]
        , elem_ "li" [ NText "false" ]
        , elem_ "li" [ NText "false" ]
        , elem_ "li" [ NText "true" ]
        , elem_ "li" [ NText "true" ]
        ]
    }
  , { name: "expr-level fold(...) reduces to a single final value (same step as scan, last only)"
    , template:
        """@any-big=fold($ctx.nums, false, (acc, n) => $or($acc, $gt($n, 5)))
.p("`$any-big`")"""
    , ctx: fromObject (Object.singleton "nums" (fromArray (fromNumber <$> [ 1.0, 2.0, 8.0, 3.0 ])))
    , expected: elem_ "p" [ NText "true" ]
    }
  , { name: "expr-level fold(...) over an empty array returns the seed unchanged"
    , template:
        """@any-big=fold($ctx.nums, false, (acc, n) => $or($acc, $gt($n, 5)))
.p("`$any-big`")"""
    , ctx: fromObject (Object.singleton "nums" (fromArray []))
    , expected: elem_ "p" [ NText "false" ]
    }
  , { name: "concat(...) joins multiple arrays in order"
    , template:
        """@all=concat($ctx.a, $ctx.b, [5, 6])
.ul(map($all, (n) => .li($n)))"""
    , ctx: fromObject
        ( Object.fromFoldable
            [ Tuple "a" (fromArray (fromNumber <$> [ 1.0, 2.0 ]))
            , Tuple "b" (fromArray (fromNumber <$> [ 3.0, 4.0 ]))
            ]
        )
    , expected: elem_ "ul"
        [ elem_ "li" [ NText "1" ]
        , elem_ "li" [ NText "2" ]
        , elem_ "li" [ NText "3" ]
        , elem_ "li" [ NText "4" ]
        , elem_ "li" [ NText "5" ]
        , elem_ "li" [ NText "6" ]
        ]
    }
  , { name: "append(...) adds a single element at the end of an array"
    , template:
        """@grown=append($ctx.items, "new")
.p("`$cardinality($grown)`")"""
    , ctx: fromObject (Object.singleton "items" (fromArray (fromString <$> [ "a", "b" ])))
    , expected: elem_ "p" [ NText "3" ]
    }
  , { name: "template-block branch(...) selects a matching node"
    , template:
        """@is-admin=$eq($ctx.role, "admin")
.div(branch(.p("guest"), $is-admin, .p("admin!")))"""
    , ctx: fromObject (Object.singleton "role" (fromString "admin"))
    , expected: elem_ "div" [ elem_ "p" [ NText "admin!" ] ]
    }
  , { name: "template-block branch(...) falls back to the fallback node"
    , template:
        """@is-admin=$eq($ctx.role, "admin")
.div(branch(.p("guest"), $is-admin, .p("admin!")))"""
    , ctx: fromObject (Object.singleton "role" (fromString "user"))
    , expected: elem_ "div" [ elem_ "p" [ NText "guest" ] ]
    }
  , { name: "a bound lambda is called by name, like a builtin"
    , template:
        """@is-big=(n) => $gt($n, 10)
.div(
  .p("`$is-big(3)`"),
  .p("`$is-big(20)`")
)"""
    , ctx: jsonNull
    , expected: elem_ "div" [ elem_ "p" [ NText "false" ], elem_ "p" [ NText "true" ] ]
    }
  , { name: "a bound lambda is passed to map(...) by reference, not just inline"
    , template:
        """@get-title=(item) => $lookup($item, "title", "?")
@titles=map($ctx.items, $get-title)
.ul(map($titles, (t) => .li($t)))"""
    , ctx: fromObject (Object.singleton "items" (fromArray [ itemTitled "Alpha", itemTitled "Beta" ]))
    , expected: elem_ "ul" [ elem_ "li" [ NText "Alpha" ], elem_ "li" [ NText "Beta" ] ]
    }
  , { name: "a closure captures its defining environment (lexical scoping)"
    , template:
        """@threshold=5
@is-big=(n) => $gt($n, $threshold)
.p("`$is-big(10)`")"""
    , ctx: jsonNull
    , expected: elem_ "p" [ NText "true" ]
    }
  , { name: "a closure can be passed as an argument to another closure (higher-order)"
    , template:
        """@apply=(f, x) => $f($x)
@is-huge=(n) => $gt($n, 100)
.p("`$apply($is-huge, 200)`")"""
    , ctx: jsonNull
    , expected: elem_ "p" [ NText "true" ]
    }
  ]
  where
  itemNamed :: String -> Json
  itemNamed n = fromObject (Object.singleton "name" (fromString n))

  itemTitled :: String -> Json
  itemTitled t = fromObject (Object.singleton "title" (fromString t))
