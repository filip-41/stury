package xml

// XML's edit services. The format commits its edits itself, through `compose.markup_commit`, with the edits and
// refusals every markup format shares, over the elements XML spells, and the result is read again, so an edit that
// breaks a rule of XML is `.Bad_Result`.

import "base:runtime"
import "core:slice"
import "core:strings"
import core "../core"
import compose "../core/compose"
import engine "../core/build"
import typed "../core/typed"
import write "../core/write"

// XML's edit services, the same table for every spec.
@(private, rodata)
EDIT := core.Edit_Services {
	value    = edit_value,
	key_text = compose.markup_key_text,
	validate = proc "contextless" (src: []u8, as: core.As) -> Maybe(core.Fault) {return validate_spec(src, .Xml, options_of(as))},
	spell    = edit_spell,
	relocate = edit_relocate,
	frozen   = frozen,
	commit   = edit_commit,
}

// Returns an edit list over `doc`. A document read as a constant spec holds no edit services, so the list takes XML's.
edit_list_init :: proc(doc: ^core.Document, spec: Spec, allocator := context.allocator) -> core.Edit_List {
	list := core.edit_list_init(doc, allocator)
	list.edit = &EDIT
	return list
}

// Makes `v` the value at every answer of `path` over `src`, in one call, and returns the new text, which the caller frees
// with `allocator`, keeping every byte the edit does not reach. A `typed.Raw` is an element's content as XML, a struct, a
// slice or a map is built by `plan`, and any other value is written as an element's content. A `Name` the path ends in
// that its element lacks is inserted as its last child.
set :: proc(src: []u8, spec: Spec, path: core.Path, v: any, plan: ^typed.Plan = nil, opts := Options{}, read := core.Query_Options{}, allocator := context.allocator) -> (out: []u8, err: core.Error) {
	scratch: write.Scratch
	defer write.scratch_destroy(&scratch)
	in_ := write.edit_input(v, plan, &scratch) or_return
	doc, berr := build(src, spec, opts, read.dups, allocator)
	defer core.destroy(&doc)
	if berr != nil {
		return nil, berr
	}
	list := edit_list_init(&doc, spec, allocator)
	defer core.edit_list_destroy(&list)
	return engine.set_answers(&list, path, in_, read, allocator)
}

// Checks `src` as an element's content.
@(private)
edit_value :: proc(v: ^core.Token_View, src: []u8, allocator: runtime.Allocator) -> core.Document_Error {
	wrapped := strings.concatenate({"<r>", string(src), "</r>"}, allocator)
	defer delete(wrapped, allocator)
	if fault, bad := validate_spec(transmute([]u8)wrapped, .Xml, options_of(v.as)).?; bad {
		fault.at -= min(fault.at, 3)
		return {kind = .Bad_Value, inner = fault}
	}
	return {}
}

// A value an edit writes, spelled as an element's content by the element write: null as none, a scalar as its escaped
// text, an object as its members' elements and its `#text` as text among them, and an array as `ITEM` before each
// item's content.
@(private)
edit_spell :: proc(_: ^core.Document, v: core.Value, opts: core.Write_Options, _: string, _: bool, _: u64, allocator: runtime.Allocator) -> ([]u8, core.Error) {
	spill: [write.ROOM_MAX]u8 = ---
	w := Writer{opts = opts}
	write.init(&w.out, &spill, allocator)
	kind := put_content(&w, v, true)
	text, err := write.finish(&w.out, {kind = kind})
	return text, core.error_of(err)
}

