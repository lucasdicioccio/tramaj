-- | Parses and evaluates each fixture in `Test.Fixtures`, comparing
-- | against the expected `Node` via its derived `Eq`, and `throw`s loudly
-- | on the first mismatch/parse/eval failure — a bare-`Effect` convention
-- | rather than pulling in a spec-runner dependency.
module Test.Main where

import Prelude

import Data.Argonaut.Core (Json, fromArray, fromBoolean, fromNumber, fromObject, fromString, jsonNull, stringify)
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Class.Console (log)
import Effect.Exception (throw)
import Foreign.Object as Object
import Templating.Eval (EvalError, evalJsonProgram, evalProgram)
import Templating.Parser (parseJsonProgram, parseProgram)
import Test.Fixtures (Fixture, fixtures)

main :: Effect Unit
main = do
  traverseFixtures fixtures
  log ("All " <> show (arrayLength fixtures) <> " templating fixtures passed.")
  runJsonFixtures
  checkParseRejected "attrs-after-child is rejected at parse time"
    ".foo(.p(\"hi\"), \"bar\": \"baz\")"
  checkParseRejected "a node can have at most one action(...)"
    ".button(action(\"on-click\", \"a\", {}), action(\"on-click\", \"b\", {}))"
  -- an *unrecognized* event type is no longer a thing: only the "must be a
  -- string" shape is still checked, the vocabulary is the host's
  checkEvalRejected "action(...) rejects a non-string event type"
    ".button(action(42, \"a\", {}))"
  checkEvalRejected "closure arity mismatch is rejected at eval time"
    "@f=(x) => $x\n.p(\"`$f(1,2)`\")"
  checkEvalRejected "a closure can't call itself by name (no recursion)"
    "@fact=(n) => $fact($n)\n.p(\"`$fact(1)`\")"
  checkEvalRejected "a bound closure used as a bare value (not called) is rejected"
    "@f=(x) => $x\n.p(\"`$f`\")"
  where
  arrayLength = foldl (\acc _ -> acc + 1) 0

  traverseFixtures :: Array Fixture -> Effect Unit
  traverseFixtures = foldl (\acc f -> acc *> runFixture f) (pure unit)

-- | For cases that must fail to *parse* at all (ordering, at-most-one
-- | `action(...)`) — a `Fixture` only covers the success path, so these
-- | are checked separately.
checkParseRejected :: String -> String -> Effect Unit
checkParseRejected label template = case parseProgram template of
  Left _ -> log ("ok - " <> label)
  Right _ -> throw (label <> ": expected a parse error, got a successful parse")

-- | For cases that must parse fine but fail at *eval* time (closures'
-- | error cases — arity, no self-recursion, used-without-calling) — a
-- | `Fixture` only covers the success path, so these are checked
-- | separately, same as `checkOrderingRejected` above.
checkEvalRejected :: String -> String -> Effect Unit
checkEvalRejected label template = case parseProgram template of
  Left err -> throw (label <> ": expected this to parse (and fail at eval instead), but parsing itself failed: " <> show err)
  Right program -> case evalProgram jsonNull program of
    Left _ -> log ("ok - " <> label)
    Right _ -> throw (label <> ": expected an eval error, got a successful eval")

runFixture :: Fixture -> Effect Unit
runFixture f = case parseProgram f.template of
  Left err -> throw (f.name <> ": parse failed: " <> show err)
  Right program -> case evalProgram f.ctx program of
    Left err -> throw (f.name <> ": eval failed: " <> show err)
    Right node ->
      if node == f.expected then log ("ok - " <> f.name)
      else
        throw
          ( f.name
              <> ": mismatch\n  expected: "
              <> show f.expected
              <> "\n  actual:   "
              <> show node
          )

