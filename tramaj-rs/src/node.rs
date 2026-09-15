//! `Node`/`NodeAttribute` and the strict `specs/node-json.md` encode/decode
//! (hand-written, not derived, so the "decoder MUST reject ... MUST NOT
//! infer a missing field from a default" rules are enforced exactly).
//! Mirrors `tramaj-hs/src/Tramaj/Node.hs`.

use std::collections::BTreeMap;

use serde_json::{Map as JsonMap, Value as Json};

pub type Annotations = BTreeMap<String, Json>;

pub fn no_annotations() -> Annotations {
    BTreeMap::new()
}

#[derive(Debug, Clone, PartialEq)]
pub enum Node {
    Text(Json, Annotations),
    Element(String, Vec<NodeAttribute>, Json, Vec<Node>, Annotations),
    Fragment(Vec<Node>, Annotations),
}

#[derive(Debug, Clone, PartialEq)]
pub enum NodeAttribute {
    Attribute(String, Json),
    Action(String, String, Json),
}

fn annotations_to_json(anns: &Annotations) -> Json {
    let mut m = JsonMap::new();
    for (k, v) in anns {
        m.insert(k.clone(), v.clone());
    }
    Json::Object(m)
}

pub fn node_to_json(n: &Node) -> Json {
    match n {
        Node::Text(v, anns) => {
            let mut m = JsonMap::new();
            m.insert("type".to_string(), Json::String("text".to_string()));
            m.insert("value".to_string(), v.clone());
            m.insert("annotations".to_string(), annotations_to_json(anns));
            Json::Object(m)
        }
        Node::Element(tag, attrs, val, children, anns) => {
            let mut m = JsonMap::new();
            m.insert("type".to_string(), Json::String("element".to_string()));
            m.insert("tag".to_string(), Json::String(tag.clone()));
            m.insert(
                "attributes".to_string(),
                Json::Array(attrs.iter().map(node_attribute_to_json).collect()),
            );
            m.insert("value".to_string(), val.clone());
            m.insert(
                "children".to_string(),
                Json::Array(children.iter().map(node_to_json).collect()),
            );
            m.insert("annotations".to_string(), annotations_to_json(anns));
            Json::Object(m)
        }
        Node::Fragment(children, anns) => {
            let mut m = JsonMap::new();
            m.insert("type".to_string(), Json::String("fragment".to_string()));
            m.insert(
                "children".to_string(),
                Json::Array(children.iter().map(node_to_json).collect()),
            );
            m.insert("annotations".to_string(), annotations_to_json(anns));
            Json::Object(m)
        }
    }
}

pub fn node_attribute_to_json(a: &NodeAttribute) -> Json {
    match a {
        NodeAttribute::Attribute(name, val) => {
            let mut m = JsonMap::new();
            m.insert("kind".to_string(), Json::String("attribute".to_string()));
            m.insert("name".to_string(), Json::String(name.clone()));
            m.insert("value".to_string(), val.clone());
            Json::Object(m)
        }
        NodeAttribute::Action(event, key, payload) => {
            let mut m = JsonMap::new();
            m.insert("kind".to_string(), Json::String("action".to_string()));
            m.insert("event".to_string(), Json::String(event.clone()));
            m.insert("key".to_string(), Json::String(key.clone()));
            m.insert("payload".to_string(), payload.clone());
            Json::Object(m)
        }
    }
}

fn req<'a>(what: &str, field: &str, obj: &'a JsonMap<String, Json>) -> Result<&'a Json, String> {
    obj.get(field)
        .ok_or_else(|| format!("{what}: missing required field {field:?}"))
}

fn req_string(what: &str, field: &str, obj: &JsonMap<String, Json>) -> Result<String, String> {
    match req(what, field, obj)? {
        Json::String(s) => Ok(s.clone()),
        _ => Err(format!("{what}: field {field:?} must be a string")),
    }
}

