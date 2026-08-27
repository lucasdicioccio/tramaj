-- | Grammar checks: what the surface accepts, what it rejects, and what it
-- desugars into.
--
-- The desugaring assertions matter more than they look. Every one of them
-- pins a surface convenience to the core constructors it lowers to, which is
-- the property the language design rests on: the surface may grow, the
-- semantic AST should not. A test here failing means a convenience quietly
-- became a semantic construct.
module Tramaj.ParserSpec (spec) where

import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Test.Hspec
import Tramaj.Ast
import Tramaj.Parser

spec :: Spec
spec = do
  acceptanceSpec
  rejectionSpec
  commentSpec
  desugaringSpec
  programKindSpec

-- | Parses to /something/; what exactly is 'desugaringSpec''s business.
accepts :: String -> Text -> Spec
accepts name src = it name (parseProgram src `shouldSatisfy` isRight)

rejects :: String -> Text -> Spec
rejects name src = it name (parseProgram src `shouldSatisfy` isLeft)

acceptanceSpec :: Spec
acceptanceSpec = describe "accepts" $ do
  accepts "a plain nested element tree" ".div(.p(\"Hello\"))"
  accepts "a fragment as the root" ".(.p(\"a\"), .p(\"b\"))"
  accepts "an empty fragment" ".()"
  accepts "an element with no arguments at all" ".hr()"
  accepts "kebab-case tags and binding names" "@my-var=1\n.my-tag(\"x\")"
  accepts "a quoted attribute key alongside a bare one" ".div(class: \"a\", \"data-id\": 1)"
  accepts "several actions on one element" ".b(action(\"on-click\", \"a\", {}), action(\"on-key\", \"b\", {}))"
  accepts "an element value slot" ".Replicas(value(3))"
  accepts "a bare special form as a child" ".div(fold($ctx.nums, 0, (acc, n) => $acc))"
  accepts "an import as a child" ".div(import(\"lib\", {}).rendered)"
  accepts "a deferred import parameter" "@p=import(\"lib\", {name: ctx(spec.name)})\n$p({})"
  accepts "adapt-actions without a closure" "adapt-actions($x, prefix(\"ns:\"))"
  accepts "adapt-actions with a closure" "adapt-actions($x, prefix(\"ns:\"), (a) => $a)"
  accepts "the identity adaptation" "adapt-actions($x, identity)"
  accepts "a call on a dotted path" "$lib.vals.fn(1)"
  accepts "concat chained several times" "\"a\" <> \"b\" <> \"c\""
  accepts "a parenthesized expression" "(1)"
  accepts "an expression-rooted program" "@n=1\n{\"n\": $n}"
  accepts "a trailing comma in an element's arguments" ".div(\"a\", \"b\",)"
  accepts "a lambda with no parameters" "() => 1"

  -- The v1 regression this replaces: a '.' beginning the next line is a new
  -- element, not a field access on the call that just closed.
  accepts
    "a '.' starting the next line rather than continuing a field access"
    "@x=cardinality($ctx.items)\n.div(\"`$x`\")"

rejectionSpec :: Spec
rejectionSpec = describe "rejects" $ do
  rejects "an attribute after a child" ".div(.p(\"hi\"), class: \"a\")"
  rejects "an action after a child" ".div(.p(\"hi\"), action(\"on-click\", \"a\", {}))"
  rejects "a value slot after a child" ".div(.p(\"hi\"), value(1))"
  rejects "more than one value slot" ".div(value(1), value(2))"

  -- Every static position is static because the grammar refuses anything
  -- else there -- not because evaluation checks it later.
  rejects "an import name that is computed" "@l=import($ctx.name, {})\n.div($l.rendered)"
  rejects "an import name that is interpolated" "@l=import(\"a`$x`\", {})\n.div($l.rendered)"
  rejects "an action key that is computed" ".b(action(\"on-click\", $ctx.key, {}))"
  rejects "an action event that is computed" ".b(action($ctx.evt, \"save\", {}))"
  rejects "an adaptation prefix that is computed" "adapt-actions($x, prefix($ctx.ns))"
  rejects "an adaptation that is an arbitrary function" "adapt-actions($x, (a) => $a)"
  rejects "an unknown adaptation" "adapt-actions($x, replace(\"a\", \"b\"))"

  -- A malformed special form must fail here, not fall through to a
  -- meaningless Call that only fails much later.
  rejects "a malformed import" "import(\"lib\")"
  rejects "a malformed map" "map($xs)"
  rejects "import parameters that are not a parameter list" "import(\"lib\", $ctx)"

  rejects "an unknown escape sequence" "\"a\\qb\""
  rejects "an unterminated string" "\"abc"
  rejects "trailing input after the root" ".div() .span()"

  -- A hyphen is a name character only between two others, which is what
  -- leaves @--@ free to start a comment right after a name.
  rejects "a binding name ending in a hyphen" "@a-=1\n$a"
  rejects "a tag ending in a hyphen" ".div-()"

