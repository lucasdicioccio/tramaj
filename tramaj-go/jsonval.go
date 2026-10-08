package tramaj

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"math/big"
	"sort"
	"strconv"
	"strings"
	"unicode/utf16"
)

// JSON is the ordinary JSON value domain (specs/node-json.md): nil, bool,
// int64, float64, string, []JSON or *Object. An object keeps its keys in
// insertion order.
//
// A number is an integer or a float, and the Go type says which
// (specs/reference.md section 3): an int64 is an integer and a float64 is a
// float, so int64(3) and float64(3) are two values, written 3 and 3.0. No
// other Go numeric type is a JSON value; a host converts an int to int64
// itself.
//
// Integer range: this port has the signed 64-bit range, -2^63 to 2^63 - 1
// (specs/reference.md section 13).
//
// A value this package produces holds only integers in that range and floats
// that are finite and not a negative zero. ParseJSON is more lenient, so
// that refusing a number is left to whoever decodes the value: it reads an
// integer-form number outside the range as a *big.Int, exactly, and a float
// too large for a double as an infinity. NormalizeNumbers is what refuses
// both, and every decoding boundary of this package goes through it.
type JSON = any

// OrderedMap is a string-keyed map that remembers insertion order. Setting an
// existing key replaces its value and keeps its position. A nil map reads as
// empty.
type OrderedMap[T any] struct {
	keys []string
	m    map[string]T
}

// Object is a JSON object.
type Object = OrderedMap[JSON]

func NewOrderedMap[T any]() *OrderedMap[T] {
	return &OrderedMap[T]{m: map[string]T{}}
}

// NewObject builds a JSON object from alternating key, value arguments.
func NewObject(kv ...any) *Object {
	o := NewOrderedMap[JSON]()
	for i := 0; i+1 < len(kv); i += 2 {
		o.Set(kv[i].(string), kv[i+1])
	}
	return o
}

func (o *OrderedMap[T]) Get(k string) (T, bool) {
	if o == nil {
		var zero T
		return zero, false
	}
	v, ok := o.m[k]
	return v, ok
}

func (o *OrderedMap[T]) Has(k string) bool {
	_, ok := o.Get(k)
	return ok
}

func (o *OrderedMap[T]) Set(k string, v T) {
	if _, ok := o.m[k]; !ok {
		o.keys = append(o.keys, k)
	}
	o.m[k] = v
}

// Keys returns the keys in insertion order. The slice must not be modified.
func (o *OrderedMap[T]) Keys() []string {
	if o == nil {
		return nil
	}
	return o.keys
}

func (o *OrderedMap[T]) Len() int {
	if o == nil {
		return 0
	}
	return len(o.keys)
}

func (o *OrderedMap[T]) clone() *OrderedMap[T] {
	c := &OrderedMap[T]{keys: make([]string, 0, o.Len()), m: make(map[string]T, o.Len())}
	for _, k := range o.Keys() {
		c.Set(k, o.m[k])
	}
	return c
}

// normalizeNumber keeps -0 from escaping: a float has no negative zero
// (specs/reference.md section 3).
func normalizeNumber(n float64) float64 {
	if n == 0 {
		return 0
	}
	return n
}

// isIntegerForm reports whether the text of a number has neither a fraction
// nor an exponent, which makes it an integer (specs/reference.md section 5).
func isIntegerForm(text string) bool {
	return !strings.ContainsAny(text, ".eE")
}

// parseNumberText reads the text of a JSON number, or of a literal with its
// underscores dropped, by the rule of specs/reference.md section 3. An
// integer-form text is an int64, or a *big.Int when it is outside the signed
// 64-bit range; any other is the nearest float64, which is an infinity when
// the value is too large for a double. A zero has no sign.
func parseNumberText(text string) (JSON, error) {
	if isIntegerForm(text) {
		if n, err := strconv.ParseInt(text, 10, 64); err == nil {
			return n, nil
		}
		if n, ok := new(big.Int).SetString(text, 10); ok {
			return n, nil
		}
		return nil, fmt.Errorf("not a number: %s", text)
	}
	f, err := strconv.ParseFloat(text, 64)
	if err != nil && !math.IsInf(f, 0) {
		return nil, fmt.Errorf("not a number: %s", text)
	}
	return normalizeNumber(f), nil
}

// NormalizeNumbers is what a decoder does to the numbers of a JSON value it
// is about to treat as a Tramaj value, at any depth (specs/reference.md
// section 3, specs/node-json.md, Numbers). An integer outside the signed
// 64-bit range (a *big.Int, as ParseJSON reads one) and a float that is not
// finite are refused; a negative zero becomes zero. Anything that is not a
// JSON value is refused too. The input is not modified.
func NormalizeNumbers(v JSON) (JSON, error) {
	switch x := v.(type) {
	case nil, bool, string, int64:
		return v, nil
	case float64:
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return nil, errors.New("a float is too large for a double")
		}
		return normalizeNumber(x), nil
	case *big.Int:
		if x.IsInt64() {
			return x.Int64(), nil
		}
		return nil, fmt.Errorf("the integer %s is outside the signed 64-bit range", x.String())
	case []JSON:
		out := make([]JSON, len(x))
		for i, item := range x {
			n, err := NormalizeNumbers(item)
			if err != nil {
				return nil, err
			}
			out[i] = n
		}
		return out, nil
	case *Object:
		out := NewObject()
		for _, k := range x.Keys() {
			n, err := NormalizeNumbers(x.m[k])
			if err != nil {
				return nil, err
			}
			out.Set(k, n)
		}
		return out, nil
	}
	return nil, fmt.Errorf("not a JSON value: %T (an integer is an int64 and a float a float64)", v)
}

