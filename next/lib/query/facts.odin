package query

import "core:fmt"
import "stury:lib/core/markup"
import "stury:lib/core/tape"

// Fact reading and path-step helpers: `.@comment`, `.@tag`, `.@anchor`, `.@alias`, `.@style`,
// `.@name`, `.@namespace`, `.@content`, `.@pi`, `.@doctype`, `.@directives`, `.@attrs`, and `.&attr`.
// In a path, a fact step is `{"fact": "<name>"}` or `{"fact": "attribute", "name": "<attr>"}` and must be last.

Fact_Class :: enum u8 {
	Comment,
	Property,
	Markup,
}

Fact_Info :: struct {
	name:      string,
	kind:      tape.Fact_Kind,
	read_only: bool,
	class:     Fact_Class,
}

// Ordered to match v1's error message listing.
@(rodata)
FACT_CATALOG := [?]Fact_Info {
	{"comment",        .Comment,        false, .Comment},
	{"comment_inline", .Comment_Inline, false, .Comment},
	{"comment_foot",   .Comment_Foot,   false, .Comment},
	{"tag",            .Tag,            false, .Property},
	{"anchor",         .Anchor,         false, .Property},
	{"alias",          .Alias,          false, .Property},
	{"style",          .Style,          false, .Property},
	{"name",           .Name,           true,  .Property},
	{"namespace",      .Namespace,      true,  .Property},
	{"content",        .Content,        true,  .Property},
	{"pi",             .Instruction,    true,  .Markup},
	{"doctype",        .Doctype,        true,  .Markup},
	{"directives",     .Directive,      true,  .Markup},
	{"attrs",          .Attribute,      false, .Markup},
}

FACT_LIST :: "comment, comment_inline, comment_foot, tag, anchor, alias, style, name, namespace, content, pi, doctype, directives, attrs, comment_head"

// Looks up `.@name` (without `@`) in the fact catalogue, including the `comment_head` alias.
fact_named :: proc "contextless" (name: string) -> (tape.Fact_Kind, bool) {
	for info in FACT_CATALOG {
		if info.name == name {
			return info.kind, true
		}
	}
	if name == "comment_head" {
		return .Comment, true
	}
	return .Comment, false
}

// Catalogue info for `kind`.
fact_info :: proc "contextless" (kind: tape.Fact_Kind) -> (Fact_Info, bool) {
	for info in FACT_CATALOG {
		if info.kind == kind {
			return info, true
		}
	}
	return {}, false
}

// Canonical path-step name for `kind`.
fact_step_name :: proc "contextless" (kind: tape.Fact_Kind) -> string {
	if info, ok := fact_info(kind); ok {
		return info.name
	}
	return ""
}

// Builds the path step `{"fact": "<name>"}` for `kind`.
@(require_results)
fact_key :: proc(h: ^Heap, kind: tape.Fact_Kind) -> (res: Value, status: Status) {
	o := make_object(h, 1) or_return
	if s := object_put_fresh(h, &o, text_borrowed("fact"), text_borrowed(fact_step_name(kind))); s != .Ok {
		release(h, o)
		return NULL, s
	}
	return o, .Ok
}

// Builds the path step `{"fact": "attribute", "name": "<attr>"}` for `.&attr`.
@(require_results)
attribute_key :: proc(h: ^Heap, attr: string) -> (res: Value, status: Status) {
	o := make_object(h, 2) or_return
	defer if status != .Ok {
		release(h, o)
	}
	object_put_fresh(h, &o, text_borrowed("fact"), text_borrowed("attribute")) or_return
	name := text_value(h, attr) or_return
	object_put_fresh(h, &o, text_borrowed("name"), name) or_return
	return o, .Ok
}

// Whether `key` is a known fact path step (`{"fact": "<name>"}` or `{"fact": "attribute", "name": "<attr>"}`).
fact_step :: proc(h: ^Heap, key: Value) -> (kind: tape.Fact_Kind, is_attr: bool, ok: bool) {
	if type_of(key) != .Object {
		return
	}
	n := length_of(h, key)
	if n < 1 || n > 2 {
		return
	}
	fv, fs := member(h, key, "fact")
	if fs != .Ok || !is_text(fv) {
		release(h, fv)
		return
	}
	defer release(h, fv)
	fname := text_of(fv)
	if n == 2 {
		if fname != "attribute" {
			return
		}
		nv, ns := member(h, key, "name")
		if ns != .Ok || !is_text(nv) {
			release(h, nv)
			return
		}
		release(h, nv)
		return .Attribute, true, true
	}
	for info in FACT_CATALOG {
		if info.name == fname {
			return info.kind, false, true
		}
	}
	return
}

