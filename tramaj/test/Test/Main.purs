-- | Parses and evaluates each fixture in `Test.Fixtures`, comparing
-- | against the expected `Node` via its derived `Eq`, and `throw`s loudly
-- | on the first mismatch/parse/eval failure — a bare-`Effect` convention
-- | rather than pulling in a spec-runner dependency.
module Test.Main where

import Prelude

import Data.Argonaut.Core (Json, fromArray, fromBoolean, fromNumber, fromObject, fromString, jsonNull, stringify)
import Data.Either (Either(..))
import Data.Foldable (foldl)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Class.Console (log)
import Effect.Exception (throw)
import Foreign.Object as Object
import Tramaj.Ast (JsonProgram, Node(..), Program)
import Tramaj.Eval (EvalError, LibrarySource(..), LibraryTable, evalJsonProgram, evalProgram)
import Tramaj.Parser (parseJsonProgram, parseProgram)
import Test.Fixtures (Fixture, fixtures)

main :: Effect Unit
main = do
  traverseFixtures fixtures
  log ("All " <> show (arrayLength fixtures) <> " tramaj fixtures passed.")
  runJsonFixtures
  runImportTests
  checkParseRejected "attrs-after-child is rejected at parse time"
    ".foo(.p(\"hi\"), \"bar\": \"baz\")"
  checkParseRejected "a node can have at most one action(...)"
    ".button(action(\"on-click\", \"a\", {}), action(\"on-click\", \"b\", {}))"
  checkParseRejected "import(...)'s name must be a string literal, not a computed expr"
    "@bar=import($ctx.libname, {})\n.div($bar.rendered)"
  checkParseRejected "partial-import(...)'s name must be a string literal, not a computed expr"
    "@bar=partial-import($ctx.libname, {})\n.div($bar.rendered)"
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
  Right program -> case evalProgram Map.empty jsonNull program of
    Left _ -> log ("ok - " <> label)
    Right _ -> throw (label <> ": expected an eval error, got a successful eval")

runFixture :: Fixture -> Effect Unit
runFixture f = case parseProgram f.template of
  Left err -> throw (f.name <> ": parse failed: " <> show err)
  Right program -> case evalProgram Map.empty f.ctx program of
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
-- | `tramaj-hs`'s `Tramaj.EvalSpec.jsonSpec`). Everything these
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
  checkJsonParseRejected "import(...)'s name must be a string literal, not a computed expr"
    "import($ctx.libname, {})"
  where
  itemTitled :: String -> Json
  itemTitled title = fromObject (Object.singleton "title" (fromString title))

  checkJsonOk :: String -> String -> Json -> Json -> Effect Unit
  checkJsonOk label template ctx expected = case parseJsonProgram template of
    Left err -> throw (label <> ": parse failed: " <> show err)
    Right program -> case evalJsonProgram Map.empty ctx program of
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
    Right program -> case evalJsonProgram Map.empty jsonNull program of
      Left (_ :: EvalError) -> log ("ok - " <> label)
      Right _ -> throw (label <> ": expected an eval error, got a successful eval")

  checkJsonParseRejected :: String -> String -> Effect Unit
  checkJsonParseRejected label template = case parseJsonProgram template of
    Left _ -> log ("ok - " <> label)
    Right _ -> throw (label <> ": expected a parse error, got a successful parse")