// ParseJSON decodes one JSON document into the JSON value domain, keeping
// object keys in source order. A duplicate key keeps its last value.
//
// Each number is typed by its text: one with neither a fraction nor an
// exponent is an integer, one with either is a float, so 3 is int64(3) and
// 3.0 and 3e0 are float64(3). No number is refused here; see JSON for what an
// out-of-range one is read as.
func ParseJSON(data []byte) (JSON, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	v, err := decodeJSONValue(dec)
	if err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, errors.New("unexpected trailing data after the JSON value")
	}
	return v, nil
}

func decodeJSONValue(dec *json.Decoder) (JSON, error) {
	tok, err := dec.Token()
	if err != nil {
		if err == io.EOF {
			return nil, io.ErrUnexpectedEOF
		}
		return nil, err
	}
	switch t := tok.(type) {
	case json.Delim:
		switch t {
		case '[':
			arr := []JSON{}
			for dec.More() {
				v, err := decodeJSONValue(dec)
				if err != nil {
					return nil, err
				}
				arr = append(arr, v)
			}
			if _, err := dec.Token(); err != nil {
				return nil, err
			}
			return arr, nil
		case '{':
			obj := NewObject()
			for dec.More() {
				ktok, err := dec.Token()
				if err != nil {
					return nil, err
				}
				k, ok := ktok.(string)
				if !ok {
					return nil, fmt.Errorf("expected an object key, got %v", ktok)
				}
				v, err := decodeJSONValue(dec)
				if err != nil {
					return nil, err
				}
				obj.Set(k, v)
			}
			if _, err := dec.Token(); err != nil {
				return nil, err
			}
			return obj, nil
		}
		return nil, fmt.Errorf("unexpected delimiter %v", t)
	case json.Number:
		return parseNumberText(string(t))
	default:
		return tok, nil
	}
}

// JSONEqual is structural equality, insensitive to object key order. An
// integer and a float are never equal, whatever they hold: 3 and 3.0 are two
// values.
func JSONEqual(a, b JSON) bool {
	switch x := a.(type) {
	case nil:
		return b == nil
	case bool:
		y, ok := b.(bool)
		return ok && x == y
	case int64:
		y, ok := b.(int64)
		return ok && x == y
	case *big.Int:
		y, ok := b.(*big.Int)
		return ok && x.Cmp(y) == 0
	case float64:
		y, ok := b.(float64)
		return ok && x == y
	case string:
		y, ok := b.(string)
		return ok && x == y
	case []JSON:
		y, ok := b.([]JSON)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if !JSONEqual(x[i], y[i]) {
				return false
			}
		}
		return true
	case *Object:
		y, ok := b.(*Object)
		if !ok || x.Len() != y.Len() {
			return false
		}
		for _, k := range x.Keys() {
			yv, ok := y.Get(k)
			if !ok || !JSONEqual(x.m[k], yv) {
				return false
			}
		}
		return true
	}
	return false
}

// shortestDigits gives the shortest round-tripping decimal digits of a
// positive finite double, as (digits, point) with the value
// 0.digits * 10**point.
func shortestDigits(x float64) (string, int) {
	s := strconv.FormatFloat(x, 'e', -1, 64)
	mant, exp, _ := strings.Cut(s, "e")
	e, _ := strconv.Atoi(exp)
	digits := strings.TrimRight(strings.Replace(mant, ".", "", 1), "0")
	if digits == "" {
		return "0", 1
	}
	return digits, e + 1
}

// FormatInteger renders an integer as its decimal digits, with a "-" when
// negative (specs/node-json.md, Numbers).
func FormatInteger(n int64) string {
	return strconv.FormatInt(n, 10)
}

// FormatFloat renders a float as the language writes it wherever a value
// becomes text (specs/node-json.md, Numbers; specs/reference.md section 6):
// the shortest round-trip text of ECMAScript's Number::toString, with ".0"
// appended when that text has neither a fraction nor an exponent, so a float
// never reads back as an integer: 1.0, 0.1, 100000000000.0, 1e+21.
func FormatFloat(n float64) string {
	s := FormatNumber(n)
	if math.IsNaN(n) || math.IsInf(n, 0) || strings.ContainsAny(s, ".e") {
		return s
	}
	return s + ".0"
}

