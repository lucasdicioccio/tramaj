-- | v4-types resolution and canonical identity (roadmap-to-v4 Phase 9).
--
-- The load-bearing property here is the same one 'Tramaj.AnalysisSpec' and
-- "Tramaj.ParserSpec" already hold the language to: every case asserts the
-- exact string a canonical id renders to, not just that resolution
-- succeeded. That is what "two implementations must agree on the id
-- strings" (roadmap Phase 9, following Phase 4's own discipline for symbol
-- ids) means in practice -- this file and its PureScript sibling assert the
-- identical literal strings.
module Tramaj.TypesSpec (spec) where

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Test.Hspec
import Tramaj.Analysis (unsuppliedTypeParams)
import Tramaj.Ast (Program, TypeExpr, typeDecls, unlets, programRoot)
import Tramaj.Parser
import Tramaj.Types

spec :: Spec
spec = do
  resolutionSpec
  errorSpec
  parameterSpec
  closureAndConstraintSpec

prog :: Text -> Program
prog src = either (\e -> error ("types fixture does not parse: " <> show e)) id (parseProgram src)

-- | The body of a @type Name = ...@ declaration, by name -- what every case
-- below resolves.
declBody :: Program -> Text -> TypeExpr
declBody p n = maybe (error ("no such declaration: " <> show n)) id (lookup n (typeDecls (fst (unlets (programRoot p)))))

resolvesTo :: Map.Map Text Program -> Program -> Text -> Text -> Spec
resolvesTo libs p declName expectedId =
  it (show declName <> " canonicalizes to " <> show expectedId) $
    fmap canonicalId (resolveTypeExpr libs p (declBody p declName)) `shouldBe` Right expectedId

