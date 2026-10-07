
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