// Reads the `"name"` field of an attribute fact step `key` (whose `fact_step` returned `is_attr = true`).
// The returned string value is owned by the caller.
@(require_results)
fact_step_attr :: proc(h: ^Heap, key: Value) -> (res: Value, status: Status) {
	return member(h, key, "name")
}

// Whether `key` is a 1-entry object `{"fact": "<unknown>"}` naming an unknown fact.
// Returns the owned string value for the unknown name.
unknown_fact_step :: proc(h: ^Heap, key: Value) -> (name: Value, unknown: bool) {
	if type_of(key) != .Object || length_of(h, key) != 1 {
		return ABSENT, false
	}
	fv, fs := member(h, key, "fact")
	if fs != .Ok || !is_text(fv) {
		release(h, fv)
		return ABSENT, false
	}
	fname := text_of(fv)
	for info in FACT_CATALOG {
		if info.name == fname {
			release(h, fv)
			return ABSENT, false
		}
	}
	return fv, true
}

// Raises `unknown fact .@<name>, the facts are ...` on `h`.
fail_unknown_fact :: proc(h: ^Heap, name: string) -> Status {
	msg := fmt.aprintf("unknown fact .@%s, the facts are %s", name, FACT_LIST, allocator = h.allocator)
	defer delete(msg, h.allocator)
	v, s := text_value(h, msg)
	if s != .Ok {
		return s
	}
	st := fail(h, .Raised, .None, v)
	release(h, v)
	return st
}

// Raises a plain raised-string error on `h`.
fail_fact_msg :: proc(h: ^Heap, msg: string) -> Status {
	v, s := text_value(h, msg)
	if s != .Ok {
		return s
	}
	st := fail(h, .Raised, .None, v)
	release(h, v)
	return st
}

// Validates that no fact step in `keys` is unknown or appears before the last step.
validate_path_facts :: proc(h: ^Heap, keys: []Value) -> Status {
	for k, i in keys {
		if _, _, is_fact := fact_step(h, k); is_fact {
			if i + 1 < len(keys) {
				return fail_fact_msg(h, "A comment step must be the last step of a path")
			}
			continue
		}
		if unk, is_unk := unknown_fact_step(h, k); is_unk {
			defer release(h, unk)
			return fail_unknown_fact(h, text_of(unk))
		}
	}
	return .Ok
}

// Reads fact `kind` (or attribute `attr` when `is_attr`) on `v`.
// Sets `h.tainted = true` if `v` belongs to a partial document scanned without facts (`!Partial.facts`).
@(require_results)
fact_read :: proc(h: ^Heap, v: Value, kind: tape.Fact_Kind, attr := "", is_attr := false) -> (res: Value, status: Status) {
	d, at, from_doc := value_doc_origin(v, true)
	if !from_doc {
		return NULL, .Ok
	}
	doc := &d.doc
	if doc.partial != nil && !doc.partial.facts {
		h.tainted = true
		return NULL, .Ok
	}
	if is_attr {
		return read_attributes(h, d, at, attr, true)
	}
	#partial switch kind {
	case .Comment, .Comment_Inline, .Comment_Foot:
		return read_comments(h, doc, at, kind)
	case .Tag:
		return read_tag(h, doc, at)
	case .Anchor, .Alias:
		return read_span_fact(h, doc, at, kind)
	case .Style:
		if name, ok := tape.fact_name(doc, at, .Style); ok {
			return text_value(h, name)
		}
		return NULL, .Ok
	case .Instruction:
		return read_instructions(h, doc, at)
	case .Directive:
		return read_many_facts(h, doc, at, .Directive)
	case .Doctype:
		return read_span_fact(h, doc, at, .Doctype)
	case .Attribute:
		return read_attributes(h, d, at, "", false)
	case .Name:
		return read_element_name(h, d, at)
	case .Namespace:
		if doc.format == nil || doc.format.namespace == nil {
			return NULL, .Ok
		}
		uri, p := doc.format.namespace(doc, at)
		note_presence(h, p)
		if p != .Found {
			return NULL, .Ok
		}
		return text_value(h, uri)
	case .Content:
		return read_content(h, doc, at)
	}
	return NULL, .Ok
}

// Hook signature for Phase 2A (`Overlay`) to back fact writes on values.
Fact_Writer :: #type proc(data: rawptr, h: ^Heap, v: Value, kind: tape.Fact_Kind, attr: string, is_attr: bool, nv: Value) -> (res: Value, status: Status)

