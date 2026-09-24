//! Hand-written recursive-descent lexer + parser for the surface syntax
//! (`specs/reference.md` §5, §8 desugaring; `specs/v3-symbols.md` §1-2).
//! Mirrors `tramaj-hs/src/Tramaj/Parser.hs`'s grammar, including its "name
//! recognition backtracks; the shape does not" rule for the special forms
//! and the static-position (no-interpolation) restrictions. Covers R1 (core
//! v2) plus R2 (`?(key)`, `?ctx.path`, `constraint(...)`, `!`) — no v4
//! `type `, which is simply not recognized, so it either fails to parse or
//! (harmlessly, since out of scope) parses as an ordinary call/path.

use crate::ast::{
    number_allocs, ActionAdaptation, Attribute, Expr, ParamValue, Program, TypeConstraintArg, TypeExpr,
};

#[derive(Debug, Clone, PartialEq)]
pub struct ParseError(pub String);

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

type PResult<T> = Result<T, ParseError>;

const SPECIAL_FORM_NAMES: &[&str] = &[
    "map",
    "filter",
    "scan",
    "fold",
    "branch",
    "import",
    "adapt-actions",
    "constraint",
];

/// The five value-domain shapes `v4-types.md` §1 reserves as type
/// primitives. Fixed and closed, so recognized at parse time rather than
/// left for a later resolution pass to classify.
const PRIM_NAMES: &[&str] = &["string", "number", "bool", "null", "document"];

struct P {
    chars: Vec<char>,
    pos: usize,
}

enum ElementArg {
    Attr(Attribute),
    Value(Expr),
    Child(Expr),
}

enum StringPart {
    Lit(String),
    Interp(Expr),
}

impl P {
    fn new(src: &str) -> Self {
        P {
            chars: src.chars().collect(),
            pos: 0,
        }
    }

    fn err(&self, msg: &str) -> ParseError {
        ParseError(format!("at char {}: {msg}", self.pos))
    }

