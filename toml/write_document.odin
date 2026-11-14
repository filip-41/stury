package toml

// The write of a document as TOML. The root must be an object, since a TOML text is a table. A member is laid out where
// TOML lets it stand: a scalar, an array of anything but tables, and an empty array are `key = value` lines at the top
// of their table, a table is a `[header]` section after the lines, and a non-empty array of tables is one `[[header]]`
// section per element, so the keys of a table may be written in another order than the document holds them. Null has no
// TOML spelling and is `.Unwritable`, as is a key a table repeats. Only TOML 1.0 forms are written: a datetime has its
// seconds, and a string has no `\e` or `\x`. A string read from TOML keeps its literal quotes unless `respell_strings`
// is set, and a datetime string that carries a `Tag` is written as the bare datetime. A comment is written when the
// document holds it: above the line or section it stands before, on the line it ends, and at the end of a table. A
// comment inside a table or an array that is an element of an array stands above that element, since TOML 1.0 has no
// multi-line inline table. A comment the output has no other place for, and one with a line end in its body, is
// dropped and counted.

import "base:runtime"
import "core:io"
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
	tagged:    bool, // the document is of another format and holds a tag
	kept:      int, // the facts written
	glue:      bool, // comments of an omitted header were written, which the next header follows without a blank line
	laid:      bool, // a collection the document writes in line or through dotted keys is written so
}

// Writes node `node` of `doc` as TOML, as `core.write` does with `as(spec)`. A document of another format is written
// too, when its root is an object and it holds no null.
write :: proc(doc: ^core.Document, $S: Spec, write := core.Write_Options{}, node := core.ROOT, allocator := context.allocator) -> (text: []u8, dropped: int, err: core.Error) {
	return core.write(doc, write, as(S), node, allocator)
}

// The handle's `write`: node `node` of `doc` as TOML.
@(private)
document_write :: proc(doc: ^core.Document, opts: core.Write_Options, as: core.As, node: core.Node_Index, stream: io.Stream, allocator: runtime.Allocator) -> (text: []u8, kept: int, err: core.Typed_Refusal) {
	return write_table_text(doc, opts, node, stream, allocator, true)
}

// Node `node` of `doc` as a TOML text. `laid` keeps the layout its collections' `.@style` names, which a text this
// writer laid out in line itself has not chosen.
@(private)
write_table_text :: proc(doc: ^core.Document, opts: core.Write_Options, node: core.Node_Index, stream: io.Stream, allocator: runtime.Allocator, laid: bool) -> (text: []u8, kept: int, err: core.Typed_Refusal) {
	if doc.partial {
		return nil, 0, {kind = .Unsupported}
	}
	if core.kind(doc, node) != .Object {
		return nil, 0, {kind = .Unwritable, detail = {want = {text = "a TOML text is a table, so its root is an object"}}}
	}
	spill: [write.ROOM_MAX]u8 = ---
	l := Layout{doc = doc, opts = opts, own = doc.readers.format == rules_of, laid = laid}
	l.tagged = !l.own && .Tag in doc.readers.holds && core.has_tags(doc)
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
	return text, l.kept, err
}

// Where a member's value stands: on a `key = value` line, in a section of its own, or on dotted-key lines in the table
// that holds it.
@(private)
Place :: enum u8 {
	Line,
	Section,
	Dotted,
}

// A table, or a non-empty array of tables, is a section, unless `laid` and its document writes it in line (`flow`)
// with no comment inside, which an inline table cannot hold, or through dotted keys (`dotted`) and it is not empty.
@(private)
place_of :: proc(l: ^Layout, value: core.Node_Index) -> Place {
	k := core.kind(l.doc, value)
	if k != .Object && k != .Array || k == .Array && core.length(l.doc, value) == 0 {
		return .Line
	}
	if l.laid {
		style, _ := core.fact_value(l.doc, value, .Style)
		switch {
		case style.text == "flow" && !write.holds_inner_fact(l.doc, value):
			return .Line
		case style.text == "dotted" && core.length(l.doc, value) > 0:
			return .Dotted
		}
	}
	if k == .Object {
		return .Section
	}
	it := core.children(l.doc, value)
	for element in core.child_next(&it) {
		if core.kind(l.doc, element) != .Object {
			return .Line
		}
	}
	return .Section
}

