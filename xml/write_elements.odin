package xml

// The element write, which every write of a value that is no XML document takes: the token write, `marshal` and the
// write of another format's document. It writes compact XML as the value arrives and refuses what XML cannot spell so
// that it reads back, as `write` says. Pretty text is laid out from the compact text, read back as a document and
// written from its spans, since whether an element holds text is known only at its close.

import "base:runtime"
import "core:io"
import core "../core"
import write "../core/write"

// An element write's state: the names of the open elements and of the member waiting for its value, end to end in
// `names`.
@(private)
Elements :: struct {
	out:      ^write.Out,
	ascii:    bool,
	names:    [dynamic]u8,
	levels:   [core.MAX_DEPTH + 1]Level,
	top:      int,
	at:       int, // where the waiting member's name starts in `names`
	keyed:    bool, // a member waits for its value
	text:     bool, // the waiting member is `#text`
	tag:      bool, // the start tag of the next element is written and open for attributes
	key_next: bool, // the token write's next string is a key
}

// An open level: the document's object, an element's object, the array whose items are elements of its name, or the
// array under `#text` whose items are text runs. `count` is the root members, the child elements or the items it holds.
@(private)
Level :: struct {
	kind:   enum u8 {Root, Object, Array, Text},
	lo, hi: int, // the element's name in `names`
	count:  int,
}

// Opens the document's object, an element's object, an array of elements of the waiting member's name, or an array of
// the runs of the waiting `#text`.
@(private)
el_open :: proc(e: ^Elements, object: bool) -> core.Typed_Error_Kind {
	if e.top == 0 {
		e.levels[0] = {kind = .Root}
		e.top = 1
		return .None if object else .Unsupported
	}
	up := &e.levels[e.top - 1]
	if e.text && !object && up.kind != .Text {
		e.levels[e.top] = {kind = .Text}
		e.top += 1
		return .None
	}
	if e.text || !object && (up.kind != .Object || !e.keyed) {
		return .Unwritable
	}
	lo, hi := e.at, len(e.names)
	if up.kind == .Array {
		lo, hi = up.lo, up.hi
	}
	if object {
		el_start(e) or_return
		write.put_byte(e.out, '>')
	}
	e.levels[e.top] = {kind = .Object if object else .Array, lo = lo, hi = hi}
	e.top += 1
	e.keyed, e.tag = false, false
	return .None
}

// Closes the innermost level. An object with no element, an array with no item and a document with no root are
// `.Unwritable`.
@(private)
el_close :: proc(e: ^Elements) -> core.Typed_Error_Kind {
	e.top -= 1
	l := e.levels[e.top]
	if l.count == 0 {
		return .Unwritable
	}
	if l.kind == .Text {
		e.text = false
		return .None
	}
	if l.kind == .Object {
		put_close(e.out, e.names[l.lo:l.hi])
	}
	if e.top > 0 && e.levels[e.top - 1].kind != .Array {
		resize(&e.names, l.lo)
	}
	return .None
}

// Takes the name of the next member, an element's or `#text`. A name that is no XML name, text at the root and a second
// root are `.Unwritable`.
@(private)
el_key :: proc(e: ^Elements, name: string) -> core.Typed_Error_Kind {
	l := &e.levels[e.top - 1]
	if name == core.MARKUP_TEXT {
		e.text = true
		return .Unwritable if l.kind == .Root else .None
	}
	if !is_name(transmute([]u8)name) || l.kind == .Root && l.count > 0 {
		return .Unwritable
	}
	l.count += 1
	e.at, e.keyed = len(e.names), true
	if _, err := append(&e.names, name); err != nil {
		return .No_Memory
	}
	return .None
}

// Writes the next element's attribute.
@(private)
el_attribute :: proc(e: ^Elements, name, value: string) -> core.Typed_Error_Kind {
	if !is_name(transmute([]u8)name) {
		return .Unwritable
	}
	el_start(e) or_return
	write.put_byte(e.out, ' ')
	write.put_text(e.out, name)
	write.put_text(e.out, `="`)
	put_escaped(e.out, value, true, e.ascii) or_return
	write.put_byte(e.out, '"')
	return .None
}

// Writes a scalar as the text that stands at the waiting `#text` member or as its next run, or as the next element,
// which `null` leaves empty.
@(private)
el_value :: proc(e: ^Elements, s: string, null := false) -> core.Typed_Error_Kind {
	if e.top == 0 {
		return .Unsupported
	}
	l := &e.levels[e.top - 1]
	if e.text {
		e.text = l.kind == .Text
		l.count += int(e.text)
		return .Unwritable if null else put_text(e.out, s, true, e.ascii)
	}
	lo, hi := e.at, len(e.names)
	if l.kind == .Array {
		lo, hi = l.lo, l.hi
	}
	el_start(e) or_return
	if null {
		write.put_text(e.out, "/>")
	} else {
		write.put_byte(e.out, '>')
		put_text(e.out, s, false, e.ascii) or_return
		put_close(e.out, e.names[lo:hi])
	}
	if e.keyed {
		resize(&e.names, e.at)
	}
	e.keyed, e.tag = false, false
	return .None
}

// Writes the start tag's `<` and name of the next element, unless an attribute wrote them. An array counts it as an item.
@(private)
el_start :: proc(e: ^Elements) -> core.Typed_Error_Kind {
	if e.tag {
		return .None
	}
	l := &e.levels[e.top - 1]
	name: []u8
	switch {
	case l.kind == .Array:
		name = e.names[l.lo:l.hi]
		l.count += 1
	case e.keyed:
		name = e.names[e.at:]
	case:
		return .Unwritable
	}
	write.put_byte(e.out, '<')
	write.put_text(e.out, string(name))
	e.tag = true
	return .None
}

// Starts an element write into `out` with what lasts only the write from `context.allocator`.
@(private)
elements_init :: proc(e: ^Elements, out: ^write.Out, opts: core.Write_Options) {
	e^ = {out = out, ascii = opts.ascii}
	e.names.allocator = context.allocator
}

// Ends the element write `e` made into `out` and returns its text, laid out as `opts` says, to `stream` or in new bytes
// from `allocator`. A compact write already went to `stream`.
@(private)
elements_finish :: proc(e: ^Elements, kind: core.Typed_Error_Kind, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator) -> ([]u8, core.Typed_Refusal) {
	delete(e.names)
	kind := kind
	if kind == .None && e.top != 0 {
		kind = .Out_Of_Order
	}
	text, err := write.finish(e.out, {kind = kind})
	if err.kind != .None || !opts.pretty {
		return text, err
	}
	defer delete(text, e.out.allocator)
	return lay_out(text, opts, stream, allocator)
}

// The compact text `text` laid out as `opts` says: read back as a document and written from its spans.
@(private)
lay_out :: proc(text: []u8, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator) -> ([]u8, core.Typed_Refusal) {
	doc, built := build_spec(text, .Xml, bound_as(.Xml), false, context.allocator)
	defer core.destroy(&doc)
	if built.kind != .None {
		return nil, {kind = .No_Memory if built.kind == .No_Memory else .Unwritable}
	}
	laid, _, err := document_write(&doc, opts, bound_as(.Xml), core.ROOT, stream, allocator)
	return laid, err
}