    fn eof(&self) -> bool {
        self.pos >= self.chars.len()
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn peek_at(&self, off: usize) -> Option<char> {
        self.chars.get(self.pos + off).copied()
    }

    fn advance(&mut self) -> Option<char> {
        let c = self.peek()?;
        self.pos += 1;
        Some(c)
    }

    /// Full save/restore backtracking around one alternative — the
    /// behavioral equivalent of wrapping `f` in Megaparsec's `try` and
    /// consuming it inside a `<|>` chain.
    fn attempt<T>(&mut self, f: impl FnOnce(&mut Self) -> PResult<T>) -> PResult<T> {
        let save = self.pos;
        match f(self) {
            Ok(v) => Ok(v),
            Err(e) => {
                self.pos = save;
                Err(e)
            }
        }
    }

    // Lexing ---------------------------------------------------------------

    fn skip_spaces(&mut self) {
        loop {
            match self.peek() {
                Some(c) if c.is_whitespace() => {
                    self.advance();
                }
                Some('-') if self.peek_at(1) == Some('-') => {
                    while let Some(c) = self.peek() {
                        if c == '\n' {
                            break;
                        }
                        self.advance();
                    }
                }
                _ => break,
            }
        }
    }

    fn lexeme<T>(&mut self, f: impl FnOnce(&mut Self) -> PResult<T>) -> PResult<T> {
        let v = f(self)?;
        self.skip_spaces();
        Ok(v)
    }

    fn literal(&mut self, s: &str) -> PResult<()> {
        let save = self.pos;
        for expected in s.chars() {
            match self.advance() {
                Some(c) if c == expected => {}
                _ => {
                    self.pos = save;
                    return Err(self.err(&format!("expected {s:?}")));
                }
            }
        }
        Ok(())
    }

    fn symbol(&mut self, s: &str) -> PResult<()> {
        self.lexeme(|p| p.literal(s))
    }

    fn char_lit(&mut self, c: char) -> PResult<char> {
        match self.peek() {
            Some(x) if x == c => {
                self.advance();
                Ok(x)
            }
            _ => Err(self.err(&format!("expected {c:?}"))),
        }
    }

    fn raw_ident(&mut self) -> PResult<String> {
        let c0 = match self.peek() {
            Some(c) if c.is_alphabetic() => c,
            _ => return Err(self.err("expected an identifier")),
        };
        self.advance();
        let mut s = String::new();
        s.push(c0);
        loop {
            match self.peek() {
                Some(c) if c.is_alphanumeric() || c == '_' => {
                    s.push(c);
                    self.advance();
                }
                Some('-') if self.peek_at(1).is_some_and(|c| c.is_alphanumeric() || c == '_') => {
                    s.push('-');
                    self.advance();
                }
                _ => break,
            }
        }
        Ok(s)
    }

    fn identifier(&mut self) -> PResult<String> {
        self.lexeme(|p| p.raw_ident())
    }

    fn path_tail(&mut self) -> PResult<(String, Vec<String>)> {
        let root = self.raw_ident()?;
        let mut rest = Vec::new();
        loop {
            let save = self.pos;
            if self.peek() == Some('.') {
                self.advance();
                match self.raw_ident() {
                    Ok(seg) => rest.push(seg),
                    Err(_) => {
                        self.pos = save;
                        break;
                    }
                }
            } else {
                break;
            }
        }
        Ok((root, rest))
    }

    fn field_access_suffix(&mut self) -> Vec<String> {
        let mut segs = Vec::new();
        loop {
            let save = self.pos;
            if self.peek() == Some('.') {
                self.advance();
                match self.raw_ident() {
                    Ok(seg) => segs.push(seg),
                    Err(_) => {
                        self.pos = save;
                        break;
                    }
                }
            } else {
                break;
            }
        }
        segs
    }

    fn apply_field_access(base: Expr, segs: Vec<String>) -> Expr {
        if segs.is_empty() {
            base
        } else {
            Expr::FieldAccess(Box::new(base), segs)
        }
    }

    // Static strings ---------------------------------------------------------

    fn static_string(&mut self) -> PResult<String> {
        self.lexeme(|p| {
            p.char_lit('"')?;
            let mut s = String::new();
            while let Some(c) = p.peek() {
                if c == '"' || c == '`' {
                    break;
                }
                s.push(c);
                p.advance();
            }
            match p.peek() {
                Some('"') => {
                    p.advance();
                    Ok(s)
                }
                _ => Err(p.err(
                    "this position must be a literal string, so it cannot contain an interpolation",
                )),
            }
        })
    }

    // String literals ---------------------------------------------------------

    fn string_lit(&mut self) -> PResult<Expr> {
        self.lexeme(|p| {
            p.char_lit('"')?;
            let mut parts = Vec::new();
            loop {
                match p.peek() {
                    Some('"') | None => break,
                    Some('`') => {
                        p.advance();
                        let e = p.expr()?;
                        p.char_lit('`')?;
                        parts.push(StringPart::Interp(e));
                    }
                    _ => {
                        let chunk = p.lit_chunk()?;
                        parts.push(StringPart::Lit(chunk));
                    }
                }
            }
            p.char_lit('"')?;
            Ok(desugar_string(parts))
        })
    }

    fn lit_chunk(&mut self) -> PResult<String> {
        let mut s = String::new();
        loop {
            match self.peek() {
                Some('\\') => {
                    self.advance();
                    s.push_str(&self.escape_seq()?);
                }
                Some(c) if c != '"' && c != '`' => {
                    s.push(c);
                    self.advance();
                }
                _ => break,
            }
        }
        if s.is_empty() {
            Err(self.err("expected string content"))
        } else {
            Ok(s)
        }
    }

    fn escape_seq(&mut self) -> PResult<String> {
        let c = self
            .advance()
            .ok_or_else(|| self.err("unterminated escape sequence"))?;
        match c {
            'n' => Ok("\n".to_string()),
            't' => Ok("\t".to_string()),
            'r' => Ok("\r".to_string()),
            '\\' => Ok("\\".to_string()),
            '"' => Ok("\"".to_string()),
            '`' => Ok("`".to_string()),
            '0' => Ok("\0".to_string()),
            'u' => {
                self.char_lit('{')?;
                let mut digits = String::new();
                while let Some(c) = self.peek() {
                    if c.is_ascii_hexdigit() {
                        digits.push(c);
                        self.advance();
                    } else {
                        break;
                    }
                }
                if digits.is_empty() {
                    return Err(self.err("invalid unicode escape"));
                }
                self.char_lit('}')?;
                let n = u32::from_str_radix(&digits, 16)
                    .map_err(|_| self.err("invalid unicode escape"))?;
                let ch = char::from_u32(n).ok_or_else(|| self.err("invalid unicode escape"))?;
                Ok(ch.to_string())
            }
            other => Err(self.err(&format!("unknown escape sequence: \\{other}"))),
        }
    }

    // Literals ------------------------------------------------------------

    /// `["-"] digits ["." digits] [("e"|"E") ["+"|"-"] digits]`, where a `_`
    /// may sit between two digits (reference.md §5, *Number literals*). The
    /// fraction and exponent are taken only when complete, so a stray `.`,
    /// `e` or `_` is left for the caller to reject. An overflow to infinity
    /// is refused and a zero is normalized so `-0` never escapes.
    fn number_lit(&mut self) -> PResult<Expr> {
        self.lexeme(|p| {
            let start = p.pos;
            let mut full = String::new();
            if p.peek() == Some('-') {
                p.advance();
                full.push('-');
            }
            if !p.digits(&mut full) {
                p.pos = start;
                return Err(p.err("expected a digit"));
            }
            let save = p.pos;
            if p.peek() == Some('.') {
                p.advance();
                let mut frac = String::from(".");
                if p.digits(&mut frac) {
                    full.push_str(&frac);
                } else {
                    p.pos = save;
                }
            }
            let save = p.pos;
            if matches!(p.peek(), Some('e') | Some('E')) {
                p.advance();
                let mut exp = String::from("e");
                if let Some(c @ ('+' | '-')) = p.peek() {
                    p.advance();
                    exp.push(c);
                }
                if p.digits(&mut exp) {
                    full.push_str(&exp);
                } else {
                    p.pos = save;
                }
            }
            match full.parse::<f64>() {
                Ok(n) if n.is_infinite() => Err(p.err("number literal out of range")),
                Ok(n) if n == 0.0 => Ok(Expr::NumberLit(0.0)),
                Ok(n) => Ok(Expr::NumberLit(n)),
                Err(_) => Err(p.err("invalid number literal")),
            }
        })
    }

    /// `digit { ["_"] digit }`, appended to `out` with the underscores
    /// dropped. Consumes nothing and answers `false` when no digit is next.
    fn digits(&mut self, out: &mut String) -> bool {
        match self.peek() {
            Some(c) if c.is_ascii_digit() => {}
            _ => return false,
        }
        loop {
            match self.peek() {
                Some(c) if c.is_ascii_digit() => {
                    out.push(c);
                    self.advance();
                }
                Some('_') if matches!(self.peek_at(1), Some(c) if c.is_ascii_digit()) => {
                    self.advance();
                }
                _ => return true,
            }
        }
    }

    fn keyword_lit(&mut self) -> PResult<Expr> {
        let name = self.identifier()?;
        match name.as_str() {
            "true" => Ok(Expr::BoolLit(true)),
            "false" => Ok(Expr::BoolLit(false)),
            "null" => Ok(Expr::NullLit),
            _ => Err(self.err("not a literal keyword")),
        }
    }

    fn array_lit(&mut self) -> PResult<Expr> {
        self.symbol("[")?;
        let elems = self.sep_end_by(",", Self::expr)?;
        self.symbol("]")?;
        Ok(Expr::ArrayLit(elems))
    }

    fn object_lit(&mut self) -> PResult<Expr> {
        self.symbol("{")?;
        let entries = self.sep_end_by(",", Self::obj_entry)?;
        self.symbol("}")?;
        Ok(Expr::ObjectLit(entries))
    }

    fn obj_entry(&mut self) -> PResult<(String, Expr)> {
        if let Ok(v) = self.attempt(Self::explicit_entry) {
            return Ok(v);
        }
        let k = self.identifier()?;
        Ok((k.clone(), Expr::Path(k, vec![])))
    }

    fn explicit_entry(&mut self) -> PResult<(String, Expr)> {
        let k = self.object_key()?;
        reserved_key_refused(self, &k)?;
        self.symbol(":")?;
        let v = self.expr()?;
        Ok((k, v))
    }

    fn object_key(&mut self) -> PResult<String> {
        if let Ok(s) = self.attempt(Self::static_string) {
            return Ok(s);
        }
        self.identifier()
    }

    // Sep-end-by helper -----------------------------------------------------

    fn sep_end_by<T>(
        &mut self,
        sep: &str,
        mut item: impl FnMut(&mut Self) -> PResult<T>,
    ) -> PResult<Vec<T>> {
        let mut out = Vec::new();
        if let Ok(v) = self.attempt(&mut item) {
            out.push(v);
        } else {
            return Ok(out);
        }
        loop {
            let save = self.pos;
            if self.symbol(sep).is_err() {
                self.pos = save;
                break;
            }
            match self.attempt(&mut item) {
                Ok(v) => out.push(v),
                Err(_) => {
                    self.pos = save;
                    break;
                }
            }
        }
        Ok(out)
    }

    // Expressions -----------------------------------------------------------

    fn path_expr(&mut self) -> PResult<Expr> {
        self.lexeme(|p| {
            p.char_lit('$')?;
            let (root, fields) = p.path_tail()?;
            Ok(Expr::Path(root, fields))
        })
    }

    /// `?(key)` (`v3-symbols.md` §1.2): allocates a symbol. The site is a
    /// placeholder here — `number_allocs` assigns the real one once the
    /// whole program has been parsed. A projection following it, as in
    /// `?(key).field`, is an ordinary field-access suffix.
    fn alloc_expr(&mut self) -> PResult<Expr> {
        self.char_lit('?')?;
        self.symbol("(")?;
        let key_expr = self.expr()?;
        self.char_lit(')')?;
        let segs = self.field_access_suffix();
        self.skip_spaces();
        Ok(Self::apply_field_access(
            Expr::Alloc(0, Box::new(key_expr)),
            segs,
        ))
    }

    /// `?ctx.a.b` (`v3-symbols.md` §1.3): the path MUST be rooted at `ctx` —
    /// unlike an ordinary read, an unsupplied demand allocates at the root
    /// rather than failing, so the language needs to tell the two apart
    /// before evaluating anything.
    fn demand_expr(&mut self) -> PResult<Expr> {
        self.lexeme(|p| {
            p.char_lit('?')?;
            let root = p.raw_ident()?;
            if root != "ctx" {
                return Err(p.err("a demand must be rooted at ctx, as in ?ctx.path"));
            }
            let mut path = Vec::new();
            loop {
                let save = p.pos;
                if p.peek() == Some('.') {
                    p.advance();
                    match p.raw_ident() {
                        Ok(seg) => path.push(seg),
                        Err(_) => {
                            p.pos = save;
                            break;
                        }
                    }
                } else {
                    break;
                }
            }
            Ok(Expr::Demand(path))
        })
    }

    fn call_expr(&mut self) -> PResult<Expr> {
        let _ = self.attempt(|p| p.char_lit('$'));
        let (root, fields) = self.path_tail()?;
        self.symbol("(")?;
        let args = self.sep_end_by(",", Self::expr)?;
        self.char_lit(')')?;
        let segs = self.field_access_suffix();
        self.skip_spaces();
        Ok(Self::apply_field_access(
            Expr::Call(Box::new(Expr::Path(root, fields)), args),
            segs,
        ))
    }

    fn lambda_expr(&mut self) -> PResult<Expr> {
        self.symbol("(")?;
        let params = self.sep_end_by(",", Self::identifier)?;
        self.symbol(")")?;
        self.symbol("=>")?;
        let body = self.expr()?;
        Ok(Expr::Lambda(params, Box::new(body)))
    }

    fn paren_expr(&mut self) -> PResult<Expr> {
        self.symbol("(")?;
        let e = self.expr()?;
        self.symbol(")")?;
        Ok(e)
    }

    /// Soft recognition only, per the module header: returns `Some(name)`
    /// having consumed the name (and trailing whitespace) iff it is one of
    /// the seven recognized special forms; otherwise fully restores.
    fn try_special_form_name(&mut self) -> Option<String> {
        let save = self.pos;
        let _ = self.attempt(|p| p.char_lit('$'));
        match self.identifier() {
            Ok(n) if SPECIAL_FORM_NAMES.contains(&n.as_str()) => Some(n),
            _ => {
                self.pos = save;
                None
            }
        }
    }

    /// Once the name is recognized, the shape does not backtrack: any error
    /// here is a hard parse error, per reference.md §5's "a malformed
    /// special form is a parse error".
    fn special_form_shape(&mut self, name: &str) -> PResult<Expr> {
        let base = match name {
            "map" => {
                let (a, b) = self.binary_shape()?;
                Expr::Map(Box::new(a), Box::new(b))
            }
            "filter" => {
                let (a, b) = self.binary_shape()?;
                Expr::Filter(Box::new(a), Box::new(b))
            }
            "scan" => {
                let (a, b, c) = self.ternary_shape()?;
                Expr::Scan(Box::new(a), Box::new(b), Box::new(c))
            }
            "fold" => {
                let (a, b, c) = self.ternary_shape()?;
                Expr::Fold(Box::new(a), Box::new(b), Box::new(c))
            }
            "branch" => self.branch_shape()?,
            "import" => self.import_shape()?,
            "adapt-actions" => self.adapt_actions_shape()?,
            "constraint" => self.constraint_shape()?,
            _ => unreachable!("name already checked against the recognized special-form set"),
        };
        let segs = self.field_access_suffix();
        self.skip_spaces();
        Ok(Self::apply_field_access(base, segs))
    }

    fn binary_shape(&mut self) -> PResult<(Expr, Expr)> {
        self.symbol("(")?;
        let a = self.expr()?;
        self.symbol(",")?;
        let b = self.expr()?;
        self.char_lit(')')?;
        Ok((a, b))
    }

    fn ternary_shape(&mut self) -> PResult<(Expr, Expr, Expr)> {
        self.symbol("(")?;
        let a = self.expr()?;
        self.symbol(",")?;
        let b = self.expr()?;
        self.symbol(",")?;
        let c = self.expr()?;
        self.char_lit(')')?;
        Ok((a, b, c))
    }

    fn branch_shape(&mut self) -> PResult<Expr> {
        self.symbol("(")?;
        let fallback = self.expr()?;
        let mut arms = Vec::new();
        loop {
            let save = self.pos;
            if self.symbol(",").is_err() {
                self.pos = save;
                break;
            }
            match self.attempt(Self::branch_arm) {
                Ok(arm) => arms.push(arm),
                Err(_) => {
                    self.pos = save;
                    break;
                }
            }
        }
        let _ = self.attempt(|p| p.symbol(","));
        self.char_lit(')')?;
        let mut acc = fallback;
        for (p, v) in arms.into_iter().rev() {
            acc = Expr::Branch(Box::new(p), Box::new(v), Box::new(acc));
        }
        Ok(acc)
    }

    fn branch_arm(&mut self) -> PResult<(Expr, Expr)> {
        let p = self.expr()?;
        self.symbol(",")?;
        let v = self.expr()?;
        Ok((p, v))
    }

    fn import_shape(&mut self) -> PResult<Expr> {
        self.symbol("(")?;
        let name = self.static_string()?;
        self.symbol(",")?;
        let params = self.import_params()?;
        self.char_lit(')')?;
        Ok(Expr::Import(name, params))
    }

    fn import_params(&mut self) -> PResult<Vec<(String, ParamValue)>> {
        self.symbol("{")?;
        let entries = self.sep_end_by(",", Self::param_entry)?;
        self.symbol("}")?;
        Ok(entries)
    }

    fn param_entry(&mut self) -> PResult<(String, ParamValue)> {
        if let Ok(v) = self.attempt(Self::explicit_param) {
            return Ok(v);
        }
        let k = self.identifier()?;
        Ok((k.clone(), ParamValue::PExpr(Expr::Path(k, vec![]))))
    }

    fn explicit_param(&mut self) -> PResult<(String, ParamValue)> {
        let k = self.object_key()?;
        self.symbol(":")?;
        let v = self.param_value()?;
        Ok((k, v))
    }

    fn param_value(&mut self) -> PResult<ParamValue> {
        if let Ok(t) = self.attempt(Self::marked_type_expr) {
            return Ok(ParamValue::PType(t));
        }
        if let Ok(v) = self.attempt(Self::ctx_param) {
            return Ok(v);
        }
        Ok(ParamValue::PExpr(self.expr()?))
    }

    // Types ---------------------------------------------------------------

    fn type_expr(&mut self) -> PResult<TypeExpr> {
        if let Ok(t) = self.attempt(Self::type_var) {
            return Ok(t);
        }
        if let Ok(t) = self.attempt(Self::type_union) {
            return Ok(t);
        }
        if let Ok(t) = self.attempt(Self::type_array) {
            return Ok(t);
        }
        if let Ok(t) = self.attempt(Self::type_record) {
            return Ok(t);
        }
        self.type_prim_or_ref()
    }

    /// Everything a union arm's payload may be — deliberately narrower than
    /// `type_expr`: a bare name is excluded because nothing marks where a
    /// nullary arm ends (`| Dev | Staging` must parse as two nullary arms).
    fn type_expr_payload(&mut self) -> PResult<TypeExpr> {
        if let Ok(t) = self.attempt(Self::type_var) {
            return Ok(t);
        }
        if let Ok(t) = self.attempt(Self::type_array) {
            return Ok(t);
        }
        self.type_record()
    }

    /// `%ctx.a.b` (`v4-types.md` §1): a type hole. The path MUST be rooted
    /// at `ctx`, mirroring `demand_expr` on the value side.
    fn type_var(&mut self) -> PResult<TypeExpr> {
        self.lexeme(|p| {
            p.char_lit('%')?;
            let root = p.raw_ident()?;
            if root != "ctx" {
                return Err(p.err("a type hole must be rooted at ctx, as in %ctx.path"));
            }
            Ok(TypeExpr::Var(p.dotted_path_tail()))
        })
    }

    fn dotted_path_tail(&mut self) -> Vec<String> {
        let mut path = Vec::new();
        loop {
            let save = self.pos;
            if self.peek() == Some('.') {
                self.advance();
                match self.raw_ident() {
                    Ok(seg) => path.push(seg),
                    Err(_) => {
                        self.pos = save;
                        break;
                    }
                }
            } else {
                break;
            }
        }
        path
    }

    /// A `%`-marked type argument, in the two positions v4-types §2 and §5
    /// both use it: an import parameter's value, and a `!type-constraint`
    /// argument. Unlike `type_var`, the leading `%` here does not require
    /// what follows to be `ctx` — `%Json` (§2's supply) and `%ctx.payload`
    /// (§6's forward) are both legal, told apart only after the `%` itself
    /// is seen.
    fn marked_type_expr(&mut self) -> PResult<TypeExpr> {
        self.char_lit('%')?;
        if let Ok(t) = self.attempt(Self::ctx_forward) {
            return Ok(t);
        }
        if let Ok(t) = self.attempt(Self::type_union) {
            return Ok(t);
        }
        if let Ok(t) = self.attempt(Self::type_array) {
            return Ok(t);
        }
        if let Ok(t) = self.attempt(Self::type_record) {
            return Ok(t);
        }
        self.type_prim_or_ref()
    }

    fn ctx_forward(&mut self) -> PResult<TypeExpr> {
        self.lexeme(|p| {
            let root = p.raw_ident()?;
            if root != "ctx" {
                return Err(p.err("a %-marked value must be ctx.path or a type expression"));
            }
            Ok(TypeExpr::Var(p.dotted_path_tail()))
        })
    }

    fn type_array(&mut self) -> PResult<TypeExpr> {
        self.symbol("[")?;
        let t = self.type_expr()?;
        self.symbol("]")?;
        Ok(TypeExpr::Array(Box::new(t)))
    }

    fn type_record(&mut self) -> PResult<TypeExpr> {
        self.symbol("{")?;
        let fields = self.sep_end_by(",", Self::type_field)?;
        self.symbol("}")?;
        Ok(TypeExpr::Record(fields))
    }

    /// Unlike an ordinary object literal's `object_key`, a field name here
    /// is always a bare identifier, never a quoted string — what keeps a
    /// canonical id (`types::canonical_id`) injective, since the id
    /// grammar's own delimiters (`:`, `,`, `[`, `]`, `|`) can never appear
    /// in one.
    fn type_field(&mut self) -> PResult<(String, TypeExpr)> {
        let k = self.identifier()?;
        self.symbol(":")?;
        let t = self.type_expr()?;
        Ok((k, t))
    }

    /// `| A T | B U | C` (`v4-types.md` §1.1): one or more arms, each a name
    /// with an optional payload. The first `|` may backtrack fully (so
    /// callers can try this as one alternative among several); once a `|`
    /// is consumed, its arm is a hard requirement, mirroring Megaparsec's
    /// `some` semantics that the reference parser relies on.
    fn type_union(&mut self) -> PResult<TypeExpr> {
        self.symbol("|")?;
        let mut arms = vec![self.union_arm()?];
        loop {
            let save = self.pos;
            if self.symbol("|").is_err() {
                self.pos = save;
                break;
            }
            arms.push(self.union_arm()?);
        }
        Ok(TypeExpr::Union(arms))
    }

    fn union_arm(&mut self) -> PResult<(String, Option<TypeExpr>)> {
        let name = self.identifier()?;
        let payload = self.attempt(Self::type_expr_payload).ok();
        Ok((name, payload))
    }

    /// A bare name (a primitive keyword or a declaration reference) or a
    /// library-qualified one, `$lib.types.Name`. Which of `Name` and
    /// `LibRef` applies is a purely syntactic distinction here; resolving
    /// either to a primitive, a declaration, or `UnresolvedType` is
    /// `types::resolve_type_expr`'s job.
    fn type_prim_or_ref(&mut self) -> PResult<TypeExpr> {
        if let Ok(t) = self.attempt(Self::type_lib_ref) {
            return Ok(t);
        }
        self.type_name_or_prim()
    }

    fn type_lib_ref(&mut self) -> PResult<TypeExpr> {
        self.lexeme(|p| {
            p.char_lit('$')?;
            let lib_name = p.raw_ident()?;
            p.char_lit('.')?;
            p.literal("types")?;
            p.char_lit('.')?;
            let type_name = p.raw_ident()?;
            Ok(TypeExpr::LibRef(lib_name, type_name))
        })
    }

    fn type_name_or_prim(&mut self) -> PResult<TypeExpr> {
        let name = self.identifier()?;
        Ok(if PRIM_NAMES.contains(&name.as_str()) {
            TypeExpr::Prim(name)
        } else {
            TypeExpr::Name(name)
        })
    }

    /// One argument to `!type-constraint` (`v4-types.md` §5): a `%`-marked
    /// type expression, or a literal scalar — reusing the same primitive
    /// literal parsers `number_lit`/`keyword_lit` use, unwrapped to the
    /// scalar the argument actually carries. A string scalar is
    /// `static_string`, not `string_lit`: like a constraint's own name,
    /// this position is never computed.
    fn type_constraint_arg(&mut self) -> PResult<TypeConstraintArg> {
        if let Ok(t) = self.attempt(Self::marked_type_expr) {
            return Ok(TypeConstraintArg::Type(t));
        }
        self.scalar_arg()
    }

    fn scalar_arg(&mut self) -> PResult<TypeConstraintArg> {
        if let Ok(s) = self.attempt(Self::static_string) {
            return Ok(TypeConstraintArg::ScalarStr(s));
        }
        if let Ok(e) = self.attempt(Self::number_lit) {
            return Ok(as_scalar_arg(e));
        }
        if let Ok(e) = self.attempt(Self::keyword_lit) {
            return Ok(as_scalar_arg(e));
        }
        Err(self.err("expected a type-constraint argument"))
    }

    /// `!type-constraint(name, args...)` (`v4-types.md` §5): tried before
    /// the general `!expr` emission, since both share the `!` leader and
    /// `type-constraint(...)` would otherwise parse as an ordinary call to
    /// an unbound name.
    fn type_emission(&mut self) -> PResult<Stmt> {
        self.char_lit('!')?;
        let kw = self.identifier()?;
        if kw != "type-constraint" {
            return Err(self.err("not a !type-constraint"));
        }
        self.symbol("(")?;
        let name = self.static_string()?;
        let mut args = Vec::new();
        loop {
            let save = self.pos;
            if self.symbol(",").is_err() {
                self.pos = save;
                break;
            }
            match self.attempt(Self::type_constraint_arg) {
                Ok(a) => args.push(a),
                Err(_) => {
                    self.pos = save;
                    break;
                }
            }
        }
        let _ = self.attempt(|p| p.symbol(","));
        self.char_lit(')')?;
        self.skip_spaces();
        Ok(Stmt::TypeEmit(name, args))
    }

    /// `type Name = TypeExpr` (`v4-types.md` §1.1): the fifth statement
    /// leader. Unlike `@`/`!`/`.`/`$` it is a whole keyword rather than a
    /// single character, so it is recognized by parsing a full identifier
    /// and checking it — the same device `keyword_lit` uses.
    fn type_decl_stmt(&mut self) -> PResult<Stmt> {
        let kw = self.identifier()?;
        if kw != "type" {
            return Err(self.err("not a type declaration"));
        }
        let name = self.identifier()?;
        self.symbol("=")?;
        let t = self.type_expr()?;
        Ok(Stmt::TypeDecl(name, t))
    }

    fn ctx_param(&mut self) -> PResult<ParamValue> {
        let save = self.pos;
        let n = self.identifier()?;
        if n != "ctx" || self.peek() != Some('(') {
            self.pos = save;
            return Err(self.err("not a ctx(...) parameter"));
        }
        self.symbol("(")?;
        let (root, fields) = self.path_tail()?;
        self.skip_spaces();
        self.char_lit(')')?;
        self.skip_spaces();
        let mut path = vec![root];
        path.extend(fields);
        Ok(ParamValue::PFromContext(path))
    }

    /// `constraint(name, arg1, arg2, ...)` (`v3-symbols.md` §2.1): a static
    /// string name, like an action's event and key, followed by any number
    /// of ordinary expressions — zero included, since the language fixes no
    /// signature for any name.
    fn constraint_shape(&mut self) -> PResult<Expr> {
        self.symbol("(")?;
        let name = self.static_string()?;
        let mut args = Vec::new();
        loop {
            let save = self.pos;
            if self.symbol(",").is_err() {
                self.pos = save;
                break;
            }
            match self.attempt(Self::expr) {
                Ok(e) => args.push(e),
                Err(_) => {
                    self.pos = save;
                    break;
                }
            }
        }
        let _ = self.attempt(|p| p.symbol(","));
        self.char_lit(')')?;
        Ok(Expr::Constrain(name, args))
    }

    fn adapt_actions_shape(&mut self) -> PResult<Expr> {
        self.symbol("(")?;
        let target = self.expr()?;
        self.symbol(",")?;
        let adaptation = self.adaptation_shape()?;
        let fn_ = self.attempt(|p| {
            p.symbol(",")?;
            p.expr()
        });
        let fn_ = fn_.ok();
        let _ = self.attempt(|p| p.symbol(","));
        self.char_lit(')')?;
        Ok(Expr::AdaptActions(
            Box::new(target),
            adaptation,
            fn_.map(Box::new),
        ))
    }

    fn adaptation_shape(&mut self) -> PResult<ActionAdaptation> {
        let name = self.identifier()?;
        match name.as_str() {
            "identity" => Ok(ActionAdaptation::Identity),
            "prefix" => {
                self.symbol("(")?;
                let p = self.static_string()?;
                self.char_lit(')')?;
                self.skip_spaces();
                Ok(ActionAdaptation::Prefix(p))
            }
            _ => Err(self.err("an action adaptation must be identity or prefix(\"...\")")),
        }
    }

    // Documents ---------------------------------------------------------------

    fn document_expr(&mut self) -> PResult<Expr> {
        self.char_lit('.')?;
        if let Ok(e) = self.attempt(Self::fragment_shape) {
            return Ok(e);
        }
        self.element_shape()
    }

    fn fragment_shape(&mut self) -> PResult<Expr> {
        self.symbol("(")?;
        let children = self.sep_end_by(",", Self::expr)?;
        self.symbol(")")?;
        Ok(Expr::Fragment(children))
    }

    fn element_shape(&mut self) -> PResult<Expr> {
        let tag = self.raw_ident()?;
        self.skip_spaces();
        self.symbol("(")?;
        let args = self.sep_end_by(",", Self::element_arg)?;
        self.symbol(")")?;
        build_element(self, tag, args)
    }

    fn element_arg(&mut self) -> PResult<ElementArg> {
        if let Some(arg) = self.try_attribute_position_arg()? {
            return Ok(arg);
        }
        if let Ok(attr) = self.attempt(Self::named_arg) {
            return Ok(ElementArg::Attr(attr));
        }
        Ok(ElementArg::Child(self.expr()?))
    }

    /// `action(...)`/`value(...)`: soft name+lookahead recognition, then a
    /// hard-committed shape, exactly as `special_form_shape` is for the
    /// top-level special forms.
    fn try_attribute_position_arg(&mut self) -> PResult<Option<ElementArg>> {
        let save = self.pos;
        let n = match self.identifier() {
            Ok(n) => n,
            Err(_) => {
                self.pos = save;
                return Ok(None);
            }
        };
        if self.peek() != Some('(') || (n != "action" && n != "value") {
            self.pos = save;
            return Ok(None);
        }
        if n == "action" {
            Ok(Some(ElementArg::Attr(self.action_shape()?)))
        } else {
            Ok(Some(ElementArg::Value(self.value_shape()?)))
        }
    }

    fn action_shape(&mut self) -> PResult<Attribute> {
        self.symbol("(")?;
        let event = self.static_string()?;
        self.symbol(",")?;
        let key = self.static_string()?;
        self.symbol(",")?;
        let payload = self.expr()?;
        self.symbol(")")?;
        Ok(Attribute::ActionAttr(event, key, payload))
    }

    fn value_shape(&mut self) -> PResult<Expr> {
        self.symbol("(")?;
        let v = self.expr()?;
        self.symbol(")")?;
        Ok(v)
    }

    fn named_arg(&mut self) -> PResult<Attribute> {
        let name = self.object_key()?;
        self.symbol(":")?;
        let v = self.expr()?;
        Ok(Attribute::Attr(name, v))
    }

    // Precedence ---------------------------------------------------------------

    fn expr(&mut self) -> PResult<Expr> {
        let first = self.operand()?;
        let mut acc = first;
        loop {
            let save = self.pos;
            match self.attempt(|p| {
                p.symbol("<>")?;
                p.operand()
            }) {
                Ok(rhs) => acc = Expr::Concat(Box::new(acc), Box::new(rhs)),
                Err(_) => {
                    self.pos = save;
                    break;
                }
            }
        }
        Ok(acc)
    }

    fn operand(&mut self) -> PResult<Expr> {
        if let Ok(e) = self.attempt(Self::keyword_lit) {
            return Ok(e);
        }
        if let Ok(e) = self.attempt(Self::lambda_expr) {
            return Ok(e);
        }
        if let Ok(e) = self.attempt(Self::paren_expr) {
            return Ok(e);
        }
        if let Some(name) = self.try_special_form_name() {
            return self.special_form_shape(&name);
        }
        if let Ok(e) = self.attempt(Self::call_expr) {
            return Ok(e);
        }
        if let Ok(e) = self.attempt(Self::path_expr) {
            return Ok(e);
        }
        if let Ok(e) = self.attempt(Self::alloc_expr) {
            return Ok(e);
        }
        if let Ok(e) = self.attempt(Self::demand_expr) {
            return Ok(e);
        }
        if let Ok(e) = self.attempt(Self::document_expr) {
            return Ok(e);
        }
        if let Ok(e) = self.attempt(Self::string_lit) {
            return Ok(e);
        }
        if let Ok(e) = self.attempt(Self::number_lit) {
            return Ok(e);
        }
        if let Ok(e) = self.attempt(Self::array_lit) {
            return Ok(e);
        }
        if let Ok(e) = self.attempt(Self::object_lit) {
            return Ok(e);
        }
        Err(self.err("expected an expression"))
    }

    // Programs -----------------------------------------------------------------

    /// `@name=expr` or `@name : T = expr` (`v4-types.md` §7), one per line —
    /// the optional `: T` is what tells `Stmt::Let` and `Stmt::Annotate`
    /// apart.
    fn binding(&mut self) -> PResult<Stmt> {
        self.char_lit('@')?;
        let name = self.identifier()?;
        let annot = self
            .attempt(|p| {
                p.symbol(":")?;
                p.type_expr()
            })
            .ok();
        self.symbol("=")?;
        let e = self.expr()?;
        Ok(match annot {
            Some(t) => Stmt::Annotate(name, t, e),
            None => Stmt::Let(name, e),
        })
    }

    /// `!expr` (`v3-symbols.md` §2.2): the fourth statement leader, joining
    /// `.`, `$` and `@`. A statement position only — it may not appear
    /// inside an expression, so there is no operand form for it.
    fn emission_stmt(&mut self) -> PResult<Expr> {
        self.char_lit('!')?;
        self.expr()
    }

    fn program(&mut self) -> PResult<Program> {
        self.skip_spaces();
        let mut statements: Vec<Stmt> = Vec::new();
        loop {
            if let Ok(st) = self.attempt(Self::binding) {
                statements.push(st);
                continue;
            }
            if let Ok(st) = self.attempt(Self::type_emission) {
                statements.push(st);
                continue;
            }
            if let Ok(e) = self.attempt(Self::emission_stmt) {
                statements.push(Stmt::Emit(e));
                continue;
            }
            if let Ok(st) = self.attempt(Self::type_decl_stmt) {
                statements.push(st);
                continue;
            }
            break;
        }
        let root = self.expr()?;
        self.skip_spaces();
        if !self.eof() {
            return Err(self.err("unexpected trailing input"));
        }
        let is_document = matches!(root, Expr::Element(_, _, _, _) | Expr::Fragment(_));
        let mut body = root;
        for stmt in statements.into_iter().rev() {
            body = match stmt {
                Stmt::Let(name, value) => Expr::Let(name, Box::new(value), Box::new(body)),
                Stmt::Emit(e) => Expr::Emit(Box::new(e), Box::new(body)),
                Stmt::TypeDecl(name, t) => Expr::TypeDecl(name, t, Box::new(body)),
                Stmt::Annotate(name, t, e) => Expr::TypeAnnotate(name, t, Box::new(e), Box::new(body)),
                Stmt::TypeEmit(name, args) => Expr::TypeEmit(name, args, Box::new(body)),
            };
        }
        number_allocs(&mut body);
        Ok(if is_document {
            Program::DocumentProgram(body)
        } else {
            Program::ExpressionProgram(body)
        })
    }
}

/// One statement of the surface program grammar (`v3-symbols.md` §2.2,
/// `v4-types.md` §1.1/§5.1/§7), after lowering, in the order the source
/// wrote them — what `program`'s fold rebuilds into the core
/// `Let`/`Emit`/`TypeDecl`/`TypeAnnotate`/`TypeEmit` chain. `type_emission`
/// is tried ahead of the generic `emission_stmt` since both share the `!`
/// leader.
enum Stmt {
    Let(String, Expr),
    Emit(Expr),
    TypeDecl(String, TypeExpr),
    Annotate(String, TypeExpr, Expr),
    TypeEmit(String, Vec<TypeConstraintArg>),
}

fn as_scalar_arg(e: Expr) -> TypeConstraintArg {
    match e {
        Expr::NumberLit(n) => TypeConstraintArg::ScalarNum(n),
        Expr::BoolLit(b) => TypeConstraintArg::ScalarBool(b),
        Expr::NullLit => TypeConstraintArg::ScalarNull,
        Expr::StringLit(s) => TypeConstraintArg::ScalarStr(s),
        _ => TypeConstraintArg::ScalarNull, // unreachable: number_lit/keyword_lit only ever produce the cases above
    }
}

fn reserved_key_refused(p: &P, k: &str) -> PResult<()> {
    if k == "$sym" || k == "$type" {
        Err(p.err(&format!(
            "\"{k}\" is a reserved key and cannot be used as an object key"
        )))
    } else {
        Ok(())
    }
}

fn build_element(p: &P, tag: String, args: Vec<ElementArg>) -> PResult<Expr> {
    let mut seen_child = false;
    for arg in &args {
        match arg {
            ElementArg::Child(_) => seen_child = true,
            _ => {
                if seen_child {
                    return Err(p.err(
                        "attributes, action(...) and value(...) must all come before an element's children",
                    ));
                }
            }
        }
    }
    let mut values = Vec::new();
    let mut attrs = Vec::new();
    let mut children = Vec::new();
    for arg in args {
        match arg {
            ElementArg::Attr(a) => attrs.push(a),
            ElementArg::Value(v) => values.push(v),
            ElementArg::Child(c) => children.push(c),
        }
    }
    let val = match values.len() {
        0 => Expr::NullLit,
        1 => values.into_iter().next().unwrap(),
        _ => return Err(p.err("an element can have at most one value(...)")),
    };
    Ok(Expr::Element(tag, attrs, Box::new(val), children))
}

fn desugar_string(parts: Vec<StringPart>) -> Expr {
    let coalesced = coalesce(parts);
    let mut iter = coalesced.into_iter();
    let first = match iter.next() {
        None => return Expr::StringLit(String::new()),
        Some(p) => part_expr(p),
    };
    iter.fold(first, |acc, p| Expr::Concat(Box::new(acc), Box::new(part_expr(p))))
}

fn part_expr(p: StringPart) -> Expr {
    match p {
        StringPart::Lit(s) => Expr::StringLit(s),
        StringPart::Interp(e) => Expr::Call(Box::new(Expr::Path("str".to_string(), vec![])), vec![e]),
    }
}

fn coalesce(parts: Vec<StringPart>) -> Vec<StringPart> {
    let mut out: Vec<StringPart> = Vec::new();
    for part in parts {
        match (out.last_mut(), &part) {
            (Some(StringPart::Lit(prev)), StringPart::Lit(next)) => {
                prev.push_str(next);
            }
            _ => out.push(part),
        }
    }
    out
}

pub fn parse_program(src: &str) -> Result<Program, ParseError> {
    let mut p = P::new(src);
    p.program()
}
