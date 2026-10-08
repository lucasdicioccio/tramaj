//! JSON as Tramaj reads and writes it: like any JSON value, except that a
//! number is an integer or a float, decided by its text (`specs/reference.md`
//! §3, `specs/node-json.md` *Numbers*, `specs/decisions.md` §18). Mirrors
//! `tramaj-hs/src/Tramaj/Json.hs`.
//!
//! This module exists because `serde_json::Value` cannot carry that
//! difference all the way: it reads `-0` as a float, an integer beyond 64
//! bits as a rounded double, and refuses `1e400` before a decoder can say
//! what is wrong with it. Everything Tramaj takes in or hands out as JSON
//! (the context, a `Node`'s payloads, an expression program's result, the
//! symbolic envelope) is therefore this [`Json`], read by [`parse`] and
//! written by [`stringify()`].
//!
//! [`from_serde`] and [`to_serde`] bridge to a `serde_json::Value`, and say
//! what each direction costs.
//!
//! **Integer range.** This implementation has the signed 64-bit range,
//! `-2^63` to `2^63 - 1` (`specs/reference.md` §13): an integer is an `i64`.

use std::collections::BTreeMap;

/// A JSON value whose numbers keep their type.
///
/// A value Tramaj produced holds an `Int` or a `Float` that is finite and
/// not a negative zero, and never an `Unrepresentable`. [`parse`] is more
/// lenient on purpose, so that refusing a number is left to whoever decodes
/// the value (see [`normalize_numbers`]).
///
/// Equality is structural, with object keys unordered. An integer and a
/// float are never equal, whatever they hold: `3` and `3.0` are two values.
#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    /// A number written with neither a fraction nor an exponent.
    Int(i64),
    /// A number written with a fraction or an exponent.
    Float(f64),
    String(String),
    Array(Vec<Json>),
    Object(BTreeMap<String, Json>),
    /// A number whose text denotes no value here: an integer-form number
    /// outside the signed 64-bit range, which is never rounded, or a float
    /// too large for a double, which is never read as an infinity. It holds
    /// that text. Only [`parse`] and [`from_serde`] produce it, and
    /// [`normalize_numbers`] refuses it.
    Unrepresentable(String),
}

impl Json {
    /// An object from its entries; a repeated key keeps its last value.
    pub fn object<K: Into<String>>(entries: impl IntoIterator<Item = (K, Json)>) -> Json {
        Json::Object(entries.into_iter().map(|(k, v)| (k.into(), v)).collect())
    }

    /// A string value.
    pub fn string(s: impl Into<String>) -> Json {
        Json::String(s.into())
    }
}

// Reading -------------------------------------------------------------------

/// Deeper nesting than this is refused, so that a hostile document cannot
/// exhaust the stack.
const MAX_DEPTH: usize = 512;

/// Reads JSON text, typing each number by its text (`specs/reference.md`
/// §3): one with neither a fraction nor an exponent is an `Int`, one with
/// either is a `Float`, so `3` is an integer and `3.0` and `3e0` are floats.
/// `-0` is the integer `0` and `-0.0` the float `0.0`.
///
/// No number is refused here: one that denotes no value is kept as an
/// `Unrepresentable`, and [`normalize_numbers`] is what refuses. An error is
/// text that is not JSON. A repeated key keeps its last value.
pub fn parse(src: &str) -> Result<Json, String> {
    let mut r = Reader { src, bytes: src.as_bytes(), pos: 0 };
    r.skip_space();
    let v = r.value(0)?;
    r.skip_space();
    if r.pos != r.bytes.len() {
        return Err(r.err("unexpected trailing input after the JSON value"));
    }
    Ok(v)
}

