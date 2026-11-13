package toml

// The write of a document as TOML. The root must be an object, since a TOML text is a table. A member is laid out where
// TOML lets it stand: a scalar, an array of anything but tables, and an empty array are `key = value` lines at the top
// of their table, a table is a `[header]` section after the lines, and a non-empty array of tables is one `[[header]]`
// section per element, so the keys of a table may be written in another order than the document holds them. Null has no
// TOML spelling and is `.Unwritable`, as is a key a table repeats. Only TOML 1.0 forms are written: a datetime has its
// seconds, and a string has no `\e` or `\x`. A string read from TOML keeps its literal quotes unless `respell_strings`
// is set, and a datetime string that carries a `Tag` is written as the bare datetime. A comment is written when the
// document holds it: above the line or section it stands before, on the line it ends, and at the end of a table. A
// comment the output has no place for, and one with a line end in its body, is dropped and counted.

import "base:runtime"
import "core:io"
import "core:slice"
import "core:unicode/utf8"
import core "../core"
import write "../core/write"

@(private)
Layout :: struct {
	out:       write.Out,
	doc:       ^core.Document,
	opts:      core.Write_Options,
	arena:     runtime.Arena,
	prefix:    string, // the header path as written that the keys of `path` follow, for sections placed in a text
	path:      [dynamic]string, // the decoded keys of the open section
	own:       bool, // the document is TOML
	commented: bool, // the document holds a comment
	kept:      int, // the comments written
	glue:      bool, // comments of an omitted header were written, which the next header follows without a blank line
}

@(private)
Member :: struct {
	name:  string,
	value: core.Node_Index,
}

// Writes node `node` of `doc` as TOML, as `core.write` does with `as(spec)`. A document of another format is written
// too, when its root is an object and it holds no null.
write :: proc(doc: ^core.Document, spec: Spec, opts := core.Write_Options{}, node := core.ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Error) {
	if int(node) >= len(doc.nodes) || doc.nodes[node].role == .Key {
		return nil, 0, core.error_of(core.Typed_Refusal{kind = .Unsupported})
	}
	out, cut, refusal := document_write(doc, opts, bound_as(spec), node, {}, allocator)
	return out, cut, core.error_of(refusal)
}

// The handle's `write`: node `node` of `doc` as TOML.
@(private)
document_write :: proc(doc: ^core.Document, opts: core.Write_Options, as: core.As, node: core.Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> (text: []u8, dropped: int, err: core.Typed_Refusal) {
	if doc.partial || core.kind(doc, node) != .Object {
		return nil, 0, {kind = .Unsupported}
	}
	spill: [write.ROOM_MAX]u8 = ---
	l := Layout{doc = doc, opts = opts, own = doc.readers.format == rules_of}
	l.arena.backing_allocator = context.allocator
	defer runtime.arena_destroy(&l.arena)
	l.path.allocator = runtime.arena_allocator(&l.arena)
	write.init(&l.out, &spill, allocator, stream, len(doc.src) + write.ROOM_MAX if l.own else 0)
	l.commented = len(core.subtree_facts(doc, node)) > 0
	kind := put_table(&l, node, false)
	text, err = write.finish(&l.out, {kind = kind})
	if err.kind != .None {
		return nil, 0, err
	}
	return text, len(core.subtree_facts(doc, node)) - l.kept, err
}

// The members of the object at `node`, in key order when the output sorts. A key the object repeats is `.Unwritable`.
@(private)
members_of :: proc(l: ^Layout, node: core.Node_Index) -> ([]Member, core.Typed_Error_Kind) {
	scratch := runtime.arena_allocator(&l.arena)
	members := make([dynamic]Member, scratch)
	seen := make(map[string]struct{}, scratch)
	it := core.pairs(l.doc, node)
	for key, value in core.pair_next(&it) {
		name, whole := core.text_clone(l.doc, key, scratch)
		if !whole {
			return nil, .No_Memory
		}
		if name in seen {
			return nil, .Unwritable
		}
		seen[name] = {}
		if _, failed := append(&members, Member{name, value}); failed != nil {
			return nil, .No_Memory
		}
	}
	if l.opts.sort_keys {
		slice.stable_sort_by(members[:], proc(a, b: Member) -> bool {return a.name < b.name})
	}
	return members[:], .None
}

// Whether `value` is written as a section of its own: a table, or a non-empty array of tables.
@(private)
is_section :: proc(l: ^Layout, value: core.Node_Index) -> bool {
	#partial switch core.kind(l.doc, value) {
	case .Object:
		return true
	case .Array:
		if core.length(l.doc, value) == 0 {
			return false
		}
		it := core.children(l.doc, value)
		for element in core.child_next(&it) {
			if core.kind(l.doc, element) != .Object {
				return false
			}
		}
		return true
	}
	return false
}

