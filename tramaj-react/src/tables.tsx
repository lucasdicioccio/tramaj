/**
 * Introspection views over the symbolic envelope (`v3-symbols.md` §5.2) and
 * v4-types' `"types"`/`"type-constraints"` arrays (`v4-types.md` §8), plus a
 * program's analysis card. Playground-level conveniences, not part of the
 * normative fold contract — this is an example host, so treat the table layout
 * and origin formatting as a starting point, not a contract.
 *
 * An entry that doesn't match the expected shape renders as a `"?"` row rather
 * than being dropped or throwing: this is reading a JSON contract, not typed
 * data.
 */

import type { ReactNode } from "react";
import { isJsonObject, type Card, type Json } from "tramaj-js";

import { renderScalar } from "./fold.js";

function field(entry: Json, name: string): Json | undefined {
  return isJsonObject(entry) ? entry[name] : undefined;
}

function stringField(entry: Json, name: string): string | null {
  const v = field(entry, name);
  return typeof v === "string" ? v : null;
}

function stringArray(v: Json | undefined): string[] | null {
  if (!Array.isArray(v)) return null;
  return v.every((x): x is string => typeof x === "string") ? v : null;
}

/** The envelope's `"symbols"` array: id, origin, and the binding it was read into. */
export function SymbolTable({ entries }: { entries: Json[] }): ReactNode {
  if (entries.length === 0) return <p>No symbols.</p>;
  return (
    <table>
      <thead>
        <tr>
          <th>id</th>
          <th>origin</th>
          <th>binding</th>
        </tr>
      </thead>
      <tbody>
        {entries.map((entry, i) => (
          <tr key={i}>
            <td>
              <code>{stringField(entry, "id") ?? "?"}</code>
            </td>
            <td>{originText(entry)}</td>
            <td>{bindingCell(entry)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function bindingCell(entry: Json): ReactNode {
  const name = stringField(entry, "binding");
  return name === null ? "—" : <code>{name}</code>;
}

function originText(entry: Json): string {
  const origin = field(entry, "origin");
  if (origin === undefined || !isJsonObject(origin)) return "?";
  const kind = stringField(origin, "kind");
  if (kind === "alloc") {
    const site = origin["site"];
    const key = origin["key"];
    if (typeof site !== "number" || !Number.isInteger(site) || key === undefined) return "?";
    return `alloc @${site} ${renderScalar(key)}`;
  }
  if (kind === "demand") {
    const path = stringArray(origin["path"]);
    return path === null ? "?" : `demand ctx.${path.join(".")}`;
  }
  return "?";
}

/**
 * The envelope's `"constraints"` array: name and arguments, each argument shown
 * with `renderScalar` — so a symbol argument renders the same placeholder text
 * the symbol table's rows and the document tree use.
 */
export function ConstraintTable({ entries }: { entries: Json[] }): ReactNode {
  if (entries.length === 0) return <p>No constraints.</p>;
  return (
    <NameAndArguments
      entries={entries}
      renderArgument={renderScalar}
    />
  );
}

/**
 * `v4-types.md` §8's `"types"` array: canonical id, and its definition rendered
 * to short text. Declaration boundaries stay boundaries here too — a `ref`
 * definition shows only the id it points at, since that entry is its own row.
 */
export function TypesTable({ entries }: { entries: Json[] }): ReactNode {
  if (entries.length === 0) return <p>No types.</p>;
  return (
    <table>
      <thead>
        <tr>
          <th>id</th>
          <th>definition</th>
        </tr>
      </thead>
      <tbody>
        {entries.map((entry, i) => {
          const definition = field(entry, "definition");
          return (
            <tr key={i}>
              <td>
                <code>{stringField(entry, "id") ?? "?"}</code>
              </td>
              <td>
                <code>{definition === undefined ? "?" : resolvedTypeText(definition)}</code>
              </td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

/**
 * One `ResolvedType` JSON value (`v4-types.md` §8's tagged union) as a short
 * one-line text form — deliberately terse, since this is a table cell, not the
 * canonical id itself.
 */
export function resolvedTypeText(j: Json): string {
  if (!isJsonObject(j)) return "?";
  const kind = stringField(j, "kind");
  switch (kind) {
    case "prim":
      return stringField(j, "name") ?? "?";
    case "array": {
      const element = j["element"];
      return element === undefined ? "?" : `[${resolvedTypeText(element)}]`;
    }
    case "record": {
      const fields = j["fields"];
      if (!Array.isArray(fields)) return "?";
      return `{${fields.map(recordField).join(", ")}}`;
    }
    case "union": {
      const arms = j["arms"];
      if (!Array.isArray(arms)) return "?";
      return arms.map(unionArm).join(" | ");
    }
    case "ref":
      return stringField(j, "id") ?? "?";
    case "var": {
      const path = stringArray(j["path"]);
      return path === null ? "?" : `%ctx.${path.join(".")}`;
    }
    default:
      return "?";
  }
}

function recordField(f: Json): string {
  if (!isJsonObject(f)) return "?";
  const name = stringField(f, "name");
  const type = f["type"];
  if (name === null || type === undefined) return "?";
  return `${name}: ${resolvedTypeText(type)}`;
}

function unionArm(a: Json): string {
  if (!isJsonObject(a)) return "?";
  const name = stringField(a, "name");
  if (name === null) return "?";
  const payload = a["payload"];
  return payload === undefined ? name : `${name}(${resolvedTypeText(payload)})`;
}

/**
 * `v4-types.md` §8's `"type-constraints"` array — the same `name`/`arguments`
 * shape as the envelope's `"constraints"`, except a type argument is the erased
 * `{"$type": ...}` tag §7 reserves rather than a plain scalar, so it needs its
 * own argument formatter.
 */
export function TypeConstraintTable({ entries }: { entries: Json[] }): ReactNode {
  if (entries.length === 0) return <p>No type constraints.</p>;
  return <NameAndArguments entries={entries} renderArgument={typeConstraintArgText} />;
}

function typeConstraintArgText(a: Json): string {
  const tid = field(a, "$type");
  return typeof tid === "string" ? tid : renderScalar(a);
}

function NameAndArguments({
  entries,
  renderArgument,
}: {
  entries: Json[];
  renderArgument: (a: Json) => string;
}): ReactNode {
  return (
    <table>
      <thead>
        <tr>
          <th>name</th>
          <th>arguments</th>
        </tr>
      </thead>
      <tbody>
        {entries.map((entry, i) => {
          const args = field(entry, "arguments");
          return (
            <tr key={i}>
              <td>
                <code>{stringField(entry, "name") ?? "?"}</code>
              </td>
              <td>{(Array.isArray(args) ? args : []).map(renderArgument).join(", ")}</td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

/**
 * A `tramaj-js` analysis `Card` — what the program produces, what its own
 * `$ctx` must supply, every library it reaches, every action key it can emit,
 * and which import sites still leave one of their library's own parameters
 * unsupplied.
 *
 * Unlike the tables above this doesn't decode a JSON envelope: a host that
 * already has the `Program` and the `LibraryTable` calls `programCard` directly
 * and hands the typed result here.
 */
export function ProgramCard({ card }: { card: Card }): ReactNode {
  return (
    <dl className="card-summary">
      <dt>Produces</dt>
      <dd>
        <code>{card.produces}</code>
      </dd>
      <dt>Requires</dt>
      <dd>{codeList(card.requires.map(dotted))}</dd>
      <dt>Imports</dt>
      <dd>{codeList(card.imports)}</dd>
      <dt>Emits</dt>
      <dd>{codeList(card.emits)}</dd>
      <dt>Unsupplied</dt>
      <dd>
        {card.unsupplied.length === 0 ? (
          EMPTY
        ) : (
          <ul>
            {card.unsupplied.map(([name, missing], i) => (
              <li key={i}>
                <code>{name}</code>
                {": "}
                {missing.length === 0 ? EMPTY : codeList(missing.map(dotted))}
              </li>
            ))}
          </ul>
        )}
      </dd>
    </dl>
  );
}

const EMPTY = "—";

function dotted(path: string[]): string {
  return path.length === 0 ? "(whole context)" : path.join(".");
}

function codeList(xs: string[]): ReactNode {
  if (xs.length === 0) return EMPTY;
  return (
    <span>
      {xs.map((x, i) => (
        <span key={i}>
          {i > 0 ? ", " : ""}
          <code>{x}</code>
        </span>
      ))}
    </span>
  );
}
