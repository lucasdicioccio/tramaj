
# should care about semantics and data-portability

- embeddable in the host
- normalized at the output
- normalized at the output

# static analysis

- many static analysis should be cheap
- set and precedence of imports
- set of possible actions
- bubbled up context holes

# determinism

- templates must be referentially transparent
- evaluation should be deterministic in the result
- outside binding precedence, we do not preclude any evaluation order

# arithmetic

- residual law: a term the host evaluates, with numbers substituted for its symbols, must give byte for byte what the template would have produced with those numbers in the context, errors included
- (specified in reference §11 and v3-symbols §1.9, not implemented yet)

# sorting and number formatting

- a sort has exactly one result: elements in key order, equal keys in input order, whatever algorithm produced it
- `sort-by-descending` is stable on its own terms, and is not the reversal of `sort-by`
- one rounding rule: for a float `x` whose rounding is in the integer range, `str(round(x))` and `format-number(x, 0, "")` are the same text
- `format-number` depends on nothing but its three arguments: no locale, no host default
- (specified in reference §11, not implemented yet)
