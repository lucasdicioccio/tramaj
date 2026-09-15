/**
 * `Node`/`NodeAttribute` and the strict `specs/node-json.md` encode/decode,
 * hand-written rather than derived so the "a decoder MUST reject ... MUST NOT
 * infer a missing field from a default" rules are enforced exactly.
 */

import { hasField, isJsonObject, jsonObjectFrom, type Json, type JsonObject } from "./json.js";

export type Annotations = Record<string, Json>;

export function noAnnotations(): Annotations {
  return {};
}

export type Node =
  | { t: "text"; value: Json; annotations: Annotations }
  | {
      t: "element";
      tag: string;
      attributes: NodeAttribute[];
      value: Json;
      children: Node[];
      annotations: Annotations;
    }
  | { t: "fragment"; children: Node[]; annotations: Annotations };

export type NodeAttribute =
  | { t: "attribute"; name: string; value: Json }
  | { t: "action"; event: string; key: string; payload: Json };

export function textNode(value: Json, annotations: Annotations = noAnnotations()): Node {
  return { t: "text", value, annotations };
}

export function elementNode(
  tag: string,
  attributes: NodeAttribute[],
  value: Json,
  children: Node[],
  annotations: Annotations = noAnnotations(),
): Node {
  return { t: "element", tag, attributes, value, children, annotations };
}

export function fragmentNode(children: Node[], annotations: Annotations = noAnnotations()): Node {
  return { t: "fragment", children, annotations };
}

function annotationsToJson(anns: Annotations): JsonObject {
  return jsonObjectFrom(Object.keys(anns).map((k) => [k, anns[k] as Json] as const));
}

export function nodeToJson(n: Node): Json {
  switch (n.t) {
    case "text":
      return { type: "text", value: n.value, annotations: annotationsToJson(n.annotations) };
    case "element":
      return {
        type: "element",
        tag: n.tag,
        attributes: n.attributes.map(nodeAttributeToJson),
        value: n.value,
        children: n.children.map(nodeToJson),
        annotations: annotationsToJson(n.annotations),
      };
    case "fragment":
      return {
        type: "fragment",
        children: n.children.map(nodeToJson),
        annotations: annotationsToJson(n.annotations),
      };
  }
}

export function nodeAttributeToJson(a: NodeAttribute): Json {
  return a.t === "attribute"
    ? { kind: "attribute", name: a.name, value: a.value }
    : { kind: "action", event: a.event, key: a.key, payload: a.payload };
}

export class NodeDecodeError extends Error {
  override readonly name = "NodeDecodeError";
}

function req(what: string, field: string, obj: JsonObject): Json {
  if (!hasField(obj, field)) {
    throw new NodeDecodeError(`${what}: missing required field ${JSON.stringify(field)}`);
  }
  return obj[field] as Json;
}

function reqString(what: string, field: string, obj: JsonObject): string {
  const v = req(what, field, obj);
  if (typeof v !== "string") {
    throw new NodeDecodeError(`${what}: field ${JSON.stringify(field)} must be a string`);
  }
  return v;
}

function reqArray(what: string, field: string, obj: JsonObject): Json[] {
  const v = req(what, field, obj);
  if (!Array.isArray(v)) {
    throw new NodeDecodeError(`${what}: field ${JSON.stringify(field)} must be an array`);
  }
  return v;
}

function reqAnnotations(obj: JsonObject): Annotations {
  const v = req("node", "annotations", obj);
  if (!isJsonObject(v)) {
    throw new NodeDecodeError('node: field "annotations" must be an object');
  }
  return jsonObjectFrom(Object.keys(v).map((k) => [k, v[k] as Json] as const));
}

export function nodeFromJson(v: Json): Node {
  if (!isJsonObject(v)) throw new NodeDecodeError("expected a JSON object for a node");
  const type = reqString("node", "type", v);
  switch (type) {
    case "text":
      return { t: "text", value: req("text node", "value", v), annotations: reqAnnotations(v) };
    case "element":
      return {
        t: "element",
        tag: reqString("element node", "tag", v),
        attributes: reqArray("element node", "attributes", v).map(nodeAttributeFromJson),
        value: req("element node", "value", v),
        children: reqArray("element node", "children", v).map(nodeFromJson),
        annotations: reqAnnotations(v),
      };
    case "fragment":
      return {
        t: "fragment",
        children: reqArray("fragment node", "children", v).map(nodeFromJson),
        annotations: reqAnnotations(v),
      };
    default:
      throw new NodeDecodeError(`unknown node type: ${JSON.stringify(type)}`);
  }
}

export function nodeAttributeFromJson(v: Json): NodeAttribute {
  if (!isJsonObject(v)) throw new NodeDecodeError("expected a JSON object for a node attribute");
  const kind = reqString("node attribute", "kind", v);
  switch (kind) {
    case "attribute":
      return {
        t: "attribute",
        name: reqString("attribute", "name", v),
        value: req("attribute", "value", v),
      };
    case "action":
      return {
        t: "action",
        event: reqString("action", "event", v),
        key: reqString("action", "key", v),
        payload: req("action", "payload", v),
      };
    default:
      throw new NodeDecodeError(`unknown node attribute kind: ${JSON.stringify(kind)}`);
  }
}

/** Rewrites every action reachable in a tree, leaving everything else untouched. */
export function mapActions(
  n: Node,
  f: (event: string, key: string, payload: Json) => NodeAttribute,
): Node {
  switch (n.t) {
    case "text":
      return n;
    case "element":
      return {
        ...n,
        attributes: n.attributes.map((a) =>
          a.t === "action" ? f(a.event, a.key, a.payload) : a,
        ),
        children: n.children.map((c) => mapActions(c, f)),
      };
    case "fragment":
      return { ...n, children: n.children.map((c) => mapActions(c, f)) };
  }
}
