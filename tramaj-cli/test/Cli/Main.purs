module Test.Cli.Main where

import Prelude

import Data.Argonaut.Core (Json, stringify, toArray, toObject, toString)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..), isJust)
import Data.String (contains) as Str
import Data.String.Pattern (Pattern(..)) as Str
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Class.Console (log)
import Effect.Exception (throw)
import Foreign.Object as Object
import Main (AnalyzeSubcommand(..), analyzeToJson)
import Partial.Unsafe (unsafeCrashWith)
import Tramaj.Ast (Program)
import Tramaj.Parser (parseProgram)

main :: Effect Unit
main = do
  testAnalyzeImports
  testAnalyzeActions
  testAnalyzeConstraints
  testAnalyzeTypes
  log "All tramaj-cli analyze checks passed."

parseProg :: String -> Program
parseProg src = case parseProgram src of
  Right p -> p
  Left err -> unsafeCrashWith ("test fixture does not parse: " <> show err)

expectArrayContainsString :: String -> Json -> Effect Unit
expectArrayContainsString expected arr = case toArray arr of
  Nothing -> throw ("expected a JSON array, got: " <> stringify arr)
  Just elems ->
    let
      found = Array.any (\j -> toString j == Just expected) elems
    in
      if found then pure unit
      else throw ("expected array to contain " <> show expected <> ", got: " <> stringify arr)

expectArrayContainsSubstring :: String -> Json -> Effect Unit
expectArrayContainsSubstring needle arr = case toArray arr of
  Nothing -> throw ("expected a JSON array, got: " <> stringify arr)
  Just elems ->
    let
      found = Array.any (\j -> isJust (toString j) && Str.contains (Str.Pattern needle) (unsafeStringOf j)) elems
      unsafeStringOf j = case toString j of
        Just s -> s
        Nothing -> ""
    in
      if found then pure unit
      else throw ("expected array to contain a string mentioning " <> show needle <> ", got: " <> stringify arr)

expectObjectField :: String -> Json -> Effect Json
expectObjectField key obj = case toObject obj >>= Object.lookup key of
  Nothing -> throw ("expected object to contain field " <> show key <> ", got: " <> stringify obj)
  Just v -> pure v

testAnalyzeImports :: Effect Unit
testAnalyzeImports = do
  let
    root = parseProg "@b=import(\"button\", {})\n.div($b.rendered)"
    button = parseProg ".button(action(\"on-click\", \"deploy\", {}), \"go\")"
    libs = Map.fromFoldable [ Tuple "button" button ]
  case analyzeToJson libs root AnalyzeImports of
    Left err -> throw ("analyze imports failed: " <> show err)
    Right json -> expectArrayContainsString "button" json

testAnalyzeActions :: Effect Unit
testAnalyzeActions = do
  let
    root = parseProg "@b=import(\"button\", {})\n.div(.b(action(\"on-click\", \"save\", {})), $b.rendered)"
    button = parseProg ".button(action(\"on-click\", \"deploy\", {}), \"go\")"
    libs = Map.fromFoldable [ Tuple "button" button ]
  case analyzeToJson libs root AnalyzeActions of
    Left err -> throw ("analyze actions failed: " <> show err)
    Right json -> do
      expectArrayContainsString "save" json
      expectArrayContainsString "deploy" json

testAnalyzeConstraints :: Effect Unit
testAnalyzeConstraints = do
  let
    root = parseProg "@t=import(\"typed\", {})\n!constraint(\"non-empty\", 1)\n$t.rendered"
    typed = parseProg "type Json = string\n!type-constraint(\"has-default\", %Json)\ntrue"
    libs = Map.fromFoldable [ Tuple "typed" typed ]
  case analyzeToJson libs root AnalyzeConstraints of
    Left err -> throw ("analyze constraints failed: " <> show err)
    Right json -> do
      kinds <- expectObjectField "kinds" json
      tcs <- expectObjectField "typeConstraints" json
      expectArrayContainsString "non-empty" kinds
      case toArray tcs of
        Nothing -> throw ("expected typeConstraints array, got: " <> stringify tcs)
        Just arr | Array.length arr == 1 -> case Array.head arr >>= toObject >>= Object.lookup "name" >>= toString of
          Just "has-default" -> pure unit
          _ -> throw ("expected type constraint named \"has-default\", got: " <> stringify tcs)
        Just arr -> throw ("expected one type constraint, got: " <> show (Array.length arr))

testAnalyzeTypes :: Effect Unit
testAnalyzeTypes = do
  let
    root = parseProg "@t=import(\"typed\", {})\ntype Envelope = { payload : $t.types.Json }\ntrue"
    typed = parseProg "type Json = string\n!type-constraint(\"has-default\", %Json)\ntrue"
    libs = Map.fromFoldable [ Tuple "typed" typed ]
  case analyzeToJson libs root AnalyzeTypes of
    Left err -> throw ("analyze types failed: " <> show err)
    Right json -> do
      decls <- expectObjectField "declarations" json
      refs <- expectObjectField "references" json
      expectArrayContainsString "Envelope" decls
      expectArrayContainsSubstring "\"typed\":Json" refs