// FormatNumber renders a double exactly as ECMAScript's Number::toString
// does, so a whole-valued one has no fraction. It is the first half of
// FormatFloat, which is the rendering the language uses.
func FormatNumber(n float64) string {
	if math.IsNaN(n) {
		return "NaN"
	}
	if math.IsInf(n, 1) {
		return "Infinity"
	}
	if math.IsInf(n, -1) {
		return "-Infinity"
	}
	if n == 0 {
		return "0"
	}
	sign := ""
	if n < 0 {
		sign = "-"
		n = -n
	}
	digits, point := shortestDigits(n)
	k := len(digits)
	// ECMAScript Number::toString, steps 5-10, with n = point.
	switch {
	case k <= point && point <= 21:
		return sign + digits + strings.Repeat("0", point-k)
	case 0 < point && point <= 21:
		return sign + digits[:point] + "." + digits[point:]
	case -6 < point && point <= 0:
		return sign + "0." + strings.Repeat("0", -point) + digits
	}
	e := point - 1
	exp := "+" + strconv.Itoa(e)
	if e < 0 {
		exp = "-" + strconv.Itoa(-e)
	}
	if k == 1 {
		return sign + digits + "e" + exp
	}
	return sign + digits[:1] + "." + digits[1:] + "e" + exp
}

// quoteString quotes as JSON.stringify does: only the characters JSON
// requires are escaped, everything else stays raw.
func quoteString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, ch := range s {
		switch ch {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		default:
			if ch < 0x20 {
				fmt.Fprintf(&b, `\u%04x`, ch)
			} else {
				b.WriteRune(ch)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

// lessUTF16 orders strings by UTF-16 code units, the order ECMAScript's `<`
// uses, so every implementation agrees on where astral characters sort.
func lessUTF16(a, b string) bool {
	if isASCII(a) && isASCII(b) {
		return a < b
	}
	x, y := utf16.Encode([]rune(a)), utf16.Encode([]rune(b))
	for i := 0; i < len(x) && i < len(y); i++ {
		if x[i] != y[i] {
			return x[i] < y[i]
		}
	}
	return len(x) < len(y)
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= 0x80 {
			return false
		}
	}
	return true
}

// sortedStrings deduplicates and sorts in UTF-16 code-unit order.
func sortedStrings(xs []string) []string {
	seen := make(map[string]bool, len(xs))
	out := make([]string, 0, len(xs))
	for _, x := range xs {
		if !seen[x] {
			seen[x] = true
			out = append(out, x)
		}
	}
	sort.Slice(out, func(i, j int) bool { return lessUTF16(out[i], out[j]) })
	return out
}

// CompactJSON renders compact JSON with object keys sorted
// (specs/reference.md section 6). A number keeps its type: an integer is
// written as its digits and a float always with a fraction or an exponent.
func CompactJSON(v JSON) string {
	var b strings.Builder
	writeCompact(&b, v)
	return b.String()
}

func writeCompact(b *strings.Builder, v JSON) {
	switch x := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		if x {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case int64:
		b.WriteString(FormatInteger(x))
	case float64:
		b.WriteString(FormatFloat(x))
	case *big.Int:
		b.WriteString(x.String())
	case string:
		b.WriteString(quoteString(x))
	case []JSON:
		b.WriteByte('[')
		for i, e := range x {
			if i > 0 {
				b.WriteByte(',')
			}
			writeCompact(b, e)
		}
		b.WriteByte(']')
	case *Object:
		keys := append([]string(nil), x.Keys()...)
		sort.Slice(keys, func(i, j int) bool { return lessUTF16(keys[i], keys[j]) })
		b.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(quoteString(k))
			b.WriteByte(':')
			writeCompact(b, x.m[k])
		}
		b.WriteByte('}')
	default:
		panic(fmt.Sprintf("tramaj: not a JSON value: %T", v))
	}
}

// DisplayString is str's rendering (section 6): raw at the top level, compact
// below it.
func DisplayString(v JSON) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	}
	return CompactJSON(v)
}

// PrettyJSON renders indented JSON in source key order, with numbers rendered
// the way the language does (3 for an integer, 3.0 for a float).
func PrettyJSON(v JSON) string {
	const pad = "  "
	var b strings.Builder
	var go_ func(x JSON, depth int)
	go_ = func(x JSON, depth int) {
		switch t := x.(type) {
		case []JSON:
			if len(t) == 0 {
				b.WriteString("[]")
				return
			}
			b.WriteString("[\n")
			for i, e := range t {
				if i > 0 {
					b.WriteString(",\n")
				}
				b.WriteString(strings.Repeat(pad, depth+1))
				go_(e, depth+1)
			}
			b.WriteString("\n" + strings.Repeat(pad, depth) + "]")
		case *Object:
			if t.Len() == 0 {
				b.WriteString("{}")
				return
			}
			b.WriteString("{\n")
			for i, k := range t.Keys() {
				if i > 0 {
					b.WriteString(",\n")
				}
				b.WriteString(strings.Repeat(pad, depth+1) + quoteString(k) + ": ")
				go_(t.m[k], depth+1)
			}
			b.WriteString("\n" + strings.Repeat(pad, depth) + "}")
		default:
			writeCompact(&b, x)
		}
	}
	go_(v, 0)
	return b.String()
}

func stringsJSON(xs []string) JSON {
	out := make([]JSON, len(xs))
	for i, x := range xs {
		out[i] = x
	}
	return out
}