-- | Comments: @--@ to the end of the line, single-line only.
--
-- The load-bearing assertion is 'leavesNoTrace' -- a commented program and
-- the same program with the comments deleted must parse to the /same/ AST.
-- Anything weaker would pass while comments quietly became a node, or shifted
-- what the parser saw around them.
commentSpec :: Spec
commentSpec = describe "comments" $ do
  accepts "a whole-line comment above the bindings" "-- a heading\n@n=1\n.p($n)"
  accepts "a comment trailing a binding" "@n=1 -- how many\n.p($n)"
  accepts "a comment inside an element's arguments" ".div(\n  class: \"a\", -- the class\n  .p(\"hi\")\n)"
  accepts "a comment between two children" ".div(\n  .p(\"a\"),\n  -- and then\n  .p(\"b\")\n)"
  accepts "a comment as the last line, with no newline after it" ".p(\"hi\")\n-- done"
  accepts "a comment directly after the root, on the same line" ".p(\"hi\") -- done"
  accepts "a file that is comments and one expression" "-- one\n-- two\n1"
  accepts "an empty comment" ".p(\"hi\") --"
  accepts "a second -- inside a comment, which does not nest or close it" "1 -- a -- b"

  leavesNoTrace
    "a comment on its own line, and one trailing a binding"
    "-- the count\n@n=cardinality($ctx.items) -- how many\n.p(\"`$n`\")"
    "@n=cardinality($ctx.items)\n.p(\"`$n`\")"

  leavesNoTrace
    "comments interleaved with an element's arguments"
    ".div(class: \"a\", -- attrs first\n  .p(\"hi\") -- then children\n)"
    ".div(class: \"a\", .p(\"hi\"))"

  -- A comment is whitespace, and whitespace before a '.' is exactly what
  -- separates a new element from a field access on the call that just
  -- closed. So the v1 regression stays fixed with a comment in between.
  leavesNoTrace
    "a comment between a closing ')' and a '.' beginning the next line"
    "@x=cardinality($ctx.items) -- a count\n.div(\"`$x`\")"
    "@x=cardinality($ctx.items)\n.div(\"`$x`\")"

  it "leaves `--` inside a string literal as ordinary text" $
    parseExpr "\"a -- b\"" `shouldBe` Right (StringLit "a -- b")

  it "leaves `--` inside a static string as ordinary text" $
    parseExpr "adapt-actions($x, prefix(\"a--b:\"))"
      `shouldBe` Right (AdaptActions (Path "x" []) (Prefix "a--b:") Nothing)

  -- The name stops at the hyphen pair rather than swallowing it, so this is
  -- a read of `x` followed by a comment -- not a read of a name `x--`.
  it "ends a name at a comment written directly against it" $
    parseExpr "$x-- note" `shouldBe` Right (Path "x" [])

  it "still takes a hyphen between two name characters" $
    parseExpr "$my-var-2" `shouldBe` Right (Path "my-var-2" [])
  where
    leavesNoTrace :: String -> Text -> Text -> Spec
    leavesNoTrace name commented plain =
      it ("leave no trace in the AST: " <> name) $
        parseProgram commented `shouldBe` parseProgram plain