// The table at `node`: its header unless it is the root or only holds sections, its lines, its foot comments, then its
// sections. An element of an array of tables always has its header.
@(private)
put_table :: proc(l: ^Layout, node: core.Node_Index, element: bool) -> core.Typed_Error_Kind {
	members := members_of(l, node) or_return
	lines, sections := 0, 0
	for m in members {
		if is_section(l, m.value) {
			sections += 1
		} else {
			lines += 1
		}
	}
	if len(l.path) > 0 || l.prefix != "" {
		if element || lines > 0 || sections == 0 {
			put_header(l, node, element)
		} else {
			before := l.kept
			put_comments(l, node, .Comment)
			l.glue = l.kept > before
		}
	}
	for m in members {
		if !is_section(l, m.value) {
			put_comments(l, m.value, .Comment)
			put_key(&l.out, m.name)
			write.put_text(&l.out, " = ")
			put_inline(l, m.value) or_return
			put_inline_comment(l, m.value)
			write.put_byte(&l.out, '\n')
		}
	}
	for m in members {
		if !is_section(l, m.value) {
			continue
		}
		append(&l.path, m.name)
		if core.kind(l.doc, m.value) == .Object {
			put_table(l, m.value, false) or_return
		} else {
			it := core.children(l.doc, m.value)
			for e in core.child_next(&it) {
				put_table(l, e, true) or_return
			}
		}
		pop(&l.path)
	}
	put_foot(l, node)
	return .None
}

// The comments at the end of a table. TOML reads a comment past the last line of a table as the head of what follows it,
// so they are written as the next header's head comments are, after a blank line and with no blank line before the header.
@(private)
put_foot :: proc(l: ^Layout, node: core.Node_Index) {
	if !l.commented {
		return
	}
	it := core.facts_of(l.doc, node, .Comment_Foot)
	written := false
	for body in core.fact_next(&it) {
		if !write.comment_ok(body) {
			continue
		}
		if !written && l.out.cursor + l.out.flushed > 0 {
			write.put_byte(&l.out, '\n')
		}
		written = true
		l.kept += 1
		write.put_byte(&l.out, '#')
		write.put_text(&l.out, body)
		write.put_byte(&l.out, '\n')
	}
	l.glue ||= written
}

// The line `[a.b]` or `[[a.b]]` of the open section, after a blank line unless it is the first.
@(private)
put_header :: proc(l: ^Layout, node: core.Node_Index, element: bool) {
	if l.out.cursor + l.out.flushed > 0 && !l.glue {
		write.put_byte(&l.out, '\n')
	}
	l.glue = false
	put_comments(l, node, .Comment)
	write.put_text(&l.out, "[[" if element else "[")
	write.put_text(&l.out, l.prefix)
	for name, i in l.path {
		if i > 0 || l.prefix != "" {
			write.put_byte(&l.out, '.')
		}
		put_key(&l.out, name)
	}
	write.put_text(&l.out, "]]" if element else "]")
	write.put_byte(&l.out, '\n')
}

// An array or inline table `put_inline` has open: the members or elements still to write.
@(private)
Inline_Open :: struct {
	members:  []Member,
	at:       int,
	elements: core.Child_Iter,
	object:   bool,
}

// A value written in line: a scalar, an array, or an inline table. The arrays and tables inside it are frames of a
// stack in the context allocator, not calls, so the native stack does not grow with the value's depth.
@(private)
put_inline :: proc(l: ^Layout, node: core.Node_Index) -> core.Typed_Error_Kind {
	opens := make([dynamic]Inline_Open, 0, 16)
	defer delete(opens)
	inline_start(l, &opens, node) or_return
	for len(opens) > 0 {
		o := &opens[len(opens) - 1]
		next: core.Node_Index
		if o.object {
			if o.at == len(o.members) {
				write.put_text(&l.out, " }")
				pop(&opens)
				continue
			}
			if o.at > 0 {
				write.put_text(&l.out, ", ")
			}
			m := o.members[o.at]
			o.at += 1
			put_key(&l.out, m.name)
			write.put_text(&l.out, " = ")
			next = m.value
		} else {
			element, more := core.child_next(&o.elements)
			if !more {
				write.put_byte(&l.out, ']')
				pop(&opens)
				continue
			}
			if o.at > 0 {
				write.put_text(&l.out, ", ")
			}
			o.at += 1
			next = element
		}
		inline_start(l, &opens, next) or_return
	}
	return .None
}

