import { render } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { Json, Node, NodeAttribute } from "tramaj-js";

import { foldToReact, isValidAttrName, renderScalar, symbolLabel, validateAttrNames } from "../src/fold.js";

import type { Dispatch } from "../src/fold.js";

const noDispatch: Dispatch = () => undefined;

function el(
  tag: string,
  attributes: NodeAttribute[] = [],
  children: Node[] = [],
  value: Json = null,
): Node {
  return { t: "element", tag, attributes, value, children, annotations: {} };
}

function text(value: Json): Node {
  return { t: "text", value, annotations: {} };
}

function frag(children: Node[]): Node {
  return { t: "fragment", children, annotations: {} };
}

function html(node: Node, dispatch: Dispatch = noDispatch): string {
  const { container } = render(<>{foldToReact(dispatch, node)}</>);
  return container.innerHTML;
}

describe("foldToReact", () => {
  it("folds a plain nested element tree", () => {
    const node = el("div", [], [el("h1", [], [text("Title")]), el("p", [], [text("body")])]);
    expect(html(node)).toBe("<div><h1>Title</h1><p>body</p></div>");
  });

  it("renders an element with no children or value as empty", () => {
    expect(html(el("br"))).toBe("<br>");
  });

  it("returns one React node per top-level element", () => {
    expect(foldToReact(noDispatch, el("p")).length).toBe(1);
  });

  it("a fragment introduces siblings with no wrapper", () => {
    const node = frag([el("p", [], [text("a")]), el("p", [], [text("b")])]);
    expect(foldToReact(noDispatch, node).length).toBe(2);
    expect(html(node)).toBe("<p>a</p><p>b</p>");
  });

  it("a nested fragment still contributes only its children", () => {
    const node = el("div", [], [frag([el("p"), frag([el("span")])]), el("i")]);
    expect(html(node)).toBe("<div><p></p><span></span><i></i></div>");
  });

  it("a fragment at the root of a fold yields an array, not one element", () => {
    expect(foldToReact(noDispatch, frag([text("a"), text("b")]))).toEqual(["a", "b"]);
  });

  it("sets attributes, rendering their values with renderScalar", () => {
    const node = el("div", [
      { t: "attribute", name: "data-count", value: 3 },
      { t: "attribute", name: "data-flag", value: true },
      { t: "attribute", name: "data-missing", value: null },
    ]);
    expect(html(node)).toBe('<div data-count="3" data-flag="true" data-missing=""></div>');
  });

  // The language does not restrict attribute names, and neither does this
  // fold: a name reaches the DOM exactly as the template wrote it, rather than
  // going through React's `className`/`htmlFor` prop spellings.
  it("sets attribute names verbatim", () => {
    const node = el("label", [
      { t: "attribute", name: "class", value: "panel" },
      { t: "attribute", name: "for", value: "x" },
    ]);
    expect(html(node)).toBe('<label class="panel" for="x"></label>');
  });

  it("renders a structured attribute value as compact JSON", () => {
    const node = el("div", [{ t: "attribute", name: "data-obj", value: { b: 1, a: [2] } }]);
    expect(html(node)).toBe('<div data-obj="{&quot;b&quot;:1,&quot;a&quot;:[2]}"></div>');
  });

  it("renders a symbol attribute value as its id with its path dotted on", () => {
    const node = el("div", [
      { t: "attribute", name: "data-x", value: { $sym: '#0:"d"', path: ["replicas"] } },
    ]);
    expect(html(node)).toBe('<div data-x="#0:&quot;d&quot;.replicas"></div>');
  });

  it("renders a symbol in text position inside <code>", () => {
    expect(html(el("p", [], [text({ $sym: "#ctx.n", path: [] })]))).toBe(
      "<p><code>#ctx.n</code></p>",
    );
  });

  it("keeps a scalar child's rendering distinct from its type", () => {
    expect(html(el("span", [], [text(3)]))).toBe("<span>3</span>");
    expect(html(el("span", [], [text(false)]))).toBe("<span>false</span>");
    expect(html(el("span", [], [text(null)]))).toBe("<span></span>");
  });

  it("renders a value slot as text content when the element has no children", () => {
    expect(html(el("data-el", [], [], "production"))).toBe("<data-el>production</data-el>");
    expect(html(el("data-el", [], [], 42))).toBe("<data-el>42</data-el>");
  });

  it("keeps the children of an element that has both a value slot and children", () => {
    expect(html(el("data-el", [], [el("span", [], [text("child")])], "ignored"))).toBe(
      "<data-el><span>child</span></data-el>",
    );
  });

  it("leaves an element with a null value slot and no children empty", () => {
    expect(html(el("data-el", [], [], null))).toBe("<data-el></data-el>");
  });

  it("renders a value slot that is a symbol inside <code>", () => {
    expect(html(el("data-el", [], [], { $sym: "#ctx.n", path: ["a"] }))).toBe(
      "<data-el><code>#ctx.n.a</code></data-el>",
    );
  });
});