// Validates a fact write (`set_path` / `del_paths` on a fact step) and dispatches to `Heap.write_fact` when set.
@(require_results)
fact_write :: proc(h: ^Heap, v: Value, kind: tape.Fact_Kind, attr: string, is_attr: bool, nv: Value) -> (res: Value, status: Status) {
	info, ok := fact_info(kind)
	if !ok {
		release(h, v)
		release(h, nv)
		return NULL, fail_fact_msg(h, "unknown fact")
	}
	if is_attr {
		if t := type_of(nv); t != .String && t != .Null && t != .Absent {
			release(h, v)
			release(h, nv)
			return NULL, fail_fact_msg(h, "an attribute is a string or null")
		}
	} else if info.class == .Comment {
		if !valid_comment_value(h, nv) {
			release(h, v)
			release(h, nv)
			return NULL, fail_fact_msg(h, "a comment is a string, an array of strings, or null")
		}
	} else if info.read_only || info.class != .Property {
		release(h, v)
		release(h, nv)
		return NULL, fail_fact_msg(h, "A markup name, namespace, content, instruction, doctype or document marker cannot be written")
	} else {
		t := type_of(nv)
		if t != .String && t != .Null && t != .Absent && !(kind == .Tag && t == .Number) {
			release(h, v)
			release(h, nv)
			return NULL, fail_fact_msg(h, "a tag, an anchor, an alias or a style is a string or null, and a tag may be a number")
		}
	}
	if h.write_fact != nil {
		return h.write_fact(h.write_fact_data, h, v, kind, attr, is_attr, nv)
	}
	release(h, v)
	release(h, nv)
	return NULL, fail_fact_msg(h, "fact writes require an overlay")
}

@(private = "file")
valid_comment_value :: proc(h: ^Heap, v: Value) -> bool {
	#partial switch type_of(v) {
	case .Null, .Absent, .String:
		return true
	case .Array:
		c, s := cursor_open(h, v)
		if s != .Ok {
			return false
		}
		defer cursor_close(&c)
		for {
			_, elem, more, ns := cursor_next(h, &c)
			if ns != .Ok {
				return false
			}
			if !more {
				return true
			}
			ok := is_text(elem)
			release(h, elem)
			if !ok {
				return false
			}
		}
	}
	return false
}

@(private = "file")
fact_body :: #force_inline proc "contextless" (doc: ^tape.Document, f: tape.Fact) -> []u8 {
	raw := tape.span_bytes(doc, f.lo, f.n)
	lead := min(int(tape.fact_lead(f.spelling)), len(raw))
	tail := min(int(tape.fact_tail(f.spelling)), len(raw) - lead)
	return raw[lead : len(raw) - tail]
}

@(private = "file")
read_comments :: proc(h: ^Heap, doc: ^tape.Document, at: tape.Node_Index, kind: tape.Fact_Kind) -> (res: Value, status: Status) {
	if kind not_in doc.present {
		return NULL, .Ok
	}
	facts := tape.facts_of(doc, at)
	out := ABSENT
	defer if status != .Ok {
		release(h, out)
	}
	for f in facts {
		if f.kind != kind {
			continue
		}
		body := string(fact_body(doc, f))
		if tape.fact_lead(f.spelling) > 0 && len(body) > 0 && body[0] == ' ' {
			body = body[1:]
		}
		if tape.fact_tail(f.spelling) > 0 && len(body) > 0 && body[len(body) - 1] == ' ' {
			body = body[:len(body) - 1]
		}
		if out.kind == .Absent {
			out = make_array(h, 2) or_return
		}
		s := text_value(h, body) or_return
		append_owned(h, &out, s) or_return
	}
	return out if out.kind != .Absent else NULL, .Ok
}

@(private = "file")
read_tag :: proc(h: ^Heap, doc: ^tape.Document, at: tape.Node_Index) -> (res: Value, status: Status) {
	if .Tag in doc.present {
		for f in tape.facts_of(doc, at) {
			if f.kind != .Tag {
				continue
			}
			if doc.format != nil && .Binary in doc.format.caps {
				if num, ok := tape.fact_number(doc, f); ok {
					#partial switch num.kind {
					case .Int:
						return int_value(i64(num.bits)), .Ok
					case .Uint:
						if num.bits <= u64(max(i64)) {
							return int_value(i64(num.bits)), .Ok
						}
						return big_from_u64(h, num.bits)
					case .Float:
						return double_value(transmute(f64)num.bits), .Ok
					}
				}
			}
			return text_value(h, string(fact_body(doc, f)))
		}
	}
	if name, ok := tape.fact_name(doc, at, .Tag); ok {
		return text_value(h, name)
	}
	return NULL, .Ok
}

