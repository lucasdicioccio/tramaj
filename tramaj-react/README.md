# tramaj-react

Folds a `tramaj-js` `Node` into React elements — the React counterpart of
`tramaj-halogen`, and the only package here that depends on `react`.

## Public API

```ts
import { foldToReact, validateAttrNames } from "tramaj-react";

const bad = validateAttrNames(node);
if (bad.length === 0) return <>{foldToReact(dispatch, node)}</>;
```

- `foldToReact(dispatch, node): ReactNode[]` — an array, not one element,
  because a `Node` need not be one element: a fragment contributes its children
  with no wrapper. A host splices the result into its own container.
- `Dispatch = (event, key, payload) => MouseEventHandler | undefined | null` —
  every action `dispatch` accepts is wired to `onClick`, without this module
  looking at the event type. `dispatch` is the only place that can tell
  `"on-click"` from anything else and returns `undefined` for event types it
  does not want turned into a click. Halogen's version returns an opaque action
  its component consumes through `handleAction`; React has no such channel, so
  the callback the host would have written there is what it returns here.
- `renderScalar(json): string` — how this host renders a JSON value as DOM
  text. Recognizes the v3-symbols §5.3 wire tag `{"$sym": …, "path": […]}` and
  renders it as the id with its path dotted on.
- `validateAttrNames(node): string[]` — every attribute name in the tree that
  is not alphanumeric plus `-`/`_`. Call it before folding: `foldToReact`
  trusts its names and the DOM will throw on an illegal one.
- `SymbolTable`, `ConstraintTable`, `TypesTable`, `TypeConstraintTable`,
  `ProgramCard` — introspection views over the symbolic envelope and a
  `programCard` result. Example-host conveniences, not part of the fold
  contract; treat the layout as a starting point.

## Scripts

```
npm run build      # builds tramaj-js, then tsc -> dist/
npm run typecheck
npm test           # vitest + jsdom
```