describe("actions", () => {
  it("wires an accepted action to onClick and reaches dispatch with event, key and payload", () => {
    const dispatch = vi.fn<Dispatch>(() => () => {});
    const node = el("button", [
      { t: "action", event: "on-click", key: "deploy", payload: { deployment: "web" } },
    ]);
    render(<>{foldToReact(dispatch, node)}</>);
    expect(dispatch).toHaveBeenCalledTimes(1);
    expect(dispatch).toHaveBeenCalledWith("on-click", "deploy", { deployment: "web" });
  });

  it("calls the handler dispatch returned when the element is clicked", () => {
    const handler = vi.fn();
    const dispatch: Dispatch = () => handler;
    const node = el("button", [{ t: "action", event: "on-click", key: "save", payload: 1 }]);
    const { container } = render(<>{foldToReact(dispatch, node)}</>);
    (container.querySelector("button") as HTMLButtonElement).click();
    expect(handler).toHaveBeenCalledTimes(1);
  });

  it("attaches no handler at all for an action dispatch declines", () => {
    const node = el("button", [{ t: "action", event: "on-hover", key: "peek", payload: null }]);
    const { container } = render(<>{foldToReact(() => undefined, node)}</>);
    const button = container.querySelector("button") as HTMLButtonElement;
    expect(() => button.click()).not.toThrow();
    expect(container.innerHTML).toBe("<button></button>");
  });

  it("does not special-case event-type strings: dispatch alone decides", () => {
    const seen: string[] = [];
    const dispatch: Dispatch = (event) => {
      seen.push(event);
      return event === "on-click" ? () => {} : undefined;
    };
    const node = el("button", [
      { t: "action", event: "on-hover", key: "a", payload: null },
      { t: "action", event: "wat", key: "b", payload: null },
      { t: "action", event: "on-click", key: "c", payload: null },
    ]);
    render(<>{foldToReact(dispatch, node)}</>);
    expect(seen).toEqual(["on-hover", "wat", "on-click"]);
  });

  it("runs every accepted action on one element, in source order", () => {
    const calls: string[] = [];
    const dispatch: Dispatch = (_event, key) => () => calls.push(key);
    const node = el("button", [
      { t: "action", event: "on-click", key: "first", payload: null },
      { t: "attribute", name: "data-x", value: 1 },
      { t: "action", event: "on-click", key: "second", payload: null },
    ]);
    const { container } = render(<>{foldToReact(dispatch, node)}</>);
    (container.querySelector("button") as HTMLButtonElement).click();
    expect(calls).toEqual(["first", "second"]);
  });

  it("reaches actions nested under fragments and elements", () => {
    const keys: string[] = [];
    const dispatch: Dispatch = (_event, key) => {
      keys.push(key);
      return undefined;
    };
    const node = el(
      "ul",
      [],
      [
        frag([
          el("li", [{ t: "action", event: "on-click", key: "one", payload: null }]),
          el("li", [{ t: "action", event: "on-click", key: "two", payload: null }]),
        ]),
      ],
    );
    render(<>{foldToReact(dispatch, node)}</>);
    expect(keys).toEqual(["one", "two"]);
  });
});

describe("renderScalar", () => {
  const cases: Array<[Json, string]> = [
    ["hello", "hello"],
    ["", ""],
    [3, "3"],
    [3.0, "3"],
    [1.5, "1.5"],
    [0, "0"],
    [100000000000, "100000000000"],
    [null, ""],
    [true, "true"],
    [false, "false"],
    [[1, "a"], '[1,"a"]'],
    [{ a: 1 }, '{"a":1}'],
    [{ $sym: "#0:1", path: [] }, "#0:1"],
    [{ $sym: "#0:1", path: ["a", "b"] }, "#0:1.a.b"],
    // Not the §5.3 tag — a "$sym" that is not a string, or no "path" at all,
    // is just an ordinary object.
    [{ $sym: 1, path: [] }, '{"$sym":1,"path":[]}'],
    [{ $sym: "#0" }, '{"$sym":"#0"}'],
    [{ $sym: "#0", path: [1] }, '{"$sym":"#0","path":[1]}'],
  ];

  for (const [input, expected] of cases) {
    it(`renders ${JSON.stringify(input)} as ${JSON.stringify(expected)}`, () => {
      expect(renderScalar(input)).toBe(expected);
    });
  }

  it("symbolLabel returns null for anything that is not the §5.3 tag", () => {
    expect(symbolLabel({ $sym: "#0", path: [] })).toBe("#0");
    expect(symbolLabel("#0")).toBeNull();
    expect(symbolLabel(null)).toBeNull();
    expect(symbolLabel([{ $sym: "#0", path: [] }])).toBeNull();
  });
});

describe("validateAttrNames", () => {
  it("accepts kebab-case and snake_case identifiers", () => {
    expect(isValidAttrName("data-count")).toBe(true);
    expect(isValidAttrName("data_count")).toBe(true);
    expect(isValidAttrName("A1")).toBe(true);
    expect(isValidAttrName("")).toBe(false);
    expect(isValidAttrName("data count")).toBe(false);
    expect(isValidAttrName("xlink:href")).toBe(false);
    expect(isValidAttrName('a"b')).toBe(false);
  });

  it("finds an illegal name anywhere in the tree", () => {
    const node = el(
      "div",
      [{ t: "attribute", name: "data-ok", value: 1 }],
      [
        frag([
          el("p", [{ t: "attribute", name: "bad name", value: 1 }]),
          el("p", [{ t: "attribute", name: "also:bad", value: 1 }]),
        ]),
      ],
    );
    expect(validateAttrNames(node)).toEqual(["bad name", "also:bad"]);
  });

  it("deduplicates and reports nothing for a safe tree", () => {
    const node = el(
      "div",
      [],
      [
        el("p", [{ t: "attribute", name: "bad name", value: 1 }]),
        el("p", [{ t: "attribute", name: "bad name", value: 2 }]),
      ],
    );
    expect(validateAttrNames(node)).toEqual(["bad name"]);
    expect(validateAttrNames(el("p", [{ t: "attribute", name: "data-x", value: 1 }]))).toEqual([]);
  });

  it("ignores action keys, which are not DOM attribute names", () => {
    const node = el("p", [{ t: "action", event: "on-click", key: "not a name", payload: null }]);
    expect(validateAttrNames(node)).toEqual([]);
  });
});