@(private = "file")
read_span_fact :: proc(h: ^Heap, doc: ^tape.Document, at: tape.Node_Index, kind: tape.Fact_Kind) -> (res: Value, status: Status) {
	if kind not_in doc.present {
		return NULL, .Ok
	}
	for f in tape.facts_of(doc, at) {
		if f.kind == kind {
			return text_value(h, string(fact_body(doc, f)))
		}
	}
	return NULL, .Ok
}

// Processing instructions (`.@pi`) include both `.Instruction` and `.Instruction_Foot`.
@(private = "file")
read_instructions :: proc(h: ^Heap, doc: ^tape.Document, at: tape.Node_Index) -> (res: Value, status: Status) {
	if .Instruction not_in doc.present && .Instruction_Foot not_in doc.present {
		return NULL, .Ok
	}
	out := ABSENT
	defer if status != .Ok {
		release(h, out)
	}
	for f in tape.facts_of(doc, at) {
		if f.kind != .Instruction && f.kind != .Instruction_Foot {
			continue
		}
		if out.kind == .Absent {
			out = make_array(h, 2) or_return
		}
		s := text_value(h, string(fact_body(doc, f))) or_return
		append_owned(h, &out, s) or_return
	}
	return out if out.kind != .Absent else NULL, .Ok
}

@(private = "file")
read_many_facts :: proc(h: ^Heap, doc: ^tape.Document, at: tape.Node_Index, kind: tape.Fact_Kind) -> (res: Value, status: Status) {
	if kind not_in doc.present {
		return NULL, .Ok
	}
	out := ABSENT
	defer if status != .Ok {
		release(h, out)
	}
	for f in tape.facts_of(doc, at) {
		if f.kind != kind {
			continue
		}
		if out.kind == .Absent {
			out = make_array(h, 2) or_return
		}
		s := text_value(h, string(fact_body(doc, f))) or_return
		append_owned(h, &out, s) or_return
	}
	return out if out.kind != .Absent else NULL, .Ok
}

@(private = "file")
read_attributes :: proc(h: ^Heap, d: ^Doc_Block, at: tape.Node_Index, name: string, one: bool) -> (res: Value, status: Status) {
	doc := &d.doc
	if doc.format == nil || doc.format.attribute == nil || .Attribute not_in doc.present {
		return NULL, .Ok
	}
	out := ABSENT
	defer if status != .Ok {
		release(h, out)
	}
	for f in tape.facts_of(doc, at) {
		if f.kind != .Attribute {
			continue
		}
		kt, vt := doc.format.attribute(doc, f)
		kstr := string(tape.span_bytes(doc, kt.lo, kt.n))
		if one && kstr != name {
			continue
		}
		val := token_text_value(h, d, vt) or_return
		if one {
			return val, .Ok
		}
		if out.kind == .Absent {
			out = make_object(h, 4) or_return
		}
		kv, ks := text_value(h, kstr)
		if ks != .Ok {
			release(h, val)
			return NULL, ks
		}
		object_put(h, &out, kv, val) or_return
	}
	return out if out.kind != .Absent else NULL, .Ok
}

@(private = "file")
read_element_name :: proc(h: ^Heap, d: ^Doc_Block, at: tape.Node_Index) -> (res: Value, status: Status) {
	doc := &d.doc
	if doc.format == nil || doc.format.attribute == nil || at == tape.ROOT {
		return NULL, .Ok
	}
	prev := doc.nodes[at - 1]
	if prev.role != .Key || markup.is_text_key(prev) {
		return NULL, .Ok
	}
	return key_value(h, d, at - 1)
}

@(private = "file")
read_content :: proc(h: ^Heap, doc: ^tape.Document, at: tape.Node_Index) -> (res: Value, status: Status) {
	if doc.format == nil || doc.format.attribute == nil {
		return NULL, .Ok
	}
	if doc.partial != nil && node_has_partial(doc, at) {
		h.tainted = true
		return NULL, .Ok
	}
	text, ok := markup.content(doc, at, heap_allocator(h))
	if !ok {
		return NULL, fail_memory(h)
	}
	defer delete(text, heap_allocator(h))
	return text_value(h, text)
}