-- | `import`/`partial-import` fixtures. Uses a small hand-built
-- | `LibraryTable` (parsed once, below) rather than `Test.Fixtures`'
-- | `Fixture` shape, since these need a library store alongside the usual
-- | template/ctx that `Fixture` doesn't carry.
runImportTests :: Effect Unit
runImportTests = do
  libs <- buildLibraryTable
  checkJsonOk "import(...): .rendered is the library's evaluated template, spliced via nodeToJson"
    "@bar=import(\"greeter\", {\"name\": \"World\"})\n$bar.rendered"
    libs
    jsonNull
    (fromObject (Object.fromFoldable [ Tuple "type" (fromString "element"), Tuple "tag" (fromString "div"), Tuple "attrs" (fromObject Object.empty), Tuple "action" jsonNull, Tuple "children" (fromArray [ fromObject (Object.fromFoldable [ Tuple "type" (fromString "text"), Tuple "text" (fromString "hello World") ]) ]) ]))
  checkJsonOk "import(...): .vals exposes the library's own bindings"
    "@bar=import(\"greeter\", {\"name\": \"World\"})\n$bar.vals.greeting"
    libs
    jsonNull
    (fromString "hello World")
  checkJsonEvalRejectedWith libs "import(...) with an unknown library name is an eval error"
    "import(\"nope\", {})"
  checkJsonEvalRejectedWith libs "import(...) with an unknown library name is an eval error (via bound name)"
    "@bar=import(\"nope\", {})\n$bar.rendered"
  checkJsonEvalRejectedWith libs "a self-importing library fails as an import cycle, not a stack overflow"
    "@bar=import(\"cyclic\", {})\n$bar.rendered"
  checkJsonEvalRejectedWith libs "a whole import result (VEnv) can't be used where a Json value is required"
    "@bar=import(\"greeter\", {\"name\": \"World\"})\n$bar"
  checkJsonOk "partial-import(...) with already-complete params matches import(...) with the same params"
    "@a=import(\"one-arg\", {\"arg0\": \"foo\"})\n@b=partial-import(\"one-arg\", {\"arg0\": \"foo\"})\n[$a.rendered, $b.rendered]"
    libs
    jsonNull
    (let node = fromObject (Object.fromFoldable [ Tuple "type" (fromString "element"), Tuple "tag" (fromString "div"), Tuple "attrs" (fromObject Object.empty), Tuple "action" jsonNull, Tuple "children" (fromArray [ fromObject (Object.fromFoldable [ Tuple "type" (fromString "text"), Tuple "text" (fromString "foo") ]) ]) ]) in fromArray [ node, node ])
  checkJsonEvalRejectedWith libs "an incomplete partial-import(...) can't be used where a Json value is required"
    "@p=partial-import(\"one-arg\", {})\n$p"
  checkJsonOk "completing a partial-import(...) by calling it matches a direct import(...) with the merged params"
    "@direct=import(\"one-arg\", {\"arg0\": \"foo\"})\n@p=partial-import(\"one-arg\", {})\n@done=$p({\"arg0\": \"foo\"})\n[$direct.rendered, $done.rendered]"
    libs
    jsonNull
    (let node = fromObject (Object.fromFoldable [ Tuple "type" (fromString "element"), Tuple "tag" (fromString "div"), Tuple "attrs" (fromObject Object.empty), Tuple "action" jsonNull, Tuple "children" (fromArray [ fromObject (Object.fromFoldable [ Tuple "type" (fromString "text"), Tuple "text" (fromString "foo") ]) ]) ]) in fromArray [ node, node ])
  checkJsonOk "partial-import(...) currying two missing params one at a time matches supplying both up front"
    "@direct=import(\"two-arg\", {\"a\": \"x\", \"b\": \"y\"})\n@p=partial-import(\"two-arg\", {})\n@p2=$p({\"a\": \"x\"})\n@done=$p2({\"b\": \"y\"})\n[$direct.rendered, $done.rendered]"
    libs
    jsonNull
    (let node = fromObject (Object.fromFoldable [ Tuple "type" (fromString "element"), Tuple "tag" (fromString "div"), Tuple "attrs" (fromObject Object.empty), Tuple "action" jsonNull, Tuple "children" (fromArray [ fromObject (Object.fromFoldable [ Tuple "type" (fromString "text"), Tuple "text" (fromString "x-y") ]) ]) ]) in fromArray [ node, node ])
  checkJsonEvalRejectedWith libs "partial-import(...) still hard-errors for a reason unrelated to missing ctx params"
    "partial-import(\"nope\", {})"
  checkJsonOk "completing a partial-import(...) and chaining .rendered directly, no intermediate binding"
    "@p=partial-import(\"one-arg\", {})\n$p({\"arg0\": \"foo\"}).rendered"
    libs
    jsonNull
    (fromObject (Object.fromFoldable [ Tuple "type" (fromString "element"), Tuple "tag" (fromString "div"), Tuple "attrs" (fromObject Object.empty), Tuple "action" jsonNull, Tuple "children" (fromArray [ fromObject (Object.fromFoldable [ Tuple "type" (fromString "text"), Tuple "text" (fromString "foo") ]) ]) ]))
  checkTemplateOkWithLibs "completing a partial-import(...) and chaining .rendered as a bare child, in the template block"
    "@p=partial-import(\"one-arg\", {})\n.div($p({\"arg0\": \"foo\"}).rendered)"
    libs
    jsonNull
    (NElement { tag: "div", attrs: Map.empty, action: Nothing, children: [ NElement { tag: "div", attrs: Map.empty, action: Nothing, children: [ NText "foo" ] } ] })
  checkJsonOk "remap-actions(...) rewrites an action's key (string-interpolation prefix) and passes the payload through"
    "@bar=import(\"btn\", {\"n\": 5})\n@remapped=remap-actions($bar.rendered, (a) => {\"eventType\": $a.eventType, \"key\": \"ns-`$a.key`\", \"payload\": $a.payload})\n$remapped"
    libs
    jsonNull
    (fromObject
        ( Object.fromFoldable
            [ Tuple "type" (fromString "element")
            , Tuple "tag" (fromString "button")
            , Tuple "attrs" (fromObject Object.empty)
            , Tuple "action" (fromObject (Object.fromFoldable [ Tuple "eventType" (fromString "on-click"), Tuple "key" (fromString "ns-foo"), Tuple "payload" (fromObject (Object.singleton "n" (fromNumber 5.0))) ]))
            , Tuple "children" (fromArray [ fromObject (Object.fromFoldable [ Tuple "type" (fromString "text"), Tuple "text" (fromString "click") ]) ])
            ]
        )
    )
  checkJsonOk "remap-actions(...)'s function can rewrite the payload as a function of the original key and payload"
    "@bar=import(\"btn\", {\"n\": 5})\n@remapped=remap-actions($bar.rendered, (a) => {\"eventType\": $a.eventType, \"key\": $a.key, \"payload\": {\"from\": $a.key, \"orig\": $a.payload}})\n$remapped"
    libs
    jsonNull
    (fromObject
        ( Object.fromFoldable
            [ Tuple "type" (fromString "element")
            , Tuple "tag" (fromString "button")
            , Tuple "attrs" (fromObject Object.empty)
            , Tuple "action" (fromObject (Object.fromFoldable [ Tuple "eventType" (fromString "on-click"), Tuple "key" (fromString "foo"), Tuple "payload" (fromObject (Object.fromFoldable [ Tuple "from" (fromString "foo"), Tuple "orig" (fromObject (Object.singleton "n" (fromNumber 5.0))) ])) ]))
            , Tuple "children" (fromArray [ fromObject (Object.fromFoldable [ Tuple "type" (fromString "text"), Tuple "text" (fromString "click") ]) ])
            ]
        )
    )
  checkJsonOk "remap-actions(...) recurses through every action in the subtree, not just the root"
    "@bar=import(\"two-actions\", {})\n@remapped=remap-actions($bar.rendered, (a) => {\"eventType\": $a.eventType, \"key\": \"ns-`$a.key`\", \"payload\": $a.payload})\n$remapped"
    libs
    jsonNull
    ( let
        button k v label = fromObject
          ( Object.fromFoldable
              [ Tuple "type" (fromString "element")
              , Tuple "tag" (fromString "button")
              , Tuple "attrs" (fromObject Object.empty)
              , Tuple "action" (fromObject (Object.fromFoldable [ Tuple "eventType" (fromString "on-click"), Tuple "key" (fromString k), Tuple "payload" (fromObject (Object.singleton "v" (fromNumber v))) ]))
              , Tuple "children" (fromArray [ fromObject (Object.fromFoldable [ Tuple "type" (fromString "text"), Tuple "text" (fromString label) ]) ])
              ]
          )
      in
        fromObject
          ( Object.fromFoldable
              [ Tuple "type" (fromString "element")
              , Tuple "tag" (fromString "div")
              , Tuple "attrs" (fromObject Object.empty)
              , Tuple "action" jsonNull
              , Tuple "children" (fromArray [ button "ns-a" 1.0 "A", button "ns-b" 2.0 "B" ])
              ]
          )
    )
  checkJsonOk "remap-actions(...) is a no-op (and never calls the function) on a node with no action anywhere"
    "@bar=import(\"greeter\", {\"name\": \"World\"})\n@remapped=remap-actions($bar.rendered, (a) => $nonexistent)\n$remapped"
    libs
    jsonNull
    (fromObject (Object.fromFoldable [ Tuple "type" (fromString "element"), Tuple "tag" (fromString "div"), Tuple "attrs" (fromObject Object.empty), Tuple "action" jsonNull, Tuple "children" (fromArray [ fromObject (Object.fromFoldable [ Tuple "type" (fromString "text"), Tuple "text" (fromString "hello World") ]) ]) ]))
  checkJsonEvalRejectedWith libs "remap-actions(...) on something that isn't a rendered node (a plain Json value) is a clear error"
    "remap-actions(5, (a) => $a)"
  checkJsonEvalRejectedWith libs "remap-actions(...)'s function returning a malformed record (missing key) is a clear error, not a silently-dropped action"
    "@bar=import(\"btn\", {\"n\": 5})\n@remapped=remap-actions($bar.rendered, (a) => {\"eventType\": $a.eventType, \"payload\": $a.payload})\n$remapped"
  checkJsonOk "remap-actions(...) accepts an import(...) result directly (no .rendered projection needed), remapping in place and keeping .vals"
    "@bar=import(\"btn\", {\"n\": 5})\n@remapped=remap-actions($bar, (a) => {\"eventType\": $a.eventType, \"key\": \"ns-`$a.key`\", \"payload\": $a.payload})\n$remapped.rendered"
    libs
    jsonNull
    (fromObject
        ( Object.fromFoldable
            [ Tuple "type" (fromString "element")
            , Tuple "tag" (fromString "button")
            , Tuple "attrs" (fromObject Object.empty)
            , Tuple "action" (fromObject (Object.fromFoldable [ Tuple "eventType" (fromString "on-click"), Tuple "key" (fromString "ns-foo"), Tuple "payload" (fromObject (Object.singleton "n" (fromNumber 5.0))) ]))
            , Tuple "children" (fromArray [ fromObject (Object.fromFoldable [ Tuple "type" (fromString "text"), Tuple "text" (fromString "click") ]) ])
            ]
        )
    )
  checkJsonOk "remap-actions(...) accepts a partial-import(...) result directly, once completed"
    "@p=partial-import(\"btn\", {})\n@remapped=remap-actions($p({\"n\": 5}), (a) => {\"eventType\": $a.eventType, \"key\": \"ns-`$a.key`\", \"payload\": $a.payload})\n$remapped.rendered"
    libs
    jsonNull
    (fromObject
        ( Object.fromFoldable
            [ Tuple "type" (fromString "element")
            , Tuple "tag" (fromString "button")
            , Tuple "attrs" (fromObject Object.empty)
            , Tuple "action" (fromObject (Object.fromFoldable [ Tuple "eventType" (fromString "on-click"), Tuple "key" (fromString "ns-foo"), Tuple "payload" (fromObject (Object.singleton "n" (fromNumber 5.0))) ]))
            , Tuple "children" (fromArray [ fromObject (Object.fromFoldable [ Tuple "type" (fromString "text"), Tuple "text" (fromString "click") ]) ])
            ]
        )
    )
  checkJsonOk "remap-actions(...) on an import(...) result still surfaces .vals unchanged alongside the remapped .rendered"
    "@bar=import(\"greeter\", {\"name\": \"World\"})\n@remapped=remap-actions($bar, (a) => $a)\n$remapped.vals.greeting"
    libs
    jsonNull
    (fromString "hello World")
  checkJsonOk "remap-actions(...) on a JSON-mode import's result (whose \"rendered\" is plain Json, not a node) is a no-op, not an error"
    "@bar=import(\"json-lib\", {\"n\": 5})\n@remapped=remap-actions($bar, (a) => $a)\n$remapped.rendered"
    libs
    jsonNull
    (fromObject (Object.singleton "n" (fromNumber 5.0)))
  checkJsonOk "remap-actions(...) recurses into .vals too, reaching a sub-import's action even when it isn't spliced into the outer .rendered"
    "@bar=import(\"wraps-btn-in-vals\", {})\n@remapped=remap-actions($bar, (a) => {\"eventType\": $a.eventType, \"key\": \"ns-`$a.key`\", \"payload\": $a.payload})\n$remapped.vals.sub.rendered"
    libs
    jsonNull
    (fromObject
        ( Object.fromFoldable
            [ Tuple "type" (fromString "element")
            , Tuple "tag" (fromString "button")
            , Tuple "attrs" (fromObject Object.empty)
            , Tuple "action" (fromObject (Object.fromFoldable [ Tuple "eventType" (fromString "on-click"), Tuple "key" (fromString "ns-foo"), Tuple "payload" (fromObject (Object.singleton "n" (fromNumber 9.0))) ]))
            , Tuple "children" (fromArray [ fromObject (Object.fromFoldable [ Tuple "type" (fromString "text"), Tuple "text" (fromString "click") ]) ])
            ]
        )
    )
  checkTemplateOkWithLibs "remap-actions(...) works as a bare $-prefixed child directly in the template block, no @-binding needed"
    "@btn=partial-import(\"one-arg\", {})\n.div(remap-actions($btn({\"arg0\": \"foo\"}).rendered, (a) => $a))"
    libs
    jsonNull
    (NElement { tag: "div", attrs: Map.empty, action: Nothing, children: [ NElement { tag: "div", attrs: Map.empty, action: Nothing, children: [ NText "foo" ] } ] })
  checkJsonOk "remap-actions(...) can wrap a still-incomplete partial-import(...) before it's completed, and the remap still applies once it is"
    "@p=partial-import(\"btn\", {})\n@p2=remap-actions($p, (a) => {\"eventType\": $a.eventType, \"key\": \"ns-`$a.key`\", \"payload\": $a.payload})\n$p2({\"n\": 5}).rendered"
    libs
    jsonNull
    (fromObject
        ( Object.fromFoldable
            [ Tuple "type" (fromString "element")
            , Tuple "tag" (fromString "button")
            , Tuple "attrs" (fromObject Object.empty)
            , Tuple "action" (fromObject (Object.fromFoldable [ Tuple "eventType" (fromString "on-click"), Tuple "key" (fromString "ns-foo"), Tuple "payload" (fromObject (Object.singleton "n" (fromNumber 5.0))) ]))
            , Tuple "children" (fromArray [ fromObject (Object.fromFoldable [ Tuple "type" (fromString "text"), Tuple "text" (fromString "click") ]) ])
            ]
        )
    )
  checkJsonOk "remap-actions(...) queued on a partial survives currying it one param at a time, applying once it's finally complete"
    "@p=partial-import(\"two-arg-btn\", {})\n@p2=remap-actions($p, (a) => {\"eventType\": $a.eventType, \"key\": \"ns-`$a.key`\", \"payload\": $a.payload})\n@p3=$p2({\"a\": 1})\n@p4=$p3({\"b\": 2})\n$p4.rendered"
    libs
    jsonNull
    (fromObject
        ( Object.fromFoldable
            [ Tuple "type" (fromString "element")
            , Tuple "tag" (fromString "button")
            , Tuple "attrs" (fromObject Object.empty)
            , Tuple "action" (fromObject (Object.fromFoldable [ Tuple "eventType" (fromString "on-click"), Tuple "key" (fromString "ns-foo"), Tuple "payload" (fromObject (Object.fromFoldable [ Tuple "a" (fromNumber 1.0), Tuple "b" (fromNumber 2.0) ])) ]))
            , Tuple "children" (fromArray [ fromObject (Object.fromFoldable [ Tuple "type" (fromString "text"), Tuple "text" (fromString "click") ]) ])
            ]
        )
    )
  checkJsonOk "remap-actions(...) called twice on the same partial-import(...) queues both fns, applied in order once complete"
    "@p=partial-import(\"btn\", {})\n@p2=remap-actions($p, (a) => {\"eventType\": $a.eventType, \"key\": \"inner-`$a.key`\", \"payload\": $a.payload})\n@p3=remap-actions($p2, (a) => {\"eventType\": $a.eventType, \"key\": \"outer-`$a.key`\", \"payload\": $a.payload})\n$p3({\"n\": 5}).rendered"
    libs
    jsonNull
    (fromObject
        ( Object.fromFoldable
            [ Tuple "type" (fromString "element")
            , Tuple "tag" (fromString "button")
            , Tuple "attrs" (fromObject Object.empty)
            , Tuple "action" (fromObject (Object.fromFoldable [ Tuple "eventType" (fromString "on-click"), Tuple "key" (fromString "outer-inner-foo"), Tuple "payload" (fromObject (Object.singleton "n" (fromNumber 5.0))) ]))
            , Tuple "children" (fromArray [ fromObject (Object.fromFoldable [ Tuple "type" (fromString "text"), Tuple "text" (fromString "click") ]) ])
            ]
        )
    )
  checkJsonEvalRejectedWith libs "a remap-actions(...)-wrapped partial that's still incomplete can't be used where a Json value is required, same as a plain partial"
    "@p=partial-import(\"btn\", {})\n@p2=remap-actions($p, (a) => $a)\n$p2"
  log "All import/partial-import fixtures passed."
  where
  buildLibraryTable :: Effect LibraryTable
  buildLibraryTable = do
    greeter <- mustParseProgram "@greeting=\"hello `$ctx.name`\"\n.div(\"`$greeting`\")"
    cyclic <- mustParseProgram "@self=import(\"cyclic\", {})\n.div(\"x\")"
    oneArg <- mustParseProgram ".div(\"`$ctx.arg0`\")"
    twoArg <- mustParseProgram ".div(\"`$ctx.a`-`$ctx.b`\")"
    btn <- mustParseProgram ".button(action(\"on-click\", \"foo\", {\"n\": $ctx.n}), \"click\")"
    twoActions <- mustParseProgram ".div(.button(action(\"on-click\", \"a\", {\"v\": 1}), \"A\"), .button(action(\"on-click\", \"b\", {\"v\": 2}), \"B\"))"
    jsonLib <- mustParseJsonProgram "{\"n\": $ctx.n}"
    wrapsBtnInVals <- mustParseProgram "@sub=import(\"btn\", {\"n\": 9})\n.div(\"just text\")"
    twoArgBtn <- mustParseProgram ".button(action(\"on-click\", \"foo\", {\"a\": $ctx.a, \"b\": $ctx.b}), \"click\")"
    pure
      ( Map.fromFoldable
          [ Tuple "greeter" (ProgramSource greeter)
          , Tuple "cyclic" (ProgramSource cyclic)
          , Tuple "one-arg" (ProgramSource oneArg)
          , Tuple "two-arg" (ProgramSource twoArg)
          , Tuple "btn" (ProgramSource btn)
          , Tuple "two-actions" (ProgramSource twoActions)
          , Tuple "json-lib" (JsonSource jsonLib)
          , Tuple "wraps-btn-in-vals" (ProgramSource wrapsBtnInVals)
          , Tuple "two-arg-btn" (ProgramSource twoArgBtn)
          ]
      )

  mustParseProgram :: String -> Effect Program
  mustParseProgram src = case parseProgram src of
    Left err -> throw ("library fixture failed to parse: " <> show err)
    Right program -> pure program

  mustParseJsonProgram :: String -> Effect JsonProgram
  mustParseJsonProgram src = case parseJsonProgram src of
    Left err -> throw ("library fixture failed to parse: " <> show err)
    Right program -> pure program

  checkJsonOk :: String -> String -> LibraryTable -> Json -> Json -> Effect Unit
  checkJsonOk label template libs ctx expected = case parseJsonProgram template of
    Left err -> throw (label <> ": parse failed: " <> show err)
    Right program -> case evalJsonProgram libs ctx program of
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

  checkJsonEvalRejectedWith :: LibraryTable -> String -> String -> Effect Unit
  checkJsonEvalRejectedWith libs label template = case parseJsonProgram template of
    Left err -> throw (label <> ": expected this to parse (and fail at eval instead), but parsing itself failed: " <> show err)
    Right program -> case evalJsonProgram libs jsonNull program of
      Left (_ :: EvalError) -> log ("ok - " <> label)
      Right _ -> throw (label <> ": expected an eval error, got a successful eval")

  checkTemplateOkWithLibs :: String -> String -> LibraryTable -> Json -> Node -> Effect Unit
  checkTemplateOkWithLibs label template libs ctx expected = case parseProgram template of
    Left err -> throw (label <> ": parse failed: " <> show err)
    Right program -> case evalProgram libs ctx program of
      Left err -> throw (label <> ": eval failed: " <> show err)
      Right actual ->
        if actual == expected then log ("ok - " <> label)
        else
          throw
            ( label
                <> ": mismatch\n  expected: "
                <> show expected
                <> "\n  actual:   "
                <> show actual
            )
