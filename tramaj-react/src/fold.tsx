/**
 * Folds the normative `tramaj-js` `Node` AST into real React output. The only
 * module in this repository that depends on `react` — `tramaj-js`'s
 * parser/eval/node/analysis have no React or DOM dependency at all, so the
 * same evaluated tree can be folded to something else entirely. The React
 * counterpart of `tramaj-halogen/src/Tramaj/Halogen.purs`.
 *
 * Three v2 facts shape this module. A node is not guaranteed to be a single
 * element, because fragments are real nodes, so the fold returns an array. An
 * element may carry any number of actions rather than at most one. And
 * attribute values, text values and the element value slot are arbitrary JSON
 * rather than pre-stringified text — evaluation deliberately stops short of
 * deciding how a number renders, which makes it this module's decision
 * (`renderScalar`).
 *
 * v3-symbols support: a value anywhere in the tree may be the §5.3 wire tag
 * `{"$sym": <id>, "path": [...]}` rather than an ordinary scalar, and
 * `renderScalar` recognizes it unconditionally rather than behind a mode flag
 * — that shape cannot arise honestly from concrete-mode output, since `"$sym"`
 * as a literal object key is a parse error, so seeing the shape already tells
 * the whole story.
 */

import {
  cloneElement,
  createElement,
  isValidElement,
  type MouseEvent,
  type MouseEventHandler,
  type ReactNode,
} from "react";
import { isJsonObject, type Json, type Node, type NodeAttribute } from "tramaj-js";

/**
 * `dispatch` maps an action — its event type, its key, and its JSON payload —
 * onto a real React event handler; a host that wants purely read-only
 * rendering supplies `() => undefined`. An action that maps to
 * `undefined`/`null` attaches no handler at all.
 *
 * Every action `dispatch` accepts is wired to `onClick`, without this module
 * looking at the event type: evaluation does not restrict that string to any
 * vocabulary, so `dispatch` is the only place that can tell `"on-click"` from
 * anything else and must return `undefined` for event types it does not want
 * turned into a click. Continuous-input handling is out of scope.
 *
 * Returning a handler rather than an opaque action value is where this differs
 * from `Tramaj.Halogen`: Halogen components consume a dispatched action
 * through `handleAction`, where React has no such channel, so the callback the
 * host would have written there is what it returns here.
 */
export type Dispatch = (
  event: string,
  key: string,
  payload: Json,
) => MouseEventHandler<Element> | undefined | null;

/**
 * Returns an array because a `Node` need not be a single element: a fragment
 * contributes its children with no wrapper, which is the whole point of it. A
 * host rendering a document root splices the result into whatever container it
 * already has, as in `<>{foldToReact(dispatch, node)}</>`.
 *
 * `foldToReact` trusts that attribute names are legal DOM attribute names. The
 * language does not restrict them, so a template can produce a name the DOM
 * rejects, throwing mid-render. Call `validateAttrNames` first and handle a
 * non-empty result rather than folding straight through.
 */
export function foldToReact(dispatch: Dispatch, node: Node): ReactNode[] {
  return foldList(dispatch, [node]);
}

/**
 * Folds a sibling sequence, keying each element by its position in the
 * *flattened* result — a fragment splices several siblings in where its parent
 * counted one, so the parent's own index is not a usable key.
 */
function foldList(dispatch: Dispatch, nodes: Node[]): ReactNode[] {
  const out: ReactNode[] = [];
  for (const n of nodes) {
    for (const child of foldNode(dispatch, n)) {
      out.push(isValidElement(child) ? cloneElement(child, { key: String(out.length) }) : child);
    }
  }
  return out;
}