@(private = "file")
put_content :: proc(w: ^Writer, value: core.Value, top: bool) -> core.Typed_Error_Kind {
	v := core.plain(value)
	#partial switch core.value_kind(v) {
	case .Null:
		return .None
	case .Array:
		if !top {
			return .Unwritable
		}
		n := 0
		it := core.value_children(v)
		for item in core.value_child_next(&it) {
			write.put_byte(&w.out, compose.MARKUP_ITEM[0])
			put_content(w, item, false) or_return
			n += 1
		}
		return .None if n > 0 else .Unwritable
	case .Object:
		// The element whose content this is stands open around the members.
		e: Elements
		elements_init(&e, &w.out, w.opts)
		defer delete(e.names)
		e.levels[0], e.levels[1], e.top = {kind = .Root}, {kind = .Object}, 2
		put_members(w, &e, v) or_return
		return .None if e.levels[1].count > 0 else .Unwritable
	}
	return put_text(&w.out, write.value_scalar_text(v, w.buf[:], write.MARKUP_TREE) or_return, false, w.opts.ascii)
}

// The content node `node` holds, as `edit_spell` writes a value: an element's between its tags, and the root element
// for the document.
@(private)
edit_relocate :: proc(doc: ^core.Document, node: core.Node_Index, _: core.Site, allocator: runtime.Allocator) -> ([]u8, bool) {
	lo, hi := compose.markup_content(doc, &MARKUP, node)
	return slice.clone(doc.src[lo:hi], allocator), true
}

// What the markup edits read from XML.
@(private, rodata)
MARKUP := compose.Markup {
	element = element_of,
	is_name = is_name,
	fact = proc(role: core.Role, body: string) -> bool {return role == .Attribute || !strings.contains(body, "--") && !strings.has_suffix(body, "-")},
	self_closing = true,
	rules = rules_of,
	refusals = {
		.Reordered = u8(Detail.Reordered),
		.Not_Name = u8(Detail.Not_Name),
		.Text_Markup = u8(Detail.Text_Markup),
		.Nested_Array = u8(Detail.Nested_Array),
		.Comment_Body = u8(Detail.Comment_Body),
		.No_Place = u8(Detail.No_Place),
		.Attribute_Body = u8(Detail.No_Place),
		.Void = u8(Detail.No_Place),
	},
}

// The element of value `v`, or the root element for the document. A tag holds no `<`, not even in an attribute's value,
// so the start of a scalar's element is the last `<` before its content.
@(private = "file")
element_of :: proc(doc: ^core.Document, v: core.Node_Index) -> (e: compose.Markup_Element) {
	if v == core.ROOT {
		return element_of(doc, core.ROOT + 2)
	}
	src := doc.src
	n := doc.nodes[v]
	if n.kind == .Object {
		e.lo, e.hi = n.lo, close_end(doc, v)
		quote: u8
		for e.open = e.lo + 1; quote != 0 || src[e.open] != '>'; e.open += 1 {
			if quote == 0 && (src[e.open] == '"' || src[e.open] == '\'') {
				quote = src[e.open]
			} else if src[e.open] == quote {
				quote = 0
			}
		}
		e.open += 1
		for e.close = e.hi - 1; src[e.close] != '<'; e.close -= 1 {}
	} else {
		for e.lo = n.lo - 1; src[e.lo] != '<'; e.lo -= 1 {}
		e.empty = n.n == 0 && src[n.lo] == '/'
		e.open, e.close = n.lo, n.lo + u64(n.n)
		e.hi = n.lo + 2 if e.empty else end_tag_end(src, e.close)
	}
	e.end_tag = !e.empty
	for e.name = e.lo + 1; !is_ws(src[e.name]) && src[e.name] != '>' && src[e.name] != '/'; e.name += 1 {}
	return e
}

// XML's commit: each edit as splices of the source, which the walk then reads.
@(private)
edit_commit :: proc(list: ^core.Edit_List, spec: u8, allocator: runtime.Allocator) -> (out: []u8, dropped: int, err: core.Document_Error) {
	out, err = compose.markup_commit(list, &MARKUP, allocator)
	if err.kind != .None {
		return nil, 0, err
	}
	if fault, bad := validate_spec(out, .Xml, options_of(list.doc.as)).?; bad {
		delete(out, allocator)
		return nil, 0, {kind = .Bad_Result, inner = fault}
	}
	return out, 0, {}
}