/// The value a JSON number's text denotes, as the literal of the same text
/// would (`specs/reference.md` §5). `text` must match the JSON number
/// grammar, or the Tramaj literal grammar with its `_` removed.
pub fn number_from_text(text: &str) -> Json {
    if text.contains(['.', 'e', 'E']) {
        match text.parse::<f64>() {
            Ok(d) if d.is_finite() => Json::Float(if d == 0.0 { 0.0 } else { d }),
            _ => Json::Unrepresentable(text.to_string()),
        }
    } else {
        match text.parse::<i64>() {
            Ok(n) => Json::Int(n),
            Err(_) => Json::Unrepresentable(text.to_string()),
        }
    }
}

struct Reader<'a> {
    src: &'a str,
    bytes: &'a [u8],
    pos: usize,
}

impl Reader<'_> {
    fn err(&self, msg: &str) -> String {
        format!("{msg} (at byte {})", self.pos)
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn skip_space(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\n' | b'\r' | b'\t')) {
            self.pos += 1;
        }
    }

    fn keyword(&mut self, word: &str, v: Json) -> Result<Json, String> {
        if self.src[self.pos..].starts_with(word) {
            self.pos += word.len();
            Ok(v)
        } else {
            Err(self.err("expected a JSON value"))
        }
    }

    fn value(&mut self, depth: usize) -> Result<Json, String> {
        if depth > MAX_DEPTH {
            return Err(self.err("JSON nested too deeply"));
        }
        match self.peek() {
            Some(b'n') => self.keyword("null", Json::Null),
            Some(b't') => self.keyword("true", Json::Bool(true)),
            Some(b'f') => self.keyword("false", Json::Bool(false)),
            Some(b'"') => self.string().map(Json::String),
            Some(b'[') => self.array(depth),
            Some(b'{') => self.object(depth),
            Some(b'-' | b'0'..=b'9') => self.number(),
            Some(_) => Err(self.err("expected a JSON value")),
            None => Err(self.err("unexpected end of JSON input")),
        }
    }

    fn array(&mut self, depth: usize) -> Result<Json, String> {
        self.pos += 1;
        let mut out = Vec::new();
        self.skip_space();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(Json::Array(out));
        }
        loop {
            self.skip_space();
            out.push(self.value(depth + 1)?);
            self.skip_space();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b']') => {
                    self.pos += 1;
                    return Ok(Json::Array(out));
                }
                _ => return Err(self.err("expected ',' or ']' in an array")),
            }
        }
    }

    fn object(&mut self, depth: usize) -> Result<Json, String> {
        self.pos += 1;
        let mut out = BTreeMap::new();
        self.skip_space();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(Json::Object(out));
        }
        loop {
            self.skip_space();
            if self.peek() != Some(b'"') {
                return Err(self.err("expected a string as an object key"));
            }
            let key = self.string()?;
            self.skip_space();
            if self.peek() != Some(b':') {
                return Err(self.err("expected ':' after an object key"));
            }
            self.pos += 1;
            self.skip_space();
            let v = self.value(depth + 1)?;
            out.insert(key, v);
            self.skip_space();
            match self.peek() {
                Some(b',') => self.pos += 1,
                Some(b'}') => {
                    self.pos += 1;
                    return Ok(Json::Object(out));
                }
                _ => return Err(self.err("expected ',' or '}' in an object")),
            }
        }
    }

    /// `-? (0 | [1-9][0-9]*) (\. [0-9]+)? ([eE] [+-]? [0-9]+)?`
    fn number(&mut self) -> Result<Json, String> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        match self.peek() {
            Some(b'0') => self.pos += 1,
            Some(b'1'..=b'9') => self.digits(),
            _ => return Err(self.err("expected a digit")),
        }
        if self.peek() == Some(b'.') {
            self.pos += 1;
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return Err(self.err("expected a digit after the decimal point"));
            }
            self.digits();
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.pos += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            if !matches!(self.peek(), Some(b'0'..=b'9')) {
                return Err(self.err("expected a digit in the exponent"));
            }
            self.digits();
        }
        Ok(number_from_text(&self.src[start..self.pos]))
    }

    fn digits(&mut self) {
        while matches!(self.peek(), Some(b'0'..=b'9')) {
            self.pos += 1;
        }
    }

    fn string(&mut self) -> Result<String, String> {
        self.pos += 1;
        let mut out = String::new();
        loop {
            let run = self.pos;
            while matches!(self.peek(), Some(c) if c != b'"' && c != b'\\' && c >= 0x20) {
                self.pos += 1;
            }
            // The run stops on an ASCII byte or at the end, so both ends are
            // character boundaries.
            out.push_str(&self.src[run..self.pos]);
            match self.peek() {
                Some(b'"') => {
                    self.pos += 1;
                    return Ok(out);
                }
                Some(b'\\') => {
                    self.pos += 1;
                    self.escape(&mut out)?;
                }
                Some(_) => return Err(self.err("control character in a string")),
                None => return Err(self.err("unterminated string")),
            }
        }
    }

    fn escape(&mut self, out: &mut String) -> Result<(), String> {
        let c = self.peek().ok_or_else(|| self.err("unterminated string"))?;
        self.pos += 1;
        match c {
            b'"' => out.push('"'),
            b'\\' => out.push('\\'),
            b'/' => out.push('/'),
            b'b' => out.push('\u{8}'),
            b'f' => out.push('\u{c}'),
            b'n' => out.push('\n'),
            b'r' => out.push('\r'),
            b't' => out.push('\t'),
            b'u' => {
                let hi = self.hex4()?;
                let code = if (0xD800..0xDC00).contains(&hi) {
                    if !self.src[self.pos..].starts_with("\\u") {
                        return Err(self.err("unpaired surrogate in a string"));
                    }
                    self.pos += 2;
                    let lo = self.hex4()?;
                    if !(0xDC00..0xE000).contains(&lo) {
                        return Err(self.err("unpaired surrogate in a string"));
                    }
                    0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                } else {
                    hi
                };
                match char::from_u32(code) {
                    Some(ch) => out.push(ch),
                    None => return Err(self.err("unpaired surrogate in a string")),
                }
            }
            _ => return Err(self.err("unknown escape sequence in a string")),
        }
        Ok(())
    }

    fn hex4(&mut self) -> Result<u32, String> {
        let end = self.pos + 4;
        let digits = self
            .bytes
            .get(self.pos..end)
            .filter(|ds| ds.iter().all(u8::is_ascii_hexdigit))
            .ok_or_else(|| self.err("expected four hexadecimal digits"))?;
        // Four ASCII hexadecimal digits: valid UTF-8, and within `u32`.
        let n = u32::from_str_radix(std::str::from_utf8(digits).unwrap_or("0"), 16).unwrap_or(0);
        self.pos = end;
        Ok(n)
    }
}