function foldNode(dispatch: Dispatch, node: Node): ReactNode[] {
  switch (node.t) {
    case "text":
      return [renderTextValue(node.value)];
    case "fragment":
      return foldList(dispatch, node.children);
    case "element": {
      const props: Record<string, unknown> = {};
      for (const a of node.attributes) {
        if (a.t === "attribute") props[reactPropName(a.name)] = renderScalar(a.value);
      }
      const handlers = node.attributes.flatMap((a) => {
        if (a.t !== "action") return [];
        const h = dispatch(a.event, a.key, a.payload);
        return h === undefined || h === null ? [] : [h];
      });
      // An element may carry any number of actions, so every handler
      // `dispatch` accepted runs, in source order, rather than all but one
      // being silently dropped by the single `onClick` slot.
      if (handlers.length > 0) {
        props["onClick"] = (e: MouseEvent<Element>) => {
          for (const h of handlers) h(e);
        };
      }
      const folded = foldList(dispatch, node.children);
      // An element with a value slot and no children renders that value as its
      // text content: in a DOM host there is nowhere else for it to go, and
      // dropping it would silently lose what the template said. An element
      // with both keeps its children.
      const children =
        folded.length === 0 && node.value !== null ? [renderTextValue(node.value)] : folded;
      return [createElement(node.tag, props, ...children)];
    }
  }
}

/**
 * Attribute names reach the DOM as the template wrote them, with the two
 * exceptions React renames: React sets `class`/`for` through `className`/
 * `htmlFor` and warns about the HTML spellings, and these are the attributes a
 * template is most likely to write. The rendered DOM attribute is the same
 * either way; everything else passes through verbatim.
 */
const REACT_PROP_NAMES: Record<string, string> = { class: "className", for: "htmlFor" };

function reactPropName(name: string): string {
  return REACT_PROP_NAMES[name] ?? name;
}

/**
 * A text-position value (a text child, or an element's value slot rendered as
 * text): a symbol renders in `<code>`, set apart from ordinary text, so a
 * reader can tell a hole from a string that happens to look like one.
 */
function renderTextValue(j: Json): ReactNode {
  const label = symbolLabel(j);
  return label === null ? renderScalar(j) : <code>{label}</code>;
}

/**
 * How this host renders a JSON value as DOM text. A symbol (`v3-symbols.md`
 * §5.3's `{"$sym": ..., "path": [...]}` tag) renders as its id with its path
 * dotted on, e.g. `#0:"d".replicas`. Otherwise: a string is itself, a whole
 * number drops its trailing `.0`, `null` renders as nothing, and anything
 * structured falls back to compact JSON.
 *
 * Deliberately this module's decision rather than the evaluator's: a different
 * host targeting YAML or a UI model would render the same values differently,
 * and `Node` keeps them unconverted precisely so that it can.
 */
export function renderScalar(j: Json): string {
  const label = symbolLabel(j);
  if (label !== null) return label;
  if (typeof j === "string") return j;
  if (typeof j === "number") return String(j);
  if (typeof j === "boolean") return j ? "true" : "false";
  if (j === null) return "";
  return JSON.stringify(j) ?? "";
}

/**
 * Recognizes the `v3-symbols.md` §5.3 wire tag and renders it as `<id>` with
 * its path dotted on. This shape cannot arise honestly in concrete-mode output
 * — `"$sym"` as a literal object key is a parse error — so detecting it needs
 * no mode flag: seeing the shape *is* the mode.
 */
export function symbolLabel(j: Json): string | null {
  if (!isJsonObject(j)) return null;
  const sid = j["$sym"];
  const path = j["path"];
  if (typeof sid !== "string" || !Array.isArray(path)) return null;
  if (!path.every((p): p is string => typeof p === "string")) return null;
  return sid + path.map((p) => `.${p}`).join("");
}

/**
 * A DOM attribute name this module is willing to set: alphanumeric plus
 * `-`/`_` only (no spaces, colons, quotes) — deliberately stricter than HTML
 * itself permits, since the only names templates should need are
 * kebab-case/snake_case identifiers like `data-count`.
 */
export function isValidAttrName(s: string): boolean {
  return s !== "" && /^[A-Za-z0-9_-]+$/.test(s);
}

/**
 * Every invalid attribute name found anywhere in the tree (deduplicated, tree
 * order), or `[]` if `node` is safe to fold with `foldToReact`.
 */
export function validateAttrNames(node: Node): string[] {
  const go = (n: Node): string[] => {
    switch (n.t) {
      case "text":
        return [];
      case "element":
        return [
          ...n.attributes
            .flatMap((a: NodeAttribute) => (a.t === "attribute" ? [a.name] : []))
            .filter((name) => !isValidAttrName(name)),
          ...n.children.flatMap(go),
        ];
      case "fragment":
        return n.children.flatMap(go);
    }
  };
  return [...new Set(go(node))];
}