resolutionSpec :: Spec
resolutionSpec = describe "canonical ids" $ do
  resolvesTo
    Map.empty
    (prog "type Tree = | Leaf | Node { l : Tree, r : Tree }\ntrue")
    "Tree"
    "|Leaf|Node {l:root:Tree,r:root:Tree}"

  resolvesTo
    Map.empty
    (prog "type Inner = { x : number }\ntype Outer = { items : [ Inner ] }\ntrue")
    "Outer"
    "{items:[root:Inner]}"

  resolvesTo
    (Map.fromList [("message", prog "type Envelope = { to : string, id : number }\ntrue")])
    (prog "@msg=import(\"message\", {})\ntype UsesEnvelope = { env : $msg.types.Envelope }\ntrue")
    "UsesEnvelope"
    "{env:\"message\":Envelope}"

  -- Sorted by arm/field name, regardless of source order -- the injectivity
  -- v4-types \S3 asks for depends on the id not encoding which order the
  -- author happened to write things in.
  resolvesTo
    Map.empty
    (prog "type Shape = | Square { s : number } | Circle { r : number } | Dev\ntrue")
    "Shape"
    "|Circle {r:number}|Dev|Square {s:number}"

  -- A root declaration and a same-named library declaration must render to
  -- different strings -- the whole point of \"root\" being a token no
  -- quoted library key can equal (see "Tramaj.Types"'s header).
  resolvesTo
    (Map.fromList [("message", prog "type Envelope = { to : string }\ntrue")])
    (prog "@msg=import(\"message\", {})\ntype Envelope = string\ntype Both = { local : Envelope, remote : $msg.types.Envelope }\ntrue")
    "Both"
    "{local:root:Envelope,remote:\"message\":Envelope}"

  resolvesTo
    Map.empty
    (prog "type Message = { to : string, payload : %ctx.payload }\ntrue")
    "Message"
    "{payload:%ctx.payload,to:string}"

  resolvesTo
    Map.empty
    (prog "type Items = [ string ]\ntrue")
    "Items"
    "[string]"

errorSpec :: Spec
errorSpec = describe "resolution errors" $ do
  it "reports UnresolvedType for a name that names no primitive and no declaration" $
    resolveTypeExpr Map.empty (prog "type Bad = NoSuchType\ntrue") (declBody (prog "type Bad = NoSuchType\ntrue") "Bad")
      `shouldBe` Left (UnresolvedType "NoSuchType")

  it "reports NotStaticallyResolvable when $lib is not bound directly to an import" $
    let p = prog "@x=1\n@msg=$x\ntype T = { e : $msg.types.Envelope }\ntrue"
     in resolveTypeExpr Map.empty p (declBody p "T") `shouldBe` Left (NotStaticallyResolvable "msg")

  it "reports NotStaticallyResolvable when the import names a library the table lacks" $
    let p = prog "@msg=import(\"missing\", {})\ntype T = { e : $msg.types.Envelope }\ntrue"
     in resolveTypeExpr Map.empty p (declBody p "T") `shouldBe` Left (NotStaticallyResolvable "msg")

  it "reports UnresolvedType for a name the library table resolves but does not declare" $
    let libs = Map.fromList [("message", prog "type Envelope = string\ntrue")]
        p = prog "@msg=import(\"message\", {})\ntype T = { e : $msg.types.Missing }\ntrue"
     in resolveTypeExpr libs p (declBody p "T") `shouldBe` Left (UnresolvedType "Missing")

-- | Type parameters through imports (v4-types \S2, roadmap Phase 10): a
-- 'RRef'\'s @arguments@ come from the import that reached it, not from any
-- syntax at the reference site itself.
parameterSpec :: Spec
parameterSpec = describe "type parameters through imports" $ do
  it "supplies a library-qualified type argument, closing the library's own hole" $
    let libs =
          Map.fromList
            [ ("json", prog "type Value = document\ntrue")
            , ("message", prog "type Envelope = { to : string, payload : %ctx.payload }\ntrue")
            ]
        p =
          prog
            "@json=import(\"json\", {})\n@msg=import(\"message\", {payload: %$json.types.Value})\ntype T = $msg.types.Envelope\ntrue"
     in fmap canonicalId (resolveTypeExpr libs p (declBody p "T")) `shouldBe` Right "\"message\":Envelope[payload=\"json\":Value]"

  it "supplies a bare local type name as a type argument" $
    let libs = Map.fromList [("message", prog "type Envelope = { payload : %ctx.payload }\ntrue")]
        p = prog "type Json = string\n@msg=import(\"message\", {payload: %Json})\ntype T = $msg.types.Envelope\ntrue"
     in fmap canonicalId (resolveTypeExpr libs p (declBody p "T")) `shouldBe` Right "\"message\":Envelope[payload=root:Json]"

  it "forwards a type hole through a nested import, closed only once the outer import supplies it" $
    let libs =
          Map.fromList
            [ ("inner", prog "type Box = { payload : %ctx.payload }\ntrue")
            , ("outer", prog "@in=import(\"inner\", {payload: %ctx.payload})\ntype Outer = $in.types.Box\ntrue")
            ]
        p = prog "@o=import(\"outer\", {payload: %string})\ntype T = $o.types.Outer\ntrue"
     in fmap canonicalId (resolveTypeExpr libs p (declBody p "T")) `shouldBe` Right "\"outer\":Outer[payload=string]"

  it "leaves an unsupplied type argument as a hole -- 'forward', not 'supply' (\\S6)" $
    let libs = Map.fromList [("message", prog "type Envelope = { payload : %ctx.payload }\ntrue")]
        p = prog "@msg=import(\"message\", {})\ntype T = $msg.types.Envelope\ntrue"
     in fmap canonicalId (resolveTypeExpr libs p (declBody p "T")) `shouldBe` Right "\"message\":Envelope[payload=%ctx.payload]"

  it "reports unsuppliedTypeParams for a parameterised import that supplies nothing" $
    let libs = Map.fromList [("outer", prog "@in=import(\"inner\", {payload: %ctx.payload})\ntrue")]
        p = prog "@o=import(\"outer\", {})\ntrue"
     in unsuppliedTypeParams libs p `shouldBe` [("outer", Set.singleton ["payload"])]

  it "requireClosed accepts a fully supplied type" $
    let libs = Map.fromList [("message", prog "type Envelope = { payload : %ctx.payload }\ntrue")]
        p = prog "@msg=import(\"message\", {payload: %string})\ntype T = $msg.types.Envelope\ntrue"
     in (resolveTypeExpr libs p (declBody p "T") >>= requireClosed) `shouldSatisfy` isRight

  it "requireClosed rejects a type that still contains a variable (\\S4's PartialType)" $
    let libs = Map.fromList [("message", prog "type Envelope = { payload : %ctx.payload }\ntrue")]
        p = prog "@msg=import(\"message\", {})\ntype T = $msg.types.Envelope\ntrue"
     in (resolveTypeExpr libs p (declBody p "T") >>= requireClosed)
          `shouldBe` Left (PartialType "\"message\":Envelope[payload=%ctx.payload]" ["payload"])

  it "reports TypeParamCollision when a params key is read both as $ctx.k and as %ctx.k" $
    let p = prog "@a=import(\"m\", {k: %ctx.k})\n@b=$ctx.k\ntrue"
     in checkTypeParamCollisions p `shouldBe` Left (TypeParamCollision "k")

  it "reports no collision when the two channels use different keys" $
    let p = prog "@a=import(\"m\", {k: %ctx.k})\n@b=$ctx.other\ntrue"
     in checkTypeParamCollisions p `shouldBe` Right ()

isRight :: Either a b -> Bool
isRight (Right _) = True
isRight (Left _) = False

-- | The @\"types\"@ closure (\S8, roadmap Phase 13) and @!type-constraint@
-- collection (\S5, roadmap Phase 12).
closureAndConstraintSpec :: Spec
closureAndConstraintSpec = describe "output: closure and type constraints" $ do
  it "expands a parameterised reference's own definition, one declaration boundary at a time" $
    let libs =
          Map.fromList
            [ ("inner", prog "type Box = { payload : %ctx.payload }\ntrue")
            , ("outer", prog "@in=import(\"inner\", {payload: %ctx.payload})\ntype Outer = $in.types.Box\ntrue")
            ]
        p = prog "@o=import(\"outer\", {payload: %string})\ntype T = $o.types.Outer\ntrue"
        Right root = resolveTypeExpr libs p (declBody p "T")
        Right table = typeClosure libs p [root]
     in do
          Map.lookup "\"outer\":Outer[payload=string]" table `shouldBe` Just (RRef (Just "inner") "Box" [("payload", RPrim "string")])
          Map.lookup "\"inner\":Box[payload=string]" table `shouldBe` Just (RRecord [("payload", RPrim "string")])

  it "resolves a !type-constraint's arguments, mixing a type and a scalar" $
    let p = prog "type Json = string\n!type-constraint(\"coercible-to\", %Json, \"lossy\")\ntrue"
     in typeConstraints Map.empty p `shouldBe` Right [("coercible-to", [RCType (RRef Nothing "Json" []), RCScalarStr "lossy"])]

  it "deduplicates two type constraints with the same name and resolved arguments" $
    let p =
          prog
            "type Json = string\n!type-constraint(\"has-default\", %Json)\n!type-constraint(\"has-default\", %Json)\ntrue"
     in typeConstraints Map.empty p `shouldBe` Right [("has-default", [RCType (RRef Nothing "Json" [])])]

  it "typeReferences collects the canonical ids of a program's own type-bearing positions" $
    let p = prog "type Json = string\n!type-constraint(\"has-default\", %Json)\ntrue"
     in typeReferences Map.empty p `shouldBe` Right (Set.fromList ["root:Json", "string"])

  it "typeReferences resolves library-qualified references" $
    let libs = Map.fromList [("message", prog "type Envelope = { to : string }\ntrue")]
        p = prog "@msg=import(\"message\", {})\ntype T = $msg.types.Envelope\ntrue"
     in typeReferences libs p `shouldBe` Right (Set.fromList ["\"message\":Envelope"])

  it "deepTypeReferences follows transitively imported libraries" $
    let libs = Map.fromList [("message", prog "type Envelope = { to : string }\ntrue")]
        p = prog "@msg=import(\"message\", {})\ntype T = $msg.types.Envelope\ntrue"
     in deepTypeReferences libs p `shouldBe` Right (Set.fromList ["\"message\":Envelope", "{to:string}"])

  it "deepTypeConstraints bubbles up constraints from imported libraries" $
    let libs = Map.fromList [("typed", prog "type Json = string\n!type-constraint(\"has-default\", %Json)\ntrue")]
        p = prog "import(\"typed\", {}).rendered"
     in deepTypeConstraints libs p `shouldBe` Right [("has-default", [RCType (RRef Nothing "Json" [])])]