// Writing -------------------------------------------------------------------

/// Compact JSON, with object keys in sorted order and a number written by
/// its type (`specs/node-json.md`, *Numbers*): an integer as its digits, a
/// float always with a fraction or an exponent.
///
/// This is also `str`'s rendering of an array or an object and v3-symbols
/// §1.4's canon, which is why the key order is fixed.
pub fn stringify(v: &Json) -> String {
    let mut out = String::new();
    write_json(&mut out, v);
    out
}

fn write_json(out: &mut String, v: &Json) {
    match v {
        Json::Null => out.push_str("null"),
        Json::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Json::Int(n) => out.push_str(&format_integer(*n)),
        Json::Float(d) => out.push_str(&format_float(*d)),
        Json::String(s) => out.push_str(&quote_string(s)),
        Json::Array(xs) => {
            out.push('[');
            for (i, x) in xs.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                write_json(out, x);
            }
            out.push(']');
        }
        Json::Object(o) => {
            out.push('{');
            for (i, (k, x)) in o.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&quote_string(k));
                out.push(':');
                write_json(out, x);
            }
            out.push('}');
        }
        // Not a value: written as it was read, so that a `Json` nobody
        // normalized still shows what it holds.
        Json::Unrepresentable(text) => out.push_str(text),
    }
}