-- | Each case states the desugaring in full: surface on the left, core AST on
-- the right, with nothing in between.
desugaringSpec :: Spec
desugaringSpec = describe "desugars" $ do
  let parsesTo name src expected = it name (parseExpr src `shouldBe` Right expected)

  parsesTo "a plain string to a single literal" "\"hello\"" (StringLit "hello")

  parsesTo
    "escape sequences into the characters they denote, leaving one literal"
    "\"a\\nb\\tc\\\\d\\\"e\""
    (StringLit "a\nb\tc\\d\"e")

  parsesTo "a braced unicode escape" "\"\\u{1F600}\"" (StringLit "\128512")

  parsesTo
    "interpolation into concat over the str builtin"
    "\"n: `$x`!\""
    (Concat (Concat (StringLit "n: ") (Call (Path "str" []) [Path "x" []])) (StringLit "!"))

  parsesTo "an empty string" "\"\"" (StringLit "")

  parsesTo
    "object shorthand into an explicit field reading the same name"
    "{foo, bar: 1}"
    (ObjectLit [("foo", Path "foo" []), ("bar", NumberLit 1)])

  parsesTo
    "a multi-armed branch into nested Branch, fallback innermost"
    "branch(0, $a, 1, $b, 2)"
    (Branch (Path "a" []) (NumberLit 1) (Branch (Path "b" []) (NumberLit 2) (NumberLit 0)))

  parsesTo
    "concat as a left-associative chain"
    "$a <> $b <> $c"
    (Concat (Concat (Path "a" []) (Path "b" [])) (Path "c" []))

  parsesTo
    "a fragment into Fragment, with no wrapper element"
    ".(.p(\"a\"))"
    (Fragment [Element "p" [] NullLit [StringLit "a"]])

  parsesTo
    "an element's arguments into attributes, value slot and children"
    ".div(class: \"a\", action(\"on-click\", \"save\", 1), value(2), \"kid\")"
    ( Element
        "div"
        [Attr "class" (StringLit "a"), ActionAttr "on-click" "save" (NumberLit 1)]
        (NumberLit 2)
        [StringLit "kid"]
    )

  parsesTo
    "an absent value slot into NullLit"
    ".div()"
    (Element "div" [] NullLit [])

  parsesTo
    "import parameters into supplied values and declared context holes"
    "import(\"dep\", {\"name\": \"web\", \"replicas\": ctx(spec.replicas)})"
    (Import "dep" [("name", PExpr (StringLit "web")), ("replicas", PFromContext ["spec", "replicas"])])

  parsesTo
    "import parameter shorthand into a supplied value, not a context hole"
    "import(\"dep\", {name})"
    (Import "dep" [("name", PExpr (Path "name" []))])

  parsesTo
    "an omitted adaptation closure into Nothing"
    "adapt-actions($x, prefix(\"ns:\"))"
    (AdaptActions (Path "x" []) (Prefix "ns:") Nothing)

  parsesTo "a dotted path into one Path, not nested field accesses" "$a.b.c" (Path "a" ["b", "c"])

  parsesTo
    "a field access on a call's result into FieldAccess"
    "$f(1).rendered"
    (FieldAccess (Call (Path "f" []) [NumberLit 1]) ["rendered"])

  parsesTo "the $ prefix on a call as optional" "cardinality($x)" (Call (Path "cardinality" []) [Path "x" []])
  parsesTo "the $ prefix on a call as meaning the same thing" "$cardinality($x)" (Call (Path "cardinality" []) [Path "x" []])

  it "binding lines into nested Lets, in declaration order" $
    parseProgram "@a=1\n@b=$a\n.p($b)"
      `shouldBe` Right
        ( DocumentProgram
            (Let "a" (NumberLit 1) (Let "b" (Path "a" []) (Element "p" [] NullLit [Path "b" []])))
        )

-- | Which kind of program it is follows from the root's own form; there is no
-- mode to declare.
programKindSpec :: Spec
programKindSpec = describe "program kind" $ do
  let isDocument (Right (DocumentProgram _)) = True
      isDocument _ = False
      isExpression (Right (ExpressionProgram _)) = True
      isExpression _ = False

  it "an element root is a document program" $
    parseProgram ".div()" `shouldSatisfy` isDocument
  it "a fragment root is a document program" $
    parseProgram ".()" `shouldSatisfy` isDocument
  it "an object root is an expression program" $
    parseProgram "{\"a\": 1}" `shouldSatisfy` isExpression
  it "bindings do not change the kind" $
    parseProgram "@a=.div()\n{\"a\": 1}" `shouldSatisfy` isExpression
