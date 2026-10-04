package tramaj

import (
	"strings"
	"testing"
)

// specs/node-json.md's round-trip law and its explicit list of things a
// decoder MUST reject. The corpus only ever exercises the encoder, since it
// compares encoded output.

func mustJSON(t *testing.T, src string) JSON {
	t.Helper()
	v, err := ParseJSON([]byte(src))
	if err != nil {
		t.Fatalf("%s: %v", src, err)
	}
	return v
}

func TestNodeJSONRoundTrip(t *testing.T) {
	sample := &Node{
		Type: ElementNode,
		Tag:  "button",
		Attributes: []NodeAttribute{
			{Kind: PlainAttribute, Name: "class", Value: "primary"},
			{Kind: ActionAttribute, Event: "on-click", Key: "deploy", Payload: NewObject("deployment", "web")},
			// Duplicate attribute names and their order are preserved.
			{Kind: PlainAttribute, Name: "data-x", Value: 1.0},
			{Kind: PlainAttribute, Name: "data-x", Value: 2.0},
		},
		Children: []*Node{
			{Type: TextNode, Value: 3.0},
			{Type: FragmentNode, Children: []*Node{{Type: TextNode, Value: "a"}}},
		},
		Annotations: NewObject("origin", "test"),
	}
	encoded := NodeToJSON(sample)
	decoded, err := NodeFromJSON(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if again := NodeToJSON(decoded); !JSONEqual(encoded, again) {
		t.Fatalf("round trip changed the node\n  before: %s\n  after:  %s", CompactJSON(encoded), CompactJSON(again))
	}
	if got := decoded.Attributes[3].Value; got != 2.0 {
		t.Fatalf("attribute order was not preserved: last data-x is %v", got)
	}
}

func TestNodeJSONEncodesEveryRequiredField(t *testing.T) {
	got := NodeToJSON(&Node{Type: ElementNode, Tag: "p"})
	want := mustJSON(t, `{"type":"element","tag":"p","attributes":[],"value":null,"children":[],"annotations":{}}`)
	if !JSONEqual(got, want) {
		t.Fatalf("got %s", CompactJSON(got))
	}
}

func TestNodeJSONRejects(t *testing.T) {
	// Each case names the field the error must mention, when a missing field
	// is the point: a decoder must not infer it from a default.
	cases := []struct{ label, src, mentions string }{
		{"no type", `{"value":1,"annotations":{}}`, "type"},
		{"unknown type", `{"type":"comment","annotations":{}}`, ""},
		{"text with no value", `{"type":"text","annotations":{}}`, "value"},
		{"text with no annotations", `{"type":"text","value":1}`, "annotations"},
		{"non-object annotations", `{"type":"text","value":1,"annotations":[]}`, "annotations"},
		{"non-string tag", `{"type":"element","tag":1,"attributes":[],"value":null,"children":[],"annotations":{}}`, "tag"},
		{"non-array attributes", `{"type":"element","tag":"p","attributes":{},"value":null,"children":[],"annotations":{}}`, "attributes"},
		{"non-array children", `{"type":"element","tag":"p","attributes":[],"value":null,"children":{},"annotations":{}}`, "children"},
		{"element with no value slot", `{"type":"element","tag":"p","attributes":[],"children":[],"annotations":{}}`, "value"},
		{"fragment with no children", `{"type":"fragment","annotations":{}}`, "children"},
		{"attribute with no kind", `{"type":"element","tag":"p","attributes":[{"name":"a","value":1}],"value":null,"children":[],"annotations":{}}`, "kind"},
		{"unknown attribute kind", `{"type":"element","tag":"p","attributes":[{"kind":"prop","name":"a","value":1}],"value":null,"children":[],"annotations":{}}`, ""},
		{"attribute with no value", `{"type":"element","tag":"p","attributes":[{"kind":"attribute","name":"a"}],"value":null,"children":[],"annotations":{}}`, "value"},
		{"action with no payload", `{"type":"element","tag":"p","attributes":[{"kind":"action","event":"e","key":"k"}],"value":null,"children":[],"annotations":{}}`, "payload"},
		{"non-string action key", `{"type":"element","tag":"p","attributes":[{"kind":"action","event":"e","key":1,"payload":null}],"value":null,"children":[],"annotations":{}}`, "key"},
		{"not an object at all", `"text"`, ""},
	}
	for _, c := range cases {
		t.Run(c.label, func(t *testing.T) {
			_, err := NodeFromJSON(mustJSON(t, c.src))
			if err == nil {
				t.Fatal("decoded, but must be rejected")
			}
			if _, ok := err.(*NodeDecodeError); !ok {
				t.Fatalf("error is %T, not *NodeDecodeError", err)
			}
			if !strings.Contains(err.Error(), c.mentions) {
				t.Fatalf("error %q does not mention %q", err, c.mentions)
			}
		})
	}
}
