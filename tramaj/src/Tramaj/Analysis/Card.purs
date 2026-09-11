-- | A one-glance summary of a program's static interface, assembled from
-- | `Tramaj.Analysis`'s primitives rather than adding any new AST walk.
-- |
-- | The motivating question is the one a host asks before running a
-- | template from an untrusted or automated source: *what does this thing
-- | need, what does it reach, and what can it do* — without evaluating it.
-- | `Tramaj.Analysis` already answers each piece separately; `programCard`
-- | just picks the five that describe one program as a unit, the way
-- | `tramaj-cli analyze card` and the Halogen playground's card panel both
-- | want to show it:
-- |
-- | * `produces`   — does the root evaluate to a document or a plain value
-- | * `requires`   — this program's own `$ctx` reads (what its caller must
-- |                  supply to run it directly, at the root)
-- | * `imports`    — every library it reaches, directly or transitively
-- | * `emits`      — every action key it can possibly emit, deep
-- | * `unsupplied` — for each import, which of the library's own context
-- |                  reads that import site leaves unfilled
-- |
-- | `requires` is deliberately the shallow, root-only `contextReads`, not
-- | `deepContextHoles`: a card describes what running *this* program
-- | needs from its own caller, not the bubbled-up shape of every library
-- | underneath it — that question already has its own analysis
-- | (`deepContextHoles`, the `holes` subcommand) for when it's the one
-- | wanted.
-- |
-- | Not part of the conformance corpus or the `node-json` wire format —
-- | this is a presentation-level composition, not a new primitive, so it
-- | has no Haskell counterpart to keep in lockstep with the way
-- | `Tramaj.Analysis` itself does.
module Tramaj.Analysis.Card
  ( ProgramKind(..)
  , Card
  , programKind
  , programCard
  ) where

import Prelude

import Data.Map (Map)
import Data.Set (Set)
import Data.Tuple (Tuple)
import Tramaj.Analysis (contextReads, deepActionKeys, transitiveImportNames, unsuppliedParams)
import Tramaj.Ast (Program(..))

-- | What a program's root evaluates to — named for display; carries the
-- | same information as which of `Tramaj.Ast.Program`'s two constructors
-- | wraps it, decided by the parser from the root's own syntax, never by
-- | running anything.
data ProgramKind = ProducesDocument | ProducesValue

derive instance eqProgramKind :: Eq ProgramKind

instance showProgramKind :: Show ProgramKind where
  show ProducesDocument = "document"
  show ProducesValue = "value"

programKind :: Program -> ProgramKind
programKind (DocumentProgram _) = ProducesDocument
programKind (ExpressionProgram _) = ProducesValue

type Card =
  { produces :: ProgramKind
  , requires :: Set (Array String)
  , imports :: Set String
  , emits :: Set String
  , unsupplied :: Array (Tuple String (Set (Array String)))
  }

-- | `libs` plays the same role it does throughout `Tramaj.Analysis`: the
-- | library table a host has (or the playground's other tabs offer) so the
-- | *deep* fields — `imports`, `emits`, `unsupplied` — can follow
-- | `import(...)` sites rather than stopping at this program's own AST.
programCard :: Map String Program -> Program -> Card
programCard libs prog =
  { produces: programKind prog
  , requires: contextReads prog
  , imports: transitiveImportNames libs prog
  , emits: deepActionKeys libs prog
  , unsupplied: unsuppliedParams libs prog
  }
