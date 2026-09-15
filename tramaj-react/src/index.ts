/**
 * React host for Tramaj. `foldToReact` is the whole contract; everything else
 * is an example host's conveniences.
 */

export type { Dispatch } from "./fold.js";
export {
  foldToReact,
  isValidAttrName,
  renderScalar,
  symbolLabel,
  validateAttrNames,
} from "./fold.js";

export {
  ConstraintTable,
  ProgramCard,
  resolvedTypeText,
  SymbolTable,
  TypeConstraintTable,
  TypesTable,
} from "./tables.js";