// The table at `node`: its header unless it is the root or only holds sections, its lines, its foot comments, then its
// sections. An element of an array of tables always has its header.
@(private)
put_table :: proc(l: ^Layout, node: core.Node_Index, element: bool) -> core.Typed_Error_Kind {
	members := write.node_members(l.doc, node, l.opts.sort_keys, true, runtime.arena_allocator(&l.arena)) or_return
	lines, sections := 0, 0
	for m in members {
		if place_of(l, m.value) == .Section {
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
	} else {
		// A blank line ends the text's head comment, so the first member's comments stay its own.
		before := l.kept
		put_comments(l, node, .Comment)
		if l.kept > before && len(members) > 0 {
			write.put_byte(&l.out, '\n')
		}
	}
	keys := make([dynamic]string, runtime.arena_allocator(&l.arena))
	put_lines(l, members, &keys) or_return
	put_sections(l, members) or_return
	put_foot(l, node)
	return .None
}

// The `key = value` lines of `members`, each key after the dotted path `keys`, and the lines of a dotted member's members
// after its key.
@(private)
put_lines :: proc(l: ^Layout, members: []write.Node_Member, keys: ^[dynamic]string) -> core.Typed_Error_Kind {
	for m in members {
		switch place_of(l, m.value) {
		case .Line:
			put_comments(l, m.value, .Comment)
			for k in keys {
				put_key(&l.out, k)
				write.put_byte(&l.out, '.')
			}
			put_key(&l.out, m.name)
			write.put_text(&l.out, " = ")
			if elements_commented(l, m.value) {
				put_lined_array(l, m.value) or_return
			} else {
				put_inline(l, m.value) or_return
			}
			put_inline_comment(l, m.value)
			write.put_byte(&l.out, '\n')
		case .Dotted:
			put_comments(l, m.value, .Comment)
			inner := write.node_members(l.doc, m.value, l.opts.sort_keys, true, runtime.arena_allocator(&l.arena)) or_return
			append(keys, m.name)
			put_lines(l, inner, keys) or_return
			pop(keys)
		case .Section:
		}
	}
	return .None
}

// The sections of `members`, and those of a dotted member's members under its key.
@(private)
put_sections :: proc(l: ^Layout, members: []write.Node_Member) -> core.Typed_Error_Kind {
	for m in members {
		place := place_of(l, m.value)
		if place == .Line {
			continue
		}
		append(&l.path, m.name)
		switch {
		case place == .Dotted:
			inner := write.node_members(l.doc, m.value, l.opts.sort_keys, true, runtime.arena_allocator(&l.arena)) or_return
			put_sections(l, inner) or_return
		case core.kind(l.doc, m.value) == .Object:
			put_table(l, m.value, false) or_return
		case:
			it := core.children(l.doc, m.value)
			for e in core.child_next(&it) {
				put_table(l, e, true) or_return
			}
		}
		pop(&l.path)
	}
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
	for text, padded in core.comment_next(&it) {
		if !write.comment_lines_ok(text) {
			continue
		}
		if !written && l.out.cursor + l.out.flushed > 0 {
			write.put_byte(&l.out, '\n')
		}
		written = true
		l.kept += 1
		write.put_comment(&l.out, "#", text, padded, 0)
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
	put_inline_comment(l, node)
	write.put_byte(&l.out, '\n')
}

// Whether `node` is an array that holds a comment past its own head and inline ones: on an element, inside an element,
// or a foot comment. Only an array written one element a line has a place for them.
@(private)
elements_commented :: proc(l: ^Layout, node: core.Node_Index) -> bool {
	if !l.commented || core.kind(l.doc, node) != .Array {
		return false
	}
	for f in core.subtree_facts(l.doc, node) {
		if f.role in core.COMMENT_ROLES && (f.node != node || f.role == .Comment_Foot) {
			return true
		}
	}
	return false
}

// The array at `node` one element a line, each with its head comments above it and its inline comment after it, and
// its foot comments before the close. A comment inside an element that is a table or an array has no line of its own in
// TOML 1.0, which has no multi-line inline table, so it stands above the element.
@(private)
put_lined_array :: proc(l: ^Layout, node: core.Node_Index) -> core.Typed_Error_Kind {
	write.put_text(&l.out, "[\n")
	it := core.children(l.doc, node)
	for e in core.child_next(&it) {
		l.kept += write.put_comment_lines(&l.out, l.doc, e, .Comment, 2)
		put_hoisted_comments(l, e)
		write.put_text(&l.out, "  ")
		put_inline(l, e) or_return
		write.put_byte(&l.out, ',')
		put_inline_comment(l, e)
		write.put_byte(&l.out, '\n')
	}
	l.kept += write.put_comment_lines(&l.out, l.doc, node, .Comment_Foot, 2)
	write.put_byte(&l.out, ']')
	return .None
}

// The comments of the nodes below `node`, in document order, each as `#` lines of its own at column 2.
@(private)
put_hoisted_comments :: proc(l: ^Layout, node: core.Node_Index) {
	for f in core.subtree_facts(l.doc, node) {
		if f.node == node || f.role not_in core.COMMENT_ROLES {
			continue
		}
		text, padded := core.comment_text(l.doc, f)
		if write.comment_lines_ok(text) {
			l.kept += 1
			write.put_text(&l.out, "  ")
			write.put_comment(&l.out, "#", text, padded, 2)
			write.put_byte(&l.out, '\n')
		}
	}
}

// An array or inline table `put_inline` has open: the members or elements still to write.
@(private)
Inline_Open :: struct {
	members:  []write.Node_Member,
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
		o.members = write.node_members(l.doc, node, l.opts.sort_keys, true, runtime.arena_allocator(&l.arena)) or_return
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
		return write.put_number_node(&l.out, l.doc, node, TREE, l.own, NUMBER_FORMS)
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
put_string_node :: proc(l: ^Layout, node: core.Node_Index) -> core.Typed_Error_Kind {
	buf: [512]u8
	text := write.node_text(l.doc, node, buf[:], runtime.arena_allocator(&l.arena)) or_return
	// A datetime tag of another format whose text is no TOML datetime of its type is dropped.
	if l.own || l.tagged {
		if tag, tagged := core.fact_value(l.doc, node, .Tag); tagged && DATETIME_TAGS[tag.meaning] != "" {
			if kind := put_datetime(&l.out, text, DATETIME_TAGS[tag.meaning]); kind == .None || l.own {
				l.kept += int(tag.span)
				return kind
			}
		}
	}
	if l.own {
		t := l.doc.nodes[node]
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
			write.put_hex(out, `\u`, u32(c), 4)
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
			write.put_hex(out, `\U` if r > 0xffff else `\u`, u32(r), 8 if r > 0xffff else 4)
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

// Writes `text` as a bare datetime of the type `tag` names, or of any type under an empty `tag`. A text that is not a
// datetime of that type is `.Bad_Raw`. A time with no seconds, which only TOML 1.1 reads, gets `:00`.
@(private)
put_datetime :: proc(out: ^write.Out, text, tag: string) -> core.Typed_Error_Kind {
	kind := text_datetime(text)
	if kind == .Own || tag != "" && kind != tag_datetime(tag) {
		return .Bad_Raw
	}
	src := transmute([]u8)text
	if _, _, v10 := scan_datetime(src, 0, false); v10 != 0 {
		at := 0 if kind == .Local_Time else 11
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

// The one-line comments of `node` that end on its line, after the value, joined into one.
@(private)
put_inline_comment :: proc(l: ^Layout, node: core.Node_Index) {
	if l.commented {
		l.kept += write.put_comment_inline(&l.out, l.doc, node)
	}
}

// Reads `bytes`, a text `end` or a typed write made of an inline table and the comments before it from offset `at`,
// behind `r = ` there, and writes the table `r` holds as a TOML text. The bytes are freed.
@(private)
lay_out_text :: proc(bytes: []u8, at: int, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator) -> ([]u8, core.Typed_Refusal) {
	keyed, made := keyed_text(bytes, at, allocator)
	if !made {
		return nil, {kind = .No_Memory}
	}
	defer delete(keyed, allocator)
	doc, berr := build_text(keyed, bound_as(.Toml_1_1), context.allocator)
	defer core.destroy(&doc)
	if berr.kind != .None {
		return nil, {kind = .Unwritable if berr.kind == .Walk else .No_Memory}
	}
	it := core.pairs(&doc, core.ROOT)
	_, table, found := core.pair_next(&it)
	if !found {
		return nil, {kind = .Unwritable}
	}
	text, _, err := write_table_text(&doc, opts, table, stream, allocator, false)
	return text, err
}

// `bytes` with `r = ` at offset `at`, in new bytes from `allocator`, and false when they are refused. The bytes are
// freed.
@(private)
keyed_text :: proc(bytes: []u8, at: int, allocator: runtime.Allocator) -> ([]u8, bool) {
	defer delete(bytes, allocator)
	keyed, failed := make([]u8, len(bytes) + 4, allocator)
	if failed != nil {
		return nil, false
	}
	copy(keyed, bytes[:at])
	copy(keyed[at:], "r = ")
	copy(keyed[at + 4:], bytes[at:])
	return keyed, true
}
