/**
 * `specs/node-json.md`'s round-trip law and its explicit list of things a
 * decoder MUST reject — the corpus only ever exercises the encoder, since it
 * compares encoded output.
 */

import { describe, expect, it } from "vitest";

import type { Json } from "../src/json.js";
import { NodeDecodeError, nodeFromJson, nodeToJson, type Node } from "../src/node.js";

const sample: Node = {
  t: "element",
  tag: "button",
  attributes: [
    { t: "attribute", name: "class", value: "primary" },
    { t: "action", event: "on-click", key: "deploy", payload: { deployment: "web" } },
  ],
  value: null,
  children: [
    { t: "text", value: 3, annotations: {} },
    { t: "fragment", children: [{ t: "text", value: "a", annotations: {} }], annotations: {} },
  ],
  annotations: { origin: "test" },
};

describe("node JSON", () => {
  it("round-trips: decode(encode(n)) equals n", () => {
    expect(nodeFromJson(nodeToJson(sample))).toEqual(sample);
  });

  it("encodes every required field, including empty annotations and a null value slot", () => {
    expect(nodeToJson({ t: "element", tag: "p", attributes: [], value: null, children: [], annotations: {} })).toEqual({
      type: "element",
      tag: "p",
      attributes: [],
      value: null,
      children: [],
      annotations: {},
    });
  });

  const rejected: Array<[string, Json]> = [
    ["no type", { value: 1, annotations: {} }],
    ["unknown type", { type: "comment", annotations: {} }],
    ["text with no value", { type: "text", annotations: {} }],
    ["text with no annotations", { type: "text", value: 1 }],
    ["non-object annotations", { type: "text", value: 1, annotations: [] }],
    ["non-string tag", { type: "element", tag: 1, attributes: [], value: null, children: [], annotations: {} }],
    ["non-array attributes", { type: "element", tag: "p", attributes: {}, value: null, children: [], annotations: {} }],
    ["non-array children", { type: "element", tag: "p", attributes: [], value: null, children: {}, annotations: {} }],
    ["element with no value slot", { type: "element", tag: "p", attributes: [], children: [], annotations: {} }],
    ["fragment with no children", { type: "fragment", annotations: {} }],
    ["attribute with no kind", { type: "element", tag: "p", attributes: [{ name: "a", value: 1 }], value: null, children: [], annotations: {} }],
    ["unknown attribute kind", { type: "element", tag: "p", attributes: [{ kind: "prop", name: "a", value: 1 }], value: null, children: [], annotations: {} }],
    ["attribute with no value", { type: "element", tag: "p", attributes: [{ kind: "attribute", name: "a" }], value: null, children: [], annotations: {} }],
    ["action with no payload", { type: "element", tag: "p", attributes: [{ kind: "action", event: "e", key: "k" }], value: null, children: [], annotations: {} }],
    ["non-string action key", { type: "element", tag: "p", attributes: [{ kind: "action", event: "e", key: 1, payload: null }], value: null, children: [], annotations: {} }],
    ["not an object at all", "text"],
  ];

  for (const [label, value] of rejected) {
    it(`rejects ${label}`, () => {
      expect(() => nodeFromJson(value)).toThrow(NodeDecodeError);
    });
  }

  it("does not infer a missing field from a default", () => {
    expect(() => nodeFromJson({ type: "text", value: 1 })).toThrow(/annotations/);
    expect(() =>
      nodeFromJson({ type: "element", tag: "p", attributes: [], children: [], annotations: {} }),
    ).toThrow(/value/);
  });

  it("preserves duplicate attribute names and their order", () => {
    const n: Node = {
      t: "element",
      tag: "p",
      attributes: [
        { t: "attribute", name: "data-x", value: 1 },
        { t: "attribute", name: "data-x", value: 2 },
      ],
      value: null,
      children: [],
      annotations: {},
    };
    expect(nodeFromJson(nodeToJson(n))).toEqual(n);
  });
});