-- | Expression-rooted programs (JSON mode, ported from
-- | `templating-hs`'s `Templating.EvalSpec.jsonSpec`). Everything these
-- | exercise below the root (bindings, closures, builtins, map/filter) is
-- | the shared expression language, already covered by `fixtures` above --
-- | these are here to pin down the JSON-mode root itself: an object/array
-- | literal, `map(...)`, a bound lambda passed to `filter`, an
-- | interpolated string, an eval-time error, and that an element root is
-- | rejected at parse time (JSON mode is not template mode).
runJsonFixtures :: Effect Unit
runJsonFixtures = do
  checkJsonOk "an object literal root keeps numbers as numbers, not display strings"
    "@n=cardinality($ctx.items)\n{\"count\": $n, \"first\": $ctx.items}"
    (fromObject (Object.singleton "items" (fromArray (fromString <$> [ "a", "b" ]))))
    (fromObject (Object.fromFoldable [ Tuple "count" (fromNumber 2.0), Tuple "first" (fromArray (fromString <$> [ "a", "b" ])) ]))
  checkJsonOk "an array literal root, with a nested object preserved structurally"
    "[$ctx.who, {\"nested\": {\"deep\": true}}]"
    (fromObject (Object.singleton "who" (fromString "me")))
    (fromArray [ fromString "me", fromObject (Object.singleton "nested" (fromObject (Object.singleton "deep" (fromBoolean true)))) ])
  checkJsonOk "map(...) as the root produces an array of objects"
    "map($ctx.items, (i) => {\"title\": $i.title})"
    (fromObject (Object.singleton "items" (fromArray [ itemTitled "Alpha", itemTitled "Beta" ])))
    (fromArray [ itemTitled "Alpha", itemTitled "Beta" ])
  checkJsonOk "filter(...) and a bound lambda work the same as in template mode"
    "@is-big=(n) => $gt($n, 10)\nfilter($ctx.ns, $is-big)"
    (fromObject (Object.singleton "ns" (fromArray (fromNumber <$> [ 3.0, 20.0, 7.0, 40.0 ]))))
    (fromArray (fromNumber <$> [ 20.0, 40.0 ]))
  checkJsonOk "a plain interpolated string root evaluates to a JSON string"
    "\"there are `cardinality($ctx.items)` item(s)\""
    (fromObject (Object.singleton "items" (fromArray (fromNumber <$> [ 1.0, 2.0, 3.0 ]))))
    (fromString "there are 3 item(s)")
  checkJsonEvalRejected "an unbound name in the root is an eval error, not a parse error"
    "{\"x\": $nope}"
  checkJsonParseRejected "an element root is rejected -- that is template mode, not JSON mode"
    ".div(\"hi\")"
  where
  itemTitled :: String -> Json
  itemTitled title = fromObject (Object.singleton "title" (fromString title))

  checkJsonOk :: String -> String -> Json -> Json -> Effect Unit
  checkJsonOk label template ctx expected = case parseJsonProgram template of
    Left err -> throw (label <> ": parse failed: " <> show err)
    Right program -> case evalJsonProgram ctx program of
      Left err -> throw (label <> ": eval failed: " <> show err)
      Right actual ->
        if actual == expected then log ("ok - " <> label)
        else
          throw
            ( label
                <> ": mismatch\n  expected: "
                <> stringify expected
                <> "\n  actual:   "
                <> stringify actual
            )

  checkJsonEvalRejected :: String -> String -> Effect Unit
  checkJsonEvalRejected label template = case parseJsonProgram template of
    Left err -> throw (label <> ": expected this to parse (and fail at eval instead), but parsing itself failed: " <> show err)
    Right program -> case evalJsonProgram jsonNull program of
      Left (_ :: EvalError) -> log ("ok - " <> label)
      Right _ -> throw (label <> ": expected an eval error, got a successful eval")

  checkJsonParseRejected :: String -> String -> Effect Unit
  checkJsonParseRejected label template = case parseJsonProgram template of
    Left _ -> log ("ok - " <> label)
    Right _ -> throw (label <> ": expected a parse error, got a successful parse")