fn req_array<'a>(
    what: &str,
    field: &str,
    obj: &'a JsonMap<String, Json>,
) -> Result<&'a Vec<Json>, String> {
    match req(what, field, obj)? {
        Json::Array(a) => Ok(a),
        _ => Err(format!("{what}: field {field:?} must be an array")),
    }
}

fn req_annotations(obj: &JsonMap<String, Json>) -> Result<Annotations, String> {
    match req("node", "annotations", obj)? {
        Json::Object(m) => Ok(m.iter().map(|(k, v)| (k.clone(), v.clone())).collect()),
        _ => Err("node: field \"annotations\" must be an object".to_string()),
    }
}

pub fn node_from_json(v: &Json) -> Result<Node, String> {
    let obj = match v {
        Json::Object(m) => m,
        _ => return Err("expected a JSON object for a node".to_string()),
    };
    let ty = req_string("node", "type", obj)?;
    match ty.as_str() {
        "text" => {
            let value = req("text node", "value", obj)?.clone();
            let anns = req_annotations(obj)?;
            Ok(Node::Text(value, anns))
        }
        "element" => {
            let tag = req_string("element node", "tag", obj)?;
            let attrs = req_array("element node", "attributes", obj)?
                .iter()
                .map(node_attribute_from_json)
                .collect::<Result<Vec<_>, _>>()?;
            let val = req("element node", "value", obj)?.clone();
            let children = req_array("element node", "children", obj)?
                .iter()
                .map(node_from_json)
                .collect::<Result<Vec<_>, _>>()?;
            let anns = req_annotations(obj)?;
            Ok(Node::Element(tag, attrs, val, children, anns))
        }
        "fragment" => {
            let children = req_array("fragment node", "children", obj)?
                .iter()
                .map(node_from_json)
                .collect::<Result<Vec<_>, _>>()?;
            let anns = req_annotations(obj)?;
            Ok(Node::Fragment(children, anns))
        }
        other => Err(format!("unknown node type: {other:?}")),
    }
}

pub fn node_attribute_from_json(v: &Json) -> Result<NodeAttribute, String> {
    let obj = match v {
        Json::Object(m) => m,
        _ => return Err("expected a JSON object for a node attribute".to_string()),
    };
    let kind = req_string("node attribute", "kind", obj)?;
    match kind.as_str() {
        "attribute" => {
            let name = req_string("attribute", "name", obj)?;
            let value = req("attribute", "value", obj)?.clone();
            Ok(NodeAttribute::Attribute(name, value))
        }
        "action" => {
            let event = req_string("action", "event", obj)?;
            let key = req_string("action", "key", obj)?;
            let payload = req("action", "payload", obj)?.clone();
            Ok(NodeAttribute::Action(event, key, payload))
        }
        other => Err(format!("unknown node attribute kind: {other:?}")),
    }
}

/// Rewrites every action reachable in a tree, leaving everything else
/// untouched. Mirrors `Node.hs`'s `mapActions`.
pub fn map_actions<E>(
    n: &Node,
    f: &mut impl FnMut(&str, &str, &Json) -> Result<NodeAttribute, E>,
) -> Result<Node, E> {
    match n {
        Node::Text(v, anns) => Ok(Node::Text(v.clone(), anns.clone())),
        Node::Element(tag, attrs, val, children, anns) => {
            let attrs2 = attrs
                .iter()
                .map(|a| match a {
                    NodeAttribute::Attribute(_, _) => Ok(a.clone()),
                    NodeAttribute::Action(event, key, payload) => f(event, key, payload),
                })
                .collect::<Result<Vec<_>, E>>()?;
            let children2 = children
                .iter()
                .map(|c| map_actions(c, f))
                .collect::<Result<Vec<_>, E>>()?;
            Ok(Node::Element(
                tag.clone(),
                attrs2,
                val.clone(),
                children2,
                anns.clone(),
            ))
        }
        Node::Fragment(children, anns) => {
            let children2 = children
                .iter()
                .map(|c| map_actions(c, f))
                .collect::<Result<Vec<_>, E>>()?;
            Ok(Node::Fragment(children2, anns.clone()))
        }
    }
}