impl std::fmt::Display for Json {
    /// [`stringify()`].
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&stringify(self))
    }
}

/// A JSON string literal, escaped by `serde_json` itself so this does not
/// grow a second, subtly different escaping table.
pub fn quote_string(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string())
}

/// An integer as its decimal digits, with a `-` when negative: no fraction
/// and no exponent, whatever its size.
pub fn format_integer(n: i64) -> String {
    n.to_string()
}

/// A float as the shortest round-trip text of ECMAScript's
/// `Number::toString`, with `.0` appended when that text has neither a
/// fraction nor an exponent: `1.0`, `0.1`, `100000000000.0`, `1e+21`,
/// `1e-7`. A float therefore never reads back as an integer.
pub fn format_float(d: f64) -> String {
    let shortest = format_double(d);
    if !d.is_finite() || shortest.contains(['.', 'e']) {
        shortest
    } else {
        shortest + ".0"
    }
}

/// Formats a double exactly as ECMAScript's `Number::toString` does. NaN and
/// the infinities are not values (`specs/reference.md` §3); they are written
/// as ECMAScript names them only so that a `Json` nobody normalized still
/// shows what it holds.
fn format_double(d: f64) -> String {
    if d.is_nan() {
        return "NaN".to_string();
    }
    if d.is_infinite() {
        return if d < 0.0 { "-Infinity" } else { "Infinity" }.to_string();
    }
    if d == 0.0 {
        return "0".to_string();
    }
    if d < 0.0 {
        return format!("-{}", format_positive(-d));
    }
    format_positive(d)
}

/// ECMAScript's `Number::toString` digit-placement rules, given the
/// shortest round-tripping decimal digit sequence and exponent that Rust's
/// own `{:e}` formatting already computes: only the placement is done here.
fn format_positive(d: f64) -> String {
    let (digits, n) = shortest_digits(d);
    let k = digits.len() as i32;
    if n >= k && n <= 21 {
        format!("{}{}", digits, "0".repeat((n - k) as usize))
    } else if n > 0 && n <= 21 {
        let n = n as usize;
        format!("{}.{}", &digits[..n], &digits[n..])
    } else if n > -6 && n <= 0 {
        format!("0.{}{}", "0".repeat((-n) as usize), digits)
    } else {
        let e = n - 1;
        let mantissa = if k == 1 {
            digits
        } else {
            format!("{}.{}", &digits[..1], &digits[1..])
        };
        let sign = if e >= 0 { "+" } else { "-" };
        format!("{mantissa}e{sign}{}", e.abs())
    }
}

/// Returns the shortest round-tripping digit string and the exponent `n`
/// such that the value equals `0.<digits> * 10^n`: what Haskell's
/// `floatToDigits 10` returns and what `format_positive` is written against.
fn shortest_digits(d: f64) -> (String, i32) {
    // Rust's `{:e}` gives the shortest round-tripping decimal mantissa and
    // exponent for a positive finite f64: "d.dddde<exp>" meaning
    // value == mantissa * 10^exp, mantissa in [1, 10).
    let s = format!("{d:e}");
    let (mantissa, exp) = s.split_once('e').expect("exponential form has an 'e'");
    let exp: i32 = exp.parse().expect("exponent is an integer");
    let digits: String = mantissa.chars().filter(|c| *c != '.').collect();
    let digits = digits.trim_end_matches('0');
    let digits = if digits.is_empty() { "0" } else { digits };
    (digits.to_string(), exp + 1)
}

// The number rules of a decoding boundary -------------------------------------

/// The bottom of this implementation's integer range, `-2^63`.
pub const MIN_INTEGER: i64 = i64::MIN;

/// The top of this implementation's integer range, `2^63 - 1`.
pub const MAX_INTEGER: i64 = i64::MAX;

