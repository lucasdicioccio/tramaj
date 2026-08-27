-- | Template / context / expected-output triples, exercised end to end
-- | (parse then eval then serialize) by `Test.Main`.
-- |
-- | Both the context and the expectation are written as **JSON text**, and
-- | the expectation is the normative `specs/node-json.md` representation
-- | rather than a `Node` built with constructors. That is deliberate: the
-- | Haskell suite asserts against the same representation, so a fixture
-- | here and its Haskell counterpart can be compared by reading them, and
-- | the corpus is already in the shape a shared cross-implementation
-- | conformance runner would want.
-- |
-- | `kind` says which half of the language a fixture exercises: a
-- | `Document` fixture must evaluate to a document, an `Expression` one to
-- | an ordinary value.
module Test.Fixtures
  ( Fixture
  , Kind(..)
  , fixtures
  ) where

import Prelude

import Data.String.Common (joinWith)

data Kind
  = Document
  | Expression

derive instance eqKind :: Eq Kind

type Fixture =
  { name :: String
  , kind :: Kind
  , template :: String
  , ctx :: String
  , expected :: String
  }

-- | A text node in the normative representation, for readability below.
text :: String -> String
text value = "{\"type\":\"text\",\"value\":" <> value <> ",\"annotations\":{}}"

el :: String -> Array String -> String
el tag children = elFull tag [] "null" children

elFull :: String -> Array String -> String -> Array String -> String
elFull tag attrs value children =
  "{\"type\":\"element\",\"tag\":\"" <> tag
    <> "\",\"attributes\":["
    <> joinWith "," attrs
    <> "],\"value\":"
    <> value
    <> ",\"children\":["
    <> joinWith "," children
    <> "],\"annotations\":{}}"

frag :: Array String -> String
frag children = "{\"type\":\"fragment\",\"children\":[" <> joinWith "," children <> "],\"annotations\":{}}"

attr :: String -> String -> String
attr name value = "{\"kind\":\"attribute\",\"name\":\"" <> name <> "\",\"value\":" <> value <> "}"

action :: String -> String -> String -> String
action event key payload =
  "{\"kind\":\"action\",\"event\":\"" <> event <> "\",\"key\":\"" <> key <> "\",\"payload\":" <> payload <> "}"

