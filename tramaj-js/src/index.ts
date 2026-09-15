/**
 * TypeScript port of the Tramaj language (`specs/reference.md`,
 * `specs/v3-symbols.md`, `specs/v4-types.md`, `specs/node-json.md`).
 * Hand-written, not generated from `tramaj/`, `tramaj-hs/` or `tramaj-rs/`;
 * agreement with those implementations is enforced by the shared corpus at
 * `corpus/cases/` (see `test/corpus.test.ts`).
 *
 * Module layout mirrors `tramaj-rs/src/*.rs` one-to-one. Nothing here depends
 * on React or the DOM — folding a `Node` into real UI output is
 * `tramaj-react`'s job, not the language's.
 */

export type {
  ActionAdaptation,
  Attribute,
  Expr,
  ParamValue,
  Program,
  Stmt,
  TypeConstraintArg,
  TypeExpr,
} from "./ast.js";
export {
  adaptKey,
  documentProgram,
  expressionProgram,
  letBindings,
  numberAllocs,
  subExprs,
  typeDecls,
  unlets,
} from "./ast.js";

export type { Json, JsonObject } from "./json.js";
export { compactJson, displayString, formatNumber, isJsonObject, jsonEqual } from "./json.js";

export type { Annotations, Node, NodeAttribute } from "./node.js";
export {
  elementNode,
  fragmentNode,
  mapActions,
  noAnnotations,
  nodeAttributeFromJson,
  nodeAttributeToJson,
  NodeDecodeError,
  nodeFromJson,
  nodeToJson,
  textNode,
} from "./node.js";

export { ParseError, parseProgram, tryParseProgram } from "./parser.js";

export type { Env, EvalErrorKind, LibraryTable, Mode, Output, Value } from "./eval.js";
export { evalProgram, EvalError, runProgram, toJson } from "./eval.js";

export type { Card, ProgramKind } from "./analysis.js";
export {
  constraintKinds,
  contextHoles,
  contextReads,
  deepActionKeys,
  deepConstraintKinds,
  deepContextHoles,
  deepSymbolDemands,
  programCard,
  programKind,
  staticActionKeys,
  staticImportNames,
  symbolDemands,
  symbolSites,
  transitiveImportNames,
  typeDeclarations,
  typeExprsIn,
  typeParamCollisions,
  typeParams,
  unsuppliedParams,
  unsuppliedTypeParams,
} from "./analysis.js";

export type { ResolvedConstraintArg, ResolvedType, TypeErrorKind } from "./types.js";
export {
  canonicalId,
  checkTypeParamCollisions,
  deepTypeConstraints,
  deepTypeReferences,
  eraseTypes,
  programTypeDecls,
  programTypeRoots,
  requireClosed,
  resolvedTypeEqual,
  resolveTypeExpr,
  typeClosure,
  typeConstraints,
  TypeError,
  typeReferences,
} from "./types.js";
