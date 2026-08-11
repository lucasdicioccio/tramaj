-- | Parses and evaluates each fixture in `Test.Fixtures`, comparing
-- | against the expected `Node` via its derived `Eq`, and `throw`s loudly
-- | on the first mismatch/parse/eval failure — a bare-`Effect` convention
-- | rather than pulling in a spec-runner dependency.
module Test.Main where

import Prelude

import Data.Argonaut.Core (jsonNull)
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Effect (Effect)
import Effect.Class.Console (log)
import Effect.Exception (throw)
import Templating.Eval (evalProgram)
import Templating.Parser (parseProgram)
import Test.Fixtures (Fixture, fixtures)

main :: Effect Unit
main = do
  traverseFixtures fixtures
  log ("All " <> show (arrayLength fixtures) <> " templating fixtures passed.")
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