fixtures :: Array Fixture
fixtures =
  [ { name: "plain nested element tree"
    , kind: Document
    , template: ".div(.p(\"Hello\"))"
    , ctx: "null"
    , expected: el "div" [ el "p" [ text "\"Hello\"" ] ]
    }
  , { name: "binding referenced through backtick interpolation"
    , kind: Document
    , template: "@count=cardinality($ctx.items)\n.p(\"there are `$count` item(s)\")"
    , ctx: "{\"items\": [\"a\", \"b\", \"c\"]}"
    , expected: el "p" [ text "\"there are 3 item(s)\"" ]
    }
  , { name: "a scalar child keeps its type instead of being stringified"
    , kind: Document
    , template: ".td($ctx.count)"
    , ctx: "{\"count\": 3}"
    , expected: el "td" [ text "3" ]
    }
  , { name: "booleans, null and objects survive as children unconverted"
    , kind: Document
    , template: ".div(true, null, {\"a\": 1})"
    , ctx: "null"
    , expected: el "div" [ text "true", text "null", text "{\"a\":1}" ]
    }
  , { name: "attribute values stay values rather than display strings"
    , kind: Document
    , template: ".div(count: $ctx.n, tags: [1, 2], on: true)"
    , ctx: "{\"n\": 3}"
    , expected: elFull "div" [ attr "count" "3", attr "tags" "[1,2]", attr "on" "true" ] "null" []
    }
  , { name: "the element value slot, and its null default"
    , kind: Document
    , template: ".Replicas(value($ctx.n))"
    , ctx: "{\"n\": 3}"
    , expected: elFull "Replicas" [] "3" []
    }
  , { name: "map produces repeated children"
    , kind: Document
    , template: ".ul(map($ctx.items, (i) => .li($i.name)))"
    , ctx: "{\"items\": [{\"name\": \"a\"}, {\"name\": \"b\"}]}"
    , expected: el "ul" [ el "li" [ text "\"a\"" ], el "li" [ text "\"b\"" ] ]
    }
  , { name: "a mapped array splices among ordinary siblings"
    , kind: Document
    , template: ".ul(.li(\"first\"), map($ctx.items, (i) => .li($i.name)), .li(\"last\"))"
    , ctx: "{\"items\": [{\"name\": \"a\"}]}"
    , expected: el "ul" [ el "li" [ text "\"first\"" ], el "li" [ text "\"a\"" ], el "li" [ text "\"last\"" ] ]
    }
  , { name: "a fragment introduces siblings with no wrapper"
    , kind: Document
    , template: ".(.p(\"one\"), .p(\"two\"))"
    , ctx: "null"
    , expected: frag [ el "p" [ text "\"one\"" ], el "p" [ text "\"two\"" ] ]
    }
  , { name: "a nested fragment stays a real node rather than being flattened"
    , kind: Document
    , template: ".div(.(.p(\"a\")))"
    , ctx: "null"
    , expected: el "div" [ frag [ el "p" [ text "\"a\"" ] ] ]
    }
  , { name: "a fragment is an ordinary value: bound, then passed to a lambda"
    , kind: Document
    , template: "@kids=.(.p(\"a\"), .p(\"b\"))\n@panel=(t, c) => .section(.h2($t), $c)\n$panel(\"T\", $kids)"
    , ctx: "null"
    , expected:
        el "section"
          [ el "h2" [ text "\"T\"" ]
          , frag [ el "p" [ text "\"a\"" ], el "p" [ text "\"b\"" ] ]
          ]
    }
  , { name: "a document bound to a name is spliced, not stringified"
    , kind: Document
    , template: "@header=.header(.h1(\"T\"))\n.main($header)"
    , ctx: "null"
    , expected: el "main" [ el "header" [ el "h1" [ text "\"T\"" ] ] ]
    }
  , { name: "several actions on one element, in source order with attributes"
    , kind: Document
    , template: ".b(class: \"c\", action(\"on-click\", \"a\", {}), action(\"on-key\", \"b\", {}))"
    , ctx: "null"
    , expected: elFull "b" [ attr "class" "\"c\"", action "on-click" "a" "{}", action "on-key" "b" "{}" ] "null" []
    }
  , { name: "an action payload is computed from the context"
    , kind: Document
    , template: ".b(action(\"on-click\", \"deploy\", {\"id\": $ctx.id}), \"Go\")"
    , ctx: "{\"id\": 1}"
    , expected: elFull "b" [ action "on-click" "deploy" "{\"id\":1}" ] "null" [ text "\"Go\"" ]
    }
  , { name: "a kebab-case tag and binding name"
    , kind: Document
    , template: "@my-var=\"x\"\n.my-tag($my-var)"
    , ctx: "null"
    , expected: el "my-tag" [ text "\"x\"" ]
    }
  , { name: "a quoted attribute key alongside a bare one"
    , kind: Document
    , template: ".div(class: \"a\", \"data-id\": $ctx.id)"
    , ctx: "{\"id\": 7}"
    , expected: elFull "div" [ attr "class" "\"a\"", attr "data-id" "7" ] "null" []
    }
  , { name: "branch selects a document and leaves the other arm unevaluated"
    , kind: Document
    , template: ".div(branch(.p(\"fallback\"), eq($ctx.s, \"ready\"), .p(\"ready\")))"
    , ctx: "{\"s\": \"ready\"}"
    , expected: el "div" [ el "p" [ text "\"ready\"" ] ]
    }
  , { name: "an unreached branch arm's errors never surface"
    , kind: Document
    , template: ".div(branch(.p(\"fallback\"), false, $nope.deeply.broken))"
    , ctx: "null"
    , expected: el "div" [ el "p" [ text "\"fallback\"" ] ]
    }
  , { name: "escape sequences resolve, including a braced unicode escape"
    , kind: Expression
    , template: "\"a\\tb\\nc\\u{1F600}\""
    , ctx: "null"
    , expected: "\"a\\tb\\nc\\ud83d\\ude00\""
    }
  , { name: "an expression program evaluates to an ordinary value"
    , kind: Expression
    , template: "@n=cardinality($ctx.items)\n{\"count\": $n, \"first\": $ctx.items}"
    , ctx: "{\"items\": [\"a\", \"b\"]}"
    , expected: "{\"count\": 2, \"first\": [\"a\", \"b\"]}"
    }
  , { name: "object shorthand reads the binding of the same name"
    , kind: Expression
    , template: "@foo=1\n@bar=2\n{foo, bar}"
    , ctx: "null"
    , expected: "{\"foo\": 1, \"bar\": 2}"
    }
  , { name: "concat joins strings"
    , kind: Expression
    , template: "\"a\" <> \"b\" <> \"c\""
    , ctx: "null"
    , expected: "\"abc\""
    }
  , { name: "concat appends arrays"
    , kind: Expression
    , template: "[1, 2] <> [3]"
    , ctx: "null"
    , expected: "[1, 2, 3]"
    }
  , { name: "concat merges objects right-biased"
    , kind: Expression
    , template: "{\"a\": 1, \"b\": 2} <> {\"b\": 3, \"c\": 4}"
    , ctx: "null"
    , expected: "{\"a\": 1, \"b\": 3, \"c\": 4}"
    }
  , { name: "map used as a value produces an array"
    , kind: Expression
    , template: "map($ctx.items, (i) => $i.name)"
    , ctx: "{\"items\": [{\"name\": \"a\"}, {\"name\": \"b\"}]}"
    , expected: "[\"a\", \"b\"]"
    }
  , { name: "filter"
    , kind: Expression
    , template: "filter($ctx.xs, (x) => gt($x, 1))"
    , ctx: "{\"xs\": [1, 2, 3]}"
    , expected: "[2, 3]"
    }
  , { name: "scan keeps the initial accumulator and every step"
    , kind: Expression
    , template: "scan($ctx.xs, 0, (a, x) => $x)"
    , ctx: "{\"xs\": [1, 2]}"
    , expected: "[0, 1, 2]"
    }
  , { name: "fold keeps only the final accumulator"
    , kind: Expression
    , template: "fold($ctx.xs, 0, (a, x) => $x)"
    , ctx: "{\"xs\": [1, 2]}"
    , expected: "2"
    }
  , { name: "a closure captures the environment where it was written"
    , kind: Expression
    , template: "@t=10\n@big=(x) => gt($x, $t)\n$big(42)"
    , ctx: "null"
    , expected: "true"
    }
  , { name: "a builtin can be passed by reference"
    , kind: Expression
    , template: "map($ctx.xs, $not)"
    , ctx: "{\"xs\": [true, false]}"
    , expected: "[false, true]"
    }
  , { name: "str renders scalars, with numbers as ECMAScript renders them"
    , kind: Expression
    , template: "[str(\"hi\"), str(null), str(true), str(3), str(1.5), str(0.05), str(123456789)]"
    , ctx: "null"
    , expected: "[\"hi\", \"\", \"true\", \"3\", \"1.5\", \"0.05\", \"123456789\"]"
    }
  , { name: "str renders a large integer without a fractional part"
    -- v1 rendered this "100000000000.0" here: its integrality test went
    -- through a 32-bit Int.
    , kind: Expression
    , template: "str(100000000000)"
    , ctx: "null"
    , expected: "\"100000000000\""
    }
  , { name: "str switches to scientific notation where ECMAScript does"
    , kind: Expression
    , template: "[str(1000000000000000000000), str(0.0000001)]"
    , ctx: "null"
    , expected: "[\"1e+21\", \"1e-7\"]"
    }
  , { name: "str renders structures as compact JSON with sorted keys"
    -- v1 rendered these through the host's own show on the Haskell side,
    -- leaking "Array [Number 1.0,Number 2.0]" into template output.
    , kind: Expression
    , template: "[str([1, 2]), str({\"b\": 2, \"a\": [1, {\"c\": true}]})]"
    , ctx: "null"
    , expected: "[\"[1,2]\", \"{\\\"a\\\":[1,{\\\"c\\\":true}],\\\"b\\\":2}\"]"
    }
  , { name: "str escapes a nested string but leaves a bare one raw"
    , kind: Expression
    , template: "[str([\"a\\\"b\"]), str(\"a\\\"b\")]"
    , ctx: "null"
    , expected: "[\"[\\\"a\\\\\\\"b\\\"]\", \"a\\\"b\"]"
    }
  , { name: "interpolation uses str"
    , kind: Expression
    , template: "\"n=`$ctx.xs`\""
    , ctx: "{\"xs\": [1, 2]}"
    , expected: "\"n=[1,2]\""
    }
  , { name: "branch selects a value by the first true predicate"
    , kind: Expression
    , template: "branch(\"unknown\", eq($ctx.s, \"ready\"), \"ready\", eq($ctx.s, \"err\"), \"error\")"
    , ctx: "{\"s\": \"err\"}"
    , expected: "\"error\""
    }
  ]