// Writes the value at `node` in line, or the opening of an array or a non-empty inline table, which it opens in `opens`.
@(private)
inline_start :: proc(l: ^Layout, opens: ^[dynamic]Inline_Open, node: core.Node_Index) -> core.Typed_Error_Kind {
	o: Inline_Open
	switch core.kind(l.doc, node) {
	case .Object:
		o.members = members_of(l, node) or_return
		if len(o.members) == 0 {
			write.put_text(&l.out, "{}")
			return .None
		}
		write.put_text(&l.out, "{ ")
		o.object = true
	case .Array:
		write.put_byte(&l.out, '[')
		o.elements = core.children(l.doc, node)
	case .String:
		return put_string_node(l, node)
	case .Number:
		return put_number_node(l, node)
	case .True:
		write.put_text(&l.out, "true")
		return .None
	case .False:
		write.put_text(&l.out, "false")
		return .None
	case .Bytes:
		stack: [512]u8
		text, ok := write.node_bytes_text(l.doc, node, stack[:])
		if !ok {
			return .No_Memory
		}
		return put_basic(&l.out, text, l.opts)
	case .Null, .Plain, .End:
		return .Unwritable
	}
	if _, failed := append(opens, o); failed != nil {
		return .No_Memory
	}
	return .None
}

@(private)
put_number_node :: proc(l: ^Layout, node: core.Node_Index) -> core.Typed_Error_Kind {
	t := l.doc.nodes[node]
	span := core.span(l.doc, node)
	if l.doc.readers.number_text != nil {
		stack: [64]u8
		text, ok := write.node_number_text(l.doc, node, stack[:])
		if !ok {
			return .No_Memory
		}
		write.put_text(&l.out, text)
		return .None
	}
	if l.own || t.kind != .Number || t.spelling & core.NUMBER_KIND_MASK == 0 {
		write.put_text(&l.out, string(span))
		return .None
	}
	return write.put_decimal(&l.out, string(span), t.spelling)
}

@(private)
put_string_node :: proc(l: ^Layout, node: core.Node_Index) -> core.Typed_Error_Kind {
	buf: [512]u8
	text, ok := core.text(l.doc, node, buf[:])
	if !ok {
		text, ok = core.text_clone(l.doc, node, runtime.arena_allocator(&l.arena))
		if !ok {
			return .No_Memory
		}
	}
	if l.own {
		t := l.doc.nodes[node]
		if tag, tagged := core.fact_value(l.doc, node, .Tag); tagged {
			return put_datetime(&l.out, text, tag.text)
		}
		if t.spelling & core.SPELLING_DECODE != 0 && !l.opts.respell_strings && style_of(t.spelling) == .Literal && literal_ok(text) {
			write.put_byte(&l.out, '\'')
			write.put_text(&l.out, text)
			write.put_byte(&l.out, '\'')
			return .None
		}
	}
	return put_basic(&l.out, text, l.opts)
}

// Whether `s` can stand between single quotes: no quote, no control byte but tab.
@(private)
literal_ok :: proc(s: string) -> bool {
	for b in transmute([]u8)s {
		if b == '\'' || b < 0x20 && b != '\t' || b == 0x7f {
			return false
		}
	}
	return true
}

// A bare key stays bare, any other is a basic string.
@(private)
put_key :: proc(out: ^write.Out, name: string) {
	bare := len(name) > 0
	for b in transmute([]u8)name {
		if !bare_byte(b) {
			bare = false
			break
		}
	}
	if bare {
		write.put_text(out, name)
	} else {
		put_basic(out, name, {})
	}
}

