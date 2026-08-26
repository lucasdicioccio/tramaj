-- | Parser-only checks not covered by 'Tramaj.EvalSpec'\'s end-to-end
-- fixtures -- in particular the attrs-after-child ordering *rejection*,
-- which is a parse failure rather than a success/expected-'Node' pair (same
-- split as @../tramaj/test/Test/Main.purs@).
module Tramaj.ParserSpec (spec) where

import Data.Either (isLeft, isRight)
import Tramaj.Parser (parseProgram)
import Test.Hspec

spec :: Spec
spec = describe "Tramaj.Parser" $ do
  it "parses a plain nested element tree" $
    parseProgram ".div(.p(\"Hello\"))" `shouldSatisfy` isRight

  it "rejects a named-arg/action(...) appearing after a sibling child node" $
    parseProgram ".div(.p(\"hi\"), \"attr\": \"value\")" `shouldSatisfy` isLeft

  it "rejects more than one action(...) on the same node" $
    parseProgram ".button(action(\"on-click\", \"a\", {}), action(\"on-click\", \"b\", {}))" `shouldSatisfy` isLeft

  it "accepts a kebab-case tag and identifier" $
    parseProgram "@my-var=1\n.my-tag(\"x\")" `shouldSatisfy` isRight

  it "accepts a bare special form (not via an @-binding) as a node child" $
    parseProgram ".div(scan($ctx.nums, 0, (acc, n) => $acc))" `shouldSatisfy` isRight

  it "accepts a bare import(...) as a node child" $
    parseProgram ".div(import(\"lib\", {}))" `shouldSatisfy` isRight

  it "rejects import(...) with a computed (non-literal) name" $
    parseProgram "@bar=import($ctx.libname, {})\n.div($bar.rendered)" `shouldSatisfy` isLeft

  it "rejects partial-import(...) with a computed (non-literal) name" $
    parseProgram "@bar=partial-import($ctx.libname, {})\n.div($bar.rendered)" `shouldSatisfy` isLeft

  it "rejects action(...) with a computed (non-literal) key" $
    parseProgram ".button(action(\"on-click\", $ctx.key, {}))" `shouldSatisfy` isLeft

  it "does not misparse a '.' starting the next line's node as a field access after a closing call" $
    parseProgram "@x=cardinality($ctx.items)\n.div(\"`$x`\")" `shouldSatisfy` isRight