/// A float as the value it denotes: one that is not finite is refused, and
/// a negative zero is zero, as the literal `-0.0` evaluates to `0.0`.
pub fn normalize_float(d: f64) -> Result<f64, String> {
    if !d.is_finite() {
        Err("a float is too large for a double".to_string())
    } else if d == 0.0 {
        Ok(0.0)
    } else {
        Ok(d)
    }
}

/// What a decoder does to the numbers of a JSON value it is about to treat
/// as a Tramaj value, at any depth: an `Unrepresentable` is refused, never
/// rounded (`specs/reference.md` §3, §13), and a float goes through
/// [`normalize_float`]. The context decoder and `node::node_from_json` both
/// go through here, so this is the one place that decides which numbers a
/// boundary refuses and which it rewrites.
pub fn normalize_numbers(v: &Json) -> Result<Json, String> {
    match v {
        Json::Float(d) => normalize_float(*d).map(Json::Float),
        Json::Unrepresentable(text) => Err(if text.contains(['.', 'e', 'E']) {
            format!("the float {text} is too large for a double")
        } else {
            format!("the integer {text} is outside the signed 64-bit range")
        }),
        Json::Array(xs) => xs.iter().map(normalize_numbers).collect::<Result<_, _>>().map(Json::Array),
        Json::Object(o) => o
            .iter()
            .map(|(k, x)| Ok((k.clone(), normalize_numbers(x)?)))
            .collect::<Result<_, String>>()
            .map(Json::Object),
        scalar => Ok(scalar.clone()),
    }
}

// Bridging to serde_json -------------------------------------------------------

/// From a `serde_json::Value`, which types a number by how its own parser
/// read it. That agrees with [`parse`] for `3`, `3.0` and `3e0`, and differs
/// in three places: `-0` arrives as the float `0.0`, an integer-form number
/// beyond 64 bits arrives as a rounded float, and one between `2^63` and
/// `2^64 - 1` is kept as an `Unrepresentable`. A host that needs the rule of
/// `specs/reference.md` §3 exactly reads its JSON text with [`parse`].
pub fn from_serde(v: &serde_json::Value) -> Json {
    match v {
        serde_json::Value::Null => Json::Null,
        serde_json::Value::Bool(b) => Json::Bool(*b),
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                Json::Int(i)
            } else if n.is_u64() {
                Json::Unrepresentable(n.to_string())
            } else {
                match n.as_f64() {
                    Some(d) if d.is_finite() => Json::Float(if d == 0.0 { 0.0 } else { d }),
                    _ => Json::Unrepresentable(n.to_string()),
                }
            }
        }
        serde_json::Value::String(s) => Json::String(s.clone()),
        serde_json::Value::Array(xs) => Json::Array(xs.iter().map(from_serde).collect()),
        serde_json::Value::Object(o) => Json::Object(o.iter().map(|(k, x)| (k.clone(), from_serde(x))).collect()),
    }
}