// Writes `s` as a basic string. Quote, backslash and the control bytes are escaped, DEL always, and with `ascii` every
// rune past U+007F too. Bytes that are no UTF-8 are `.Invalid_Utf8`.
@(private)
put_basic :: proc(out: ^write.Out, s: string, opts: core.Write_Options) -> core.Typed_Error_Kind {
	HEX := "0123456789abcdef"
	write.put_byte(out, '"')
	run := 0
	for i := 0; i < len(s); {
		c := s[i]
		escape: string
		switch {
		case c == '"':
			escape = `\"`
		case c == '\\':
			escape = `\\`
		case c == '\b':
			escape = `\b`
		case c == '\t':
			escape = `\t`
		case c == '\n':
			escape = `\n`
		case c == '\f':
			escape = `\f`
		case c == '\r':
			escape = `\r`
		case c < 0x20 || c == 0x7f:
			write.put_text(out, s[run:i])
			buf := [6]u8{'\\', 'u', '0', '0', HEX[c >> 4], HEX[c & 15]}
			write.put_text(out, string(buf[:]))
			i += 1
			run = i
			continue
		case c < 0x80:
			i += 1
			continue
		case:
			r, width := utf8.decode_rune_in_string(s[i:])
			if r == utf8.RUNE_ERROR && width <= 1 {
				return .Invalid_Utf8
			}
			if !opts.ascii {
				i += width
				continue
			}
			write.put_text(out, s[run:i])
			if r > 0xffff {
				buf := [10]u8{'\\', 'U', HEX[(r >> 28) & 15], HEX[(r >> 24) & 15], HEX[(r >> 20) & 15], HEX[(r >> 16) & 15], HEX[(r >> 12) & 15], HEX[(r >> 8) & 15], HEX[(r >> 4) & 15], HEX[r & 15]}
				write.put_text(out, string(buf[:]))
			} else {
				buf := [6]u8{'\\', 'u', HEX[(r >> 12) & 15], HEX[(r >> 8) & 15], HEX[(r >> 4) & 15], HEX[r & 15]}
				write.put_text(out, string(buf[:]))
			}
			i += width
			run = i
			continue
		}
		write.put_text(out, s[run:i])
		write.put_text(out, escape)
		i += 1
		run = i
	}
	write.put_text(out, s[run:])
	write.put_byte(out, '"')
	return .None
}

// Writes `text` as a bare datetime of the type `tag` names. A text that is not a datetime of that type is `.Bad_Raw`. A
// time with no seconds, which only TOML 1.1 reads, gets `:00`.
@(private)
put_datetime :: proc(out: ^write.Out, text, tag: string) -> core.Typed_Error_Kind {
	want := Datetime.None
	for name, d in DATETIME_TAGS {
		if d != .None && name == tag {
			want = d
		}
	}
	src := transmute([]u8)text
	if want == .None || len(src) < 5 || !datetime_starts(src, 0) {
		return .Bad_Raw
	}
	end, kind, verdict := scan_datetime(src, 0, true)
	if verdict != 0 || end != len(src) || kind != want {
		return .Bad_Raw
	}
	if _, _, v10 := scan_datetime(src, 0, false); v10 != 0 {
		at := 0 if want == .Time else 11
		write.put_text(out, text[:at + 5])
		write.put_text(out, ":00")
		write.put_text(out, text[at + 5:])
		return .None
	}
	write.put_text(out, text)
	return .None
}

// Each comment of `role` on `node` as a line of its own.
@(private)
put_comments :: proc(l: ^Layout, node: core.Node_Index, role: core.Role) {
	if l.commented {
		l.kept += write.put_comment_lines(&l.out, l.doc, node, role, 0)
	}
}

// The first comment of `node` that ends on its line, after the value.
@(private)
put_inline_comment :: proc(l: ^Layout, node: core.Node_Index) {
	if l.commented && write.put_comment_inline(&l.out, l.doc, node) {
		l.kept += 1
	}
}

// Reads `bytes`, a text `end` or a typed write made as `r = {...}`, and writes the table `r` holds as a TOML text. The
// bytes are freed.
@(private)
lay_out_text :: proc(bytes: []u8, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator) -> ([]u8, core.Typed_Refusal) {
	defer delete(bytes, allocator)
	doc, berr := build_text(bytes, bound_as(.Toml_1_0), context.allocator)
	defer core.destroy(&doc)
	if berr.kind != .None {
		return nil, {kind = .Unwritable if berr.kind == .Walk else .No_Memory}
	}
	it := core.pairs(&doc, core.ROOT)
	_, table, found := core.pair_next(&it)
	if !found {
		return nil, {kind = .Unwritable}
	}
	text, _, err := document_write(&doc, opts, bound_as(.Toml_1_0), table, stream, allocator)
	return text, err
}
