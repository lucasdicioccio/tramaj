package tramaj

import "fmt"

// Node/NodeAttribute and the strict specs/node-json.md encode/decode,
// hand-written so the "a decoder MUST reject ... MUST NOT infer a missing
// field from a default" rules are enforced exactly.

type NodeType string

const (
	TextNode     NodeType = "text"
	ElementNode  NodeType = "element"
	FragmentNode NodeType = "fragment"
)

// Node is a document node. Which fields are meaningful depends on Type: a
// text node has Value; an element has Tag, Attributes, Value and Children; a
// fragment has Children. Every node has Annotations (nil reads as empty).
type Node struct {
	Type        NodeType
	Tag         string
	Attributes  []NodeAttribute
	Value       JSON
	Children    []*Node
	Annotations *Object
}

type AttributeKind string

const (
	PlainAttribute  AttributeKind = "attribute"
	ActionAttribute AttributeKind = "action"
)

// NodeAttribute is a plain attribute (Name, Value) or an action (Event, Key,
// Payload), told apart by Kind.
type NodeAttribute struct {
	Kind    AttributeKind
	Name    string
	Value   JSON
	Event   string
	Key     string
	Payload JSON
}

func annotationsJSON(a *Object) JSON {
	if a == nil {
		return NewObject()
	}
	return a
}

func nodesJSON(ns []*Node) JSON {
	out := make([]JSON, len(ns))
	for i, c := range ns {
		out[i] = NodeToJSON(c)
	}
	return out
}

// NodeToJSON encodes a node in specs/node-json.md form.
func NodeToJSON(n *Node) JSON {
	switch n.Type {
	case TextNode:
		return NewObject("type", "text", "value", n.Value, "annotations", annotationsJSON(n.Annotations))
	case ElementNode:
		attrs := make([]JSON, len(n.Attributes))
		for i, a := range n.Attributes {
			attrs[i] = NodeAttributeToJSON(a)
		}
		return NewObject(
			"type", "element",
			"tag", n.Tag,
			"attributes", attrs,
			"value", n.Value,
			"children", nodesJSON(n.Children),
			"annotations", annotationsJSON(n.Annotations),
		)
	}
	return NewObject("type", "fragment", "children", nodesJSON(n.Children), "annotations", annotationsJSON(n.Annotations))
}

func NodeAttributeToJSON(a NodeAttribute) JSON {
	if a.Kind == ActionAttribute {
		return NewObject("kind", "action", "event", a.Event, "key", a.Key, "payload", a.Payload)
	}
	return NewObject("kind", "attribute", "name", a.Name, "value", a.Value)
}

// NodeDecodeError is what NodeFromJSON and NodeAttributeFromJSON return.
type NodeDecodeError struct{ Msg string }

func (e *NodeDecodeError) Error() string { return e.Msg }

func decodeErr(format string, args ...any) error {
	return &NodeDecodeError{Msg: fmt.Sprintf(format, args...)}
}

func req(what, field string, obj *Object) (JSON, error) {
	v, ok := obj.Get(field)
	if !ok {
		return nil, decodeErr("%s: missing required field %q", what, field)
	}
	return v, nil
}

func reqString(what, field string, obj *Object) (string, error) {
	v, err := req(what, field, obj)
	if err != nil {
		return "", err
	}
	s, ok := v.(string)
	if !ok {
		return "", decodeErr("%s: field %q must be a string", what, field)
	}
	return s, nil
}

func reqArray(what, field string, obj *Object) ([]JSON, error) {
	v, err := req(what, field, obj)
	if err != nil {
		return nil, err
	}
	a, ok := v.([]JSON)
	if !ok {
		return nil, decodeErr("%s: field %q must be an array", what, field)
	}
	return a, nil
}

func reqAnnotations(obj *Object) (*Object, error) {
	v, err := req("node", "annotations", obj)
	if err != nil {
		return nil, err
	}
	a, ok := v.(*Object)
	if !ok {
		return nil, decodeErr(`node: field "annotations" must be an object`)
	}
	return a, nil
}

func reqChildren(what string, obj *Object) ([]*Node, error) {
	raw, err := reqArray(what, "children", obj)
	if err != nil {
		return nil, err
	}
	out := make([]*Node, len(raw))
	for i, c := range raw {
		if out[i], err = NodeFromJSON(c); err != nil {
			return nil, err
		}
	}
	return out, nil
}

// NodeFromJSON decodes specs/node-json.md form, rejecting anything the spec
// says a decoder must reject.
func NodeFromJSON(v JSON) (*Node, error) {
	obj, ok := v.(*Object)
	if !ok {
		return nil, decodeErr("expected a JSON object for a node")
	}
	typ, err := reqString("node", "type", obj)
	if err != nil {
		return nil, err
	}
	n := &Node{Type: NodeType(typ)}
	switch n.Type {
	case TextNode:
		if n.Value, err = req("text node", "value", obj); err != nil {
			return nil, err
		}
	case ElementNode:
		if n.Tag, err = reqString("element node", "tag", obj); err != nil {
			return nil, err
		}
		attrs, err := reqArray("element node", "attributes", obj)
		if err != nil {
			return nil, err
		}
		n.Attributes = make([]NodeAttribute, len(attrs))
		for i, a := range attrs {
			if n.Attributes[i], err = NodeAttributeFromJSON(a); err != nil {
				return nil, err
			}
		}
		if n.Value, err = req("element node", "value", obj); err != nil {
			return nil, err
		}
		if n.Children, err = reqChildren("element node", obj); err != nil {
			return nil, err
		}
	case FragmentNode:
		if n.Children, err = reqChildren("fragment node", obj); err != nil {
			return nil, err
		}
	default:
		return nil, decodeErr("unknown node type: %q", typ)
	}
	if n.Annotations, err = reqAnnotations(obj); err != nil {
		return nil, err
	}
	return n, nil
}

func NodeAttributeFromJSON(v JSON) (NodeAttribute, error) {
	var a NodeAttribute
	obj, ok := v.(*Object)
	if !ok {
		return a, decodeErr("expected a JSON object for a node attribute")
	}
	kind, err := reqString("node attribute", "kind", obj)
	if err != nil {
		return a, err
	}
	a.Kind = AttributeKind(kind)
	switch a.Kind {
	case PlainAttribute:
		if a.Name, err = reqString("attribute", "name", obj); err != nil {
			return a, err
		}
		a.Value, err = req("attribute", "value", obj)
	case ActionAttribute:
		if a.Event, err = reqString("action", "event", obj); err != nil {
			return a, err
		}
		if a.Key, err = reqString("action", "key", obj); err != nil {
			return a, err
		}
		a.Payload, err = req("action", "payload", obj)
	default:
		err = decodeErr("unknown node attribute kind: %q", kind)
	}
	return a, err
}

// mapActions rewrites every action reachable in a tree, leaving everything
// else untouched.
func mapActions(n *Node, f func(NodeAttribute) NodeAttribute) *Node {
	if n.Type == TextNode {
		return n
	}
	out := *n
	if n.Type == ElementNode {
		out.Attributes = make([]NodeAttribute, len(n.Attributes))
		for i, a := range n.Attributes {
			if a.Kind == ActionAttribute {
				a = f(a)
			}
			out.Attributes[i] = a
		}
	}
	out.Children = make([]*Node, len(n.Children))
	for i, c := range n.Children {
		out.Children[i] = mapActions(c, f)
	}
	return &out
}