/// To a `serde_json::Value`. An integer and a float stay two kinds of
/// `serde_json::Number`, and `serde_json` writes a whole float with a
/// fraction, but its float text is not ECMAScript's (`1e21`, where
/// [`stringify()`] writes `1e+21`). A float that is not finite and an
/// `Unrepresentable` become `null`. Use [`stringify()`] to write a value as
/// `specs/node-json.md` requires.
pub fn to_serde(v: &Json) -> serde_json::Value {
    match v {
        Json::Null | Json::Unrepresentable(_) => serde_json::Value::Null,
        Json::Bool(b) => serde_json::Value::Bool(*b),
        Json::Int(n) => serde_json::Value::Number((*n).into()),
        Json::Float(d) => serde_json::Number::from_f64(*d)
            .map(serde_json::Value::Number)
            .unwrap_or(serde_json::Value::Null),
        Json::String(s) => serde_json::Value::String(s.clone()),
        Json::Array(xs) => serde_json::Value::Array(xs.iter().map(to_serde).collect()),
        Json::Object(o) => serde_json::Value::Object(o.iter().map(|(k, x)| (k.clone(), to_serde(x))).collect()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_number_is_typed_by_its_text() {
        assert_eq!(parse("3"), Ok(Json::Int(3)));
        assert_eq!(parse("3.0"), Ok(Json::Float(3.0)));
        assert_eq!(parse("3e0"), Ok(Json::Float(3.0)));
        assert_ne!(parse("3"), parse("3.0"));
        assert_eq!(parse("-0"), Ok(Json::Int(0)));
        assert_eq!(parse("-9223372036854775808"), Ok(Json::Int(i64::MIN)));
        assert_eq!(parse("9223372036854775807"), Ok(Json::Int(i64::MAX)));
    }

    #[test]
    fn a_negative_zero_float_reads_as_zero() {
        match parse("-0.0") {
            Ok(Json::Float(d)) => assert!(d == 0.0 && d.is_sign_positive()),
            other => panic!("unexpected {other:?}"),
        }
        match parse("-1e-400") {
            Ok(Json::Float(d)) => assert!(d == 0.0 && d.is_sign_positive()),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn a_number_without_a_value_is_kept_and_then_refused() {
        for text in ["9223372036854775808", "-9223372036854775809", "123456789012345678901234567890", "1e400", "-1e400"] {
            let v = parse(&format!("[{{\"k\": {text}}}]")).unwrap();
            assert_eq!(
                v,
                Json::Array(vec![Json::object([("k", Json::Unrepresentable(text.to_string()))])])
            );
            assert!(normalize_numbers(&v).is_err(), "{text} should be refused");
        }
    }

    #[test]
    fn text_that_is_not_json_is_an_error() {
        for bad in ["", "01", "1.", ".5", "1e", "+1", "[1,]", "{\"a\":1,}", "nul", "\"a", "1 2", "\"\\ud800\"", "- 1"] {
            assert!(parse(bad).is_err(), "{bad:?} should not parse");
        }
    }

    #[test]
    fn strings_and_structures_round_trip() {
        let src = r#"{"b":[1,2.5,"x\n\"y\"",null,true],"a":{"é":"\ud83d\ude00"}}"#;
        let v = parse(src).unwrap();
        assert_eq!(stringify(&v), "{\"a\":{\"é\":\"😀\"},\"b\":[1,2.5,\"x\\n\\\"y\\\"\",null,true]}");
        assert_eq!(parse(&stringify(&v)), Ok(v));
    }

    #[test]
    fn a_number_is_written_by_its_type() {
        assert_eq!(stringify(&Json::Int(3)), "3");
        assert_eq!(stringify(&Json::Int(100000000000)), "100000000000");
        assert_eq!(stringify(&Json::Int(i64::MIN)), "-9223372036854775808");
        assert_eq!(stringify(&Json::Float(3.0)), "3.0");
        assert_eq!(stringify(&Json::Float(0.1)), "0.1");
        assert_eq!(stringify(&Json::Float(100000000000.0)), "100000000000.0");
        assert_eq!(stringify(&Json::Float(1e21)), "1e+21");
        assert_eq!(stringify(&Json::Float(1e-7)), "1e-7");
        assert_eq!(stringify(&Json::Float(-1.5)), "-1.5");
        assert_eq!(stringify(&Json::Float(0.0)), "0.0");
    }

    #[test]
    fn serde_bridge_keeps_the_two_number_types() {
        let v = from_serde(&serde_json::json!({"i": 3, "f": 3.0, "big": 18446744073709551615u64}));
        assert_eq!(
            v,
            Json::object([
                ("i", Json::Int(3)),
                ("f", Json::Float(3.0)),
                ("big", Json::Unrepresentable("18446744073709551615".to_string())),
            ])
        );
        assert_eq!(to_serde(&Json::Float(3.0)).to_string(), "3.0");
        assert_eq!(to_serde(&Json::Int(3)).to_string(), "3");
    }
}
