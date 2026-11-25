package toml

import "base:runtime"
import "core:encoding/base64"
import "core:io"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "stury:lib/core/tape"
import "stury:lib/ops/write"

// TOML's writer: a document whose root is an object, written as a table. A member that is an object is a table under a
// header, an array of objects an array of tables, and any other value is written in line after its key, a table in
// braces and an array in brackets, so a table's own keys come before its subtables whatever order the document holds.
// Keys are bare where TOML allows it. A string is a basic string, a date-time of a TOML document its own text, a byte
// string a string of its base64, and a number its text. TOML has no null, so that is refused, as is a number with no
// decimal text.
//
// The facts it holds are written: the comments of a value as `#` lines before it, after it on its line and after the
// last member of its table, and the styles a TOML document names, which are the quotes of a string or key, a number's
// base, a float's point, and a table's form (in braces, dotted keys, or only the headers of the tables below it).

Write_Options :: write.Options
Write_Error :: write.Error

// The kinds of fact a TOML target writes of any document.
@(private)
HELD :: tape.COMMENTS + {.Style}

// Writes value `opts.node` of `doc`, a document of any format, as a text of `spec` in a buffer from `allocator` that
// the caller owns. The value must be an object. Returns the kinds of the facts `doc` holds that the text does not: a
// comment on an element of an array or a member of a table in braces is not written, nor is any fact but comments,
// styles and, of a TOML document, date-time types. A value with no TOML spelling is `Refused` with its node: a null, a
// number with no decimal text, a key that is a container, and a root that is no object. `indent` and `tab` indent each
// level of table by that much, and `sort_keys` writes the members of each table in the order of their keys' texts.
// `ascii` and `framing` have no meaning and are `Bad_Option`.
write :: proc(doc: ^tape.Document, spec := Spec.Toml_1_0, opts := Write_Options{}, allocator := context.allocator) -> (text: []u8, dropped: tape.Facts, err: Write_Error) {
	return write.to_buffer(doc, u8(spec), opts, allocator, write_out)
}

// `write` into `sink`, through a buffer of `write.SINK_BYTES` from `allocator`. A sink with no procedure is
// `Bad_Option{"sink"}`. On a refusal or a failed sink the sink may hold a prefix of the text.
write_to :: proc(sink: io.Writer, doc: ^tape.Document, spec := Spec.Toml_1_0, opts := Write_Options{}, allocator := context.allocator) -> (dropped: tape.Facts, err: Write_Error) {
	return write.to_sink(sink, doc, u8(spec), opts, allocator, write_out)
}

// A member of a table or an element of an array, with under `sort_keys` the text of its key.
@(private)
Member :: struct {
	key, value: tape.Node_Index,
	name:       string,
}

// The writer's state: the walk's helper for texts and errors, the output, the dotted path of the table being written
// and a buffer a spelled key or string is made in.
@(private)
Writing :: struct {
	w:        write.Tree,
	out:      ^write.Out,
	path:     [dynamic]u8,
	dots:     [dynamic]u8, // the keys of the dotted tables around the member being written, each with its point
	via:      [dynamic]u8, // the `dots` of each pending table written under the tables around it, as `Pending.via_lo` says
	tmp:      [dynamic]u8,
	pending:  [dynamic]Pending,
	members:  [dynamic]Member,
	reader:   tape.Reader,
	skipped:  tape.Facts, // the kinds of fact on values that stand where no comment can
	unit:     []u8, // what one level of indent is
	root:     tape.Node_Index, // the table written first, whose foot comments end the text
	toml:     bool, // the document is a TOML text, whose date-times are written as they are
	v11:      bool, // the text is TOML 1.1's
	wrote:    bool,
	sort:     bool,
	comments: bool, // the document holds comments
	styled:   bool, // the document holds styles
}

// A table still to be written under its table: an object, or one element of an array of tables, whose array's own
// comments are written before its first.
@(private)
Pending :: struct {
	key, value: tape.Node_Index,
	array:      tape.Node_Index, // the array, for the first element
	element:    bool,
	// The keys of the dotted tables it stands in, each with its point, as `via[via_lo:via_hi]`: a table under a header
	// whose table a dotted key made is named by them in its header.
	via_lo, via_hi: int,
}

// A table whose pending tables are `pending[cursor:end]`, those of the table written before it `pending[:lo]`, and the
// path length that is its own.
@(private)
Table_Frame :: struct {
	lo, cursor, end, path_to: int,
}

@(private)
Inline_Frame :: struct {
	lo, cur, hi: int,
	node:        tape.Node_Index,
	last:        tape.Node_Index, // the element of a broken array written last, whose comma and comment are still to come
	level:       int, // the indent of the line the container opens on
	object:      bool,
	first:       bool,
	broken:      bool, // an array with comments, one element a line
	dotted:      bool, // the members of a table of dotted keys, written in the table around it
	dots_len:    int, // the length of `Writing.dots` before its key
	// The dotted keys around a container in braces or brackets, which are its line's and not its members', while it is
	// open.
	outer:       [dynamic]u8,
}

@(private)
write_out :: proc(out: ^write.Out, doc: ^tape.Document, spec: u8, opts: Write_Options, allocator: runtime.Allocator) -> (tape.Facts, write.Error) {
	if spec > u8(max(Spec)) {
		return {}, tape.Bad_Option{"spec"}
	}
	if opts.format != nil || opts.ascii || opts.framing != .None {
		return {}, tape.Bad_Option{"format" if opts.format != nil else "options"}
	}
	t := Writing{out = out, sort = opts.sort_keys, root = opts.node}
	t.path.allocator, t.dots.allocator, t.via.allocator, t.tmp.allocator, t.pending.allocator, t.members.allocator = allocator, allocator, allocator, allocator, allocator, allocator
	t.unit = transmute([]u8)string("\t") if opts.tab else TABS[:int(opts.indent)]
	defer {
		delete(t.path)
		delete(t.dots)
		delete(t.via)
		delete(t.tmp)
		delete(t.pending)
		release(&t, 0)
		delete(t.members)
	}
	t.v11 = Spec(spec) == .Toml_1_1
	t.toml = doc.format == &FORMATS[.Toml_1_0] || doc.format == &FORMATS[.Toml_1_1]
	held := HELD + {.Tag} if t.toml else HELD
	if e := write.tree_start(&t.w, doc, opts, held, allocator); e != nil {
		return {}, e
	}
	t.reader = {doc, nil}
	t.comments, t.styled = doc.present & tape.COMMENTS != {}, .Style in doc.present
	if doc.nodes[opts.node].kind != .Object {
		t.w.err = write.Refused{opts.node, .No_Spelling}
	} else {
		write_tables(&t, opts.node, allocator)
	}
	// The facts are found by node, not given in order, so the walk reports none of them.
	t.w.fact = len(t.w.facts)
	dropped := write.tree_end(&t.w) + t.skipped
	if t.w.err == nil {
		t.w.err = out.err
	}
	return dropped, t.w.err
}

@(private, rodata)
TABS := [255]u8{0 ..< 255 = ' '}

// Writes the table at `root`, then each table below it in turn, on a stack of frames and a list of the tables left.
@(private)
write_tables :: proc(t: ^Writing, root: tape.Node_Index, allocator: runtime.Allocator) {
	stack: [dynamic]Table_Frame
	stack.allocator = allocator
	defer delete(stack)
	if put_lead(t, root, 0) {
		write.put_byte(t.out, '\n')
	}
	if !put_table(t, root, &stack, 0) {
		return
	}
	defer if t.w.err == nil {
		put_foot(t, root, 0)
	}
	for len(stack) > 0 && t.w.err == nil {
		f := &stack[len(stack) - 1]
		if f.cursor == f.end {
			resize(&t.pending, f.lo)
			resize(&t.path, f.path_to)
			pop(&stack)
			continue
		}
		item := t.pending[f.cursor]
		f.cursor += 1
		resize(&t.path, f.path_to)
		if len(t.path) > 0 {
			append(&t.path, '.')
		}
		append(&t.path, ..t.via[item.via_lo:item.via_hi])
		if !spell_key(t, item.key) {
			return
		}
		append(&t.path, ..t.tmp[:])
		level := len(stack) - 1
		if !(style_is(t, item.value, "implicit") && only_tables(t, item.value)) {
			if t.wrote {
				write.put_byte(t.out, '\n')
			}
			if item.array != tape.NO_NODE {
				put_lead(t, item.array, level)
			}
			put_lead(t, item.value, level)
			put_indent(t, level)
			write.put(t.out, transmute([]u8)string("[[" if item.element else "["))
			write.put(t.out, t.path[:])
			write.put(t.out, transmute([]u8)string("]]" if item.element else "]"))
			put_tail(t, item.value)
			write.put_byte(t.out, '\n')
			t.wrote = true
		}
		if !put_table(t, item.value, &stack, len(stack)) {
			return
		}
	}
}

// Writes the members of the table at `at` that are written in line, at indent `level`, and lists those that are
// tables after the pending ones, as a frame on `stack`.
@(private)
put_table :: proc(t: ^Writing, at: tape.Node_Index, stack: ^[dynamic]Table_Frame, level: int) -> bool {
	lo, hi, ok := collect(t, at, true)
	if !ok {
		return false
	}
	defer release(t, lo)
	frame := Table_Frame{path_to = len(t.path)}
	// A frame's tables come after those of the frames below it, so the list is cut back to where its own start.
	first := len(t.pending)
	for m in t.members[lo:hi] {
		deferred, listed := defer_table(t, m)
		if !listed ||!deferred && !put_member(t, m, level) {
			return false
		}
	}
	if at != t.root {
		put_foot(t, at, level)
	}
	frame.lo, frame.cursor, frame.end = first, first, len(t.pending)
	_, e := append(stack, frame)
	if e != nil {
		t.w.err = e
		return false
	}
	return true
}

// Lists the member `m` of a table as a table still to be written when it is written under a header: an object that is
// not in braces or dotted, or an array of objects, each a table of the array. False with the error set when memory is
// refused.
@(private)
defer_table :: proc(t: ^Writing, m: Member) -> (deferred, ok: bool) {
	kind := t.w.nodes[m.value].kind
	via_lo := len(t.via)
	switch {
	case kind == .Object && !style_is(t, m.value, "inline") && !style_is(t, m.value, "dotted"):
		append(&t.via, ..t.dots[:])
		append(&t.pending, Pending{key = m.key, value = m.value, array = tape.NO_NODE, via_lo = via_lo, via_hi = len(t.via)})
	case kind == .Array && !style_is(t, m.value, "inline") && all_tables(t, m.value):
		elements, _, e := tape.children(t.reader, m.value, t.w.allocator)
		if e != nil {
			t.w.err = e
			return false, false
		}
		array := m.value
		append(&t.via, ..t.dots[:])
		for {
			_, element, q := tape.next_child(t.reader, &elements, .Group)
			if q != .Found {
				break
			}
			append(&t.pending, Pending{key = m.key, value = element, array = array, element = true, via_lo = via_lo, via_hi = len(t.via)})
			array = tape.NO_NODE
		}
		tape.destroy_children(&elements)
	case:
		return false, true
	}
	return true, true
}

// Writes member `m` of a table as a line at indent `level`: its comments, its key, its value in line, or for a table of
// dotted keys each of its members as a line under the key and a point.
@(private)
put_member :: proc(t: ^Writing, m: Member, level: int) -> bool {
	if is_dotted(t, m.value) {
		if !spell_key(t, m.key) {
			return false
		}
		put_lead(t, m.value, level)
		before := len(t.dots)
		append(&t.dots, ..t.tmp[:])
		append(&t.dots, '.')
		lo, hi, ok := collect(t, m.value, true)
		if !ok {
			return false
		}
		defer release(t, lo)
		for inner in t.members[lo:hi] {
			deferred, listed := defer_table(t, inner)
			if !listed || !deferred && !put_member(t, inner, level) {
				return false
			}
		}
		resize(&t.dots, before)
		return true
	}
	put_lead(t, m.value, level)
	put_indent(t, level)
	write.put(t.out, t.dots[:])
	if !spell_key(t, m.key) {
		return false
	}
	write.put(t.out, t.tmp[:])
	write.put(t.out, transmute([]u8)string(" = "))
	if !put_inline(t, m.value, level) {
		return false
	}
	put_tail(t, m.value)
	write.put_byte(t.out, '\n')
	t.wrote = true
	return true
}

// Whether the array at `at` holds objects and nothing else, at least one.
@(private)
all_tables :: proc(t: ^Writing, at: tape.Node_Index) -> bool {
	c, _, err := tape.children(t.reader, at, t.w.allocator)
	if err != nil {
		t.w.err = err
		return false
	}
	defer tape.destroy_children(&c)
	any := false
	for {
		_, value, p := tape.next_child(t.reader, &c, .Group)
		if p != .Found {
			return any
		}
		if t.w.nodes[value].kind != .Object {
			return false
		}
		any = true
	}
}

// Whether every member of the table at `at` is itself written under a header, so that a header of the table says
// nothing its subtables' do not.
@(private)
only_tables :: proc(t: ^Writing, at: tape.Node_Index) -> bool {
	lo, hi, ok := collect(t, at, false)
	if !ok {
		return false
	}
	defer release(t, lo)
	for m in t.members[lo:hi] {
		kind := t.w.nodes[m.value].kind
		if !(kind == .Object && !style_is(t, m.value, "inline") && !style_is(t, m.value, "dotted") || kind == .Array && !style_is(t, m.value, "inline") && all_tables(t, m.value)) {
			return false
		}
	}
	return true
}

// Appends the children of the container at `at` to `members`, `lo` to `hi`, and under `sort_keys` orders those of an
// object by their keys' texts, which it holds as copies.
@(private)
collect :: proc(t: ^Writing, at: tape.Node_Index, object: bool) -> (lo, hi: int, ok: bool) {
	lo = len(t.members)
	c, _, err := tape.children(t.reader, at, t.w.allocator)
	if err != nil {
		t.w.err = err
		return lo, lo, false
	}
	defer tape.destroy_children(&c)
	for {
		key, value, p := tape.next_child(t.reader, &c, .Group)
		if p != .Found {
			break
		}
		if _, err = append(&t.members, Member{key = key, value = value}); err != nil {
			t.w.err = err
			return lo, lo, false
		}
	}
	hi = len(t.members)
	if t.sort && object {
		for &m in t.members[lo:hi] {
			if t.w.nodes[m.key].kind > .Plain {
				refuse(t, m.key)
				return lo, hi, false
			}
			s, good := write.text_of(&t.w, m.key)
			if !good {
				return lo, hi, false
			}
			m.name, err = strings.clone(s, t.w.allocator)
			if err != nil {
				t.w.err = err
				return lo, hi, false
			}
		}
		slice.stable_sort_by(t.members[lo:hi], proc(a, b: Member) -> bool {return a.name < b.name})
	}
	return lo, hi, true
}

// Drops the members from `lo` on and the key texts they hold.
@(private)
release :: proc(t: ^Writing, lo: int) {
	for m in t.members[lo:] {
		delete(m.name, t.w.allocator)
	}
	resize(&t.members, lo)
}

// Writes the value at `at` in line: a scalar, a table in braces or an array in brackets, with a stack of its own.
@(private)
put_inline :: proc(t: ^Writing, at: tape.Node_Index, level: int) -> bool {
	stack: [dynamic]Inline_Frame
	stack.allocator = t.w.allocator
	base := len(t.members)
	defer {
		release(t, base)
		for f in stack {
			delete(f.outer)
		}
		delete(stack)
	}
	next := at
	for {
		kind := t.w.nodes[next].kind
		inside, in_broken := level, false
		if len(stack) > 0 {
			up := stack[len(stack) - 1]
			in_broken = up.broken
			inside = up.level + 1 if in_broken else up.level
		}
		if next != at && !in_broken {
			skip_comments(t, next)
		}
		if kind >= .Array {
			lo, hi, ok := collect(t, next, kind == .Object)
			if !ok {
				return false
			}
			// A table in braces holds a comment between its members in a text of TOML 1.1, which has a line for each.
			broken := (kind == .Array || kind == .Object && t.v11) && has_notes(t, next, lo, hi)
			frame := Inline_Frame{lo = lo, cur = lo, hi = hi, node = next, last = tape.NO_NODE, level = inside, object = kind == .Object, first = true, broken = broken}
			if len(t.dots) > 0 {
				frame.outer = t.dots
				t.dots = make([dynamic]u8, t.w.allocator)
			}
			if _, err := append(&stack, frame); err != nil {
				t.w.err = err
				return false
			}
			write.put_byte(t.out, '{' if kind == .Object else '[')
			if broken {
				write.put_byte(t.out, '\n')
			}
		} else if !put_scalar(t, next) {
			return false
		}
		// The next value of the innermost container that has one, or the end of the value.
		for {
			if len(stack) == 0 {
				return true
			}
			f := &stack[len(stack) - 1]
			if f.last != tape.NO_NODE {
				write.put_byte(t.out, ',')
				put_tail(t, f.last)
				write.put_byte(t.out, '\n')
				f.last = tape.NO_NODE
			}
			if f.cur == f.hi {
				if f.broken {
					put_foot(t, f.node, f.level + 1)
					put_indent(t, f.level)
				}
				if f.dotted {
					resize(&t.dots, f.dots_len)
				} else {
					write.put_byte(t.out, '}' if f.object else ']')
					if f.outer != nil {
						delete(t.dots)
						t.dots = f.outer
					}
				}
				release(t, f.lo)
				pop(&stack)
				continue
			}
			m := t.members[f.cur]
			f.cur += 1
			if f.broken {
				_ = put_lead(t, m.value, f.level + 1)
				put_indent(t, f.level + 1)
				f.last = m.value
			} else if !f.first {
				write.put(t.out, transmute([]u8)string(", "))
			}
			f.first = false
			if f.object {
				if !spell_key(t, m.key) {
					return false
				}
				if is_dotted(t, m.value) {
					// The members of a table of dotted keys stand in this one's, each under the key and a point.
					dots_len := len(t.dots)
					append(&t.dots, ..t.tmp[:])
					append(&t.dots, '.')
					lo, hi, ok := collect(t, m.value, true)
					if !ok {
						return false
					}
					if _, err := append(&stack, Inline_Frame{lo = lo, cur = lo, hi = hi, node = m.value, last = tape.NO_NODE, level = f.level, object = true, first = true, dotted = true, dots_len = dots_len}); err != nil {
						t.w.err = err
						return false
					}
					// The separator before the first of them is written, so each after it takes its own.
					continue
				}
				write.put(t.out, t.dots[:])
				write.put(t.out, t.tmp[:])
				write.put(t.out, transmute([]u8)string(" = "))
			}
			next = m.value
			break
		}
	}
}

// Whether the object at `at` is written as dotted keys: it was, and it holds more than itself.
@(private)
is_dotted :: proc(t: ^Writing, at: tape.Node_Index) -> bool {
	return t.w.nodes[at].kind == .Object && t.w.nodes[at].n > 1 && style_is(t, at, "dotted")
}

// Whether the array at `at`, whose elements are `members[lo:hi]`, holds a comment, between its brackets or on an
// element, which a text with one element a line can write.
@(private)
has_notes :: proc(t: ^Writing, at: tape.Node_Index, lo, hi: int) -> bool {
	if !t.comments {
		return false
	}
	for f in comments_of(t, at) {
		if f.kind == .Comment_Foot {
			return true
		}
	}
	for m in t.members[lo:hi] {
		for f in comments_of(t, m.value) {
			if f.kind in tape.COMMENTS {
				return true
			}
		}
	}
	return false
}

// Writes the scalar at `at`. False with `w.err` set when TOML has no spelling for it.
@(private)
put_scalar :: proc(t: ^Writing, at: tape.Node_Index) -> bool {
	n := t.w.nodes[at]
	#partial switch n.kind {
	case .True:
		write.put(t.out, transmute([]u8)string("true"))
	case .False:
		write.put(t.out, transmute([]u8)string("false"))
	case .Number:
		return put_number(t, at)
	case .Bytes:
		s, ok := write.text_of(&t.w, at)
		if !ok {
			return false
		}
		encoded, err := base64.encode(transmute([]u8)s, allocator = t.w.allocator)
		if err != nil {
			t.w.err = err
			return false
		}
		defer delete(encoded, t.w.allocator)
		basic_string(t, encoded)
		write.put(t.out, t.tmp[:])
	case .String, .Plain:
		if t.toml && date_kind(n) != .None {
			write.put(t.out, tape.span_bytes(t.w.doc, n.lo, n.n))
			return true
		}
		s, ok := write.text_of(&t.w, at)
		if !ok {
			return false
		}
		put_string(t, s, style_name(t, at))
	case:
		return refuse(t, at)
	}
	return true
}

// Writes the number at `at`: in the base a TOML document wrote it in, with a point when it was a float, and an infinite
// or not-a-number float as `inf` and `nan`.
@(private)
put_number :: proc(t: ^Writing, at: tape.Node_Index) -> bool {
	buf: [write.NUMBER_ROOM]u8
	style := style_name(t, at)
	value, _ := tape.node_number(t.w.doc, at)
	if value.kind == .Float {
		f := transmute(f64)value.bits
		if math.is_nan(f) || math.is_inf(f) {
			write.put(t.out, transmute([]u8)string("nan" if math.is_nan(f) else "inf" if f > 0 else "-inf"))
			return true
		}
	}
	if style == "hex" || style == "octal" || style == "binary" {
		base := 16 if style == "hex" else 8 if style == "octal" else 2
		if value.kind == .Uint || value.kind == .Int && i64(value.bits) >= 0 {
			write.put(t.out, transmute([]u8)string("0x" if base == 16 else "0o" if base == 8 else "0b"))
			write.put(t.out, transmute([]u8)strconv.write_bits(buf[:], value.bits, base, false, 64, "0123456789abcdef", {}))
			return true
		}
	}
	s, ok := write.number_text(&t.w, at, &buf)
	if !ok || !toml_number(t, at, s) {
		return refuse(t, at)
	}
	write.put(t.out, transmute([]u8)s)
	if style == "float" && !strings.contains_any(s, ".eE") {
		write.put(t.out, transmute([]u8)string(".0"))
	}
	return true
}

@(private)
refuse :: proc(t: ^Writing, at: tape.Node_Index) -> bool {
	if t.w.err == nil {
		t.w.err = write.Refused{at, .No_Spelling}
	}
	return false
}

// Whether the number at `at`, of text `s`, is a TOML number: an integer that fits 64 bits, or a float, which TOML reads
// as JSON does.
@(private)
toml_number :: proc(t: ^Writing, at: tape.Node_Index, s: string) -> bool {
	if !write.is_json_number(transmute([]u8)s) {
		return false
	}
	for c in transmute([]u8)s {
		if c == '.' || c == 'e' || c == 'E' {
			return true
		}
	}
	n, _ := tape.node_number(t.w.doc, at)
	return n.kind == .Int
}

// The name a TOML document gives how node `at` is written, empty for another document and a node that has none.
@(private)
style_name :: proc(t: ^Writing, at: tape.Node_Index) -> string {
	if !t.styled {
		return ""
	}
	name, _ := tape.fact_name(t.w.doc, at, .Style)
	return name
}

@(private)
style_is :: proc(t: ^Writing, at: tape.Node_Index, name: string) -> bool {
	return t.styled && style_name(t, at) == name
}

// Makes the spelling of the key at `at` in `t.tmp`: bare when it is letters, digits, `_` and `-` and the key was not
// quoted, else a basic string, or a literal one when it was written as that.
@(private)
spell_key :: proc(t: ^Writing, at: tape.Node_Index) -> bool {
	if t.w.nodes[at].kind > .Plain {
		return refuse(t, at)
	}
	s, ok := write.text_of(&t.w, at)
	if !ok {
		return false
	}
	bare := len(s) > 0
	for c in transmute([]u8)s {
		bare &&= c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-'
	}
	style := style_name(t, at)
	if bare && (style == "" || style == "bare") {
		clear(&t.tmp)
		append(&t.tmp, s)
	} else if style == "literal" && is_literal(s, false) {
		literal_string(t, s, false)
	} else {
		basic_string(t, s)
	}
	return true
}

// Whether `s` can be written between single quotes: no single quote, and no control character but tab, and for a
// multi-line string a line feed too, but not three quotes in a row.
@(private)
is_literal :: proc(s: string, multi: bool) -> bool {
	for c in transmute([]u8)s {
		if c < 0x20 && c != '\t' && !(multi && c == '\n') || c == 0x7F || c == '\'' && !multi {
			return false
		}
	}
	return !multi || !strings.contains(s, "'''") && utf8.valid_string(s)
}

// Makes the literal string of `s` in `t.tmp`.
@(private)
literal_string :: proc(t: ^Writing, s: string, multi: bool) {
	clear(&t.tmp)
	quote := "'''\n" if multi else "'"
	append(&t.tmp, quote)
	append(&t.tmp, s)
	append(&t.tmp, quote[:3] if multi else quote)
}

// Writes string `s` as TOML spells it by `style`, a basic string when `s` has no spelling in that one.
@(private)
put_string :: proc(t: ^Writing, s: string, style: string) {
	switch {
	case style == "literal" && is_literal(s, false):
		literal_string(t, s, false)
	case style == "multiline_literal" && is_literal(s, true):
		literal_string(t, s, true)
	case style == "multiline":
		basic_string(t, s, true)
	case:
		basic_string(t, s)
	}
	write.put(t.out, t.tmp[:])
}

// Makes the basic string of `s` in `t.tmp`: a quote, a backslash and the control bytes escaped, each other character
// as itself, and with `multi` between triple quotes with its line feeds as they are. A string of invalid UTF-8 has no
// TOML spelling, so each bad byte is a replacement character.
@(private)
basic_string :: proc(t: ^Writing, s: string, multi := false) {
	clear(&t.tmp)
	append(&t.tmp, "\"\"\"\n" if multi else "\"")
	hex := "0123456789abcdef"
	for r in s {
		switch {
		case r == '"':
			append(&t.tmp, '\\', '"')
		case r == '\\':
			append(&t.tmp, '\\', '\\')
		case r == '\n':
			if multi {
				append(&t.tmp, '\n')
			} else {
				append(&t.tmp, '\\', 'n')
			}
		case r == '\t':
			append(&t.tmp, '\\', 't')
		case r == '\r':
			append(&t.tmp, '\\', 'r')
		case r == '\b':
			append(&t.tmp, '\\', 'b')
		case r == '\f':
			append(&t.tmp, '\\', 'f')
		case r < 0x20 || r == 0x7F:
			append(&t.tmp, '\\', 'u', '0', '0', hex[r >> 4], hex[r & 15])
		case r == utf8.RUNE_ERROR:
			append(&t.tmp, "\xEF\xBF\xBD")
		case:
			buf, n := utf8.encode_rune(r)
			append(&t.tmp, ..buf[:n])
		}
	}
	append(&t.tmp, "\"\"\"" if multi else "\"")
}

// Writes the indent of `level` levels.
@(private)
put_indent :: proc(t: ^Writing, level: int) {
	for _ in 0 ..< level {
		write.put(t.out, t.unit)
	}
}

// The comments of kind `kind` of the value at `at`, none for a document that holds no comment.
@(private)
comments_of :: proc(t: ^Writing, at: tape.Node_Index) -> []tape.Fact {
	return tape.facts_of(t.w.doc, at) if t.comments else nil
}

// Writes the comments before the value at `at` as lines at indent `level`, each line of a body after a `#`. Returns
// whether it wrote any.
@(private)
put_lead :: proc(t: ^Writing, at: tape.Node_Index, level: int) -> (wrote: bool) {
	for f in comments_of(t, at) {
		if f.kind == .Comment {
			wrote = put_comment_lines(t, f, level) || wrote
		}
	}
	return
}

// Writes the comments that end the table at `at` as lines at indent `level`.
@(private)
put_foot :: proc(t: ^Writing, at: tape.Node_Index, level: int) {
	for f in comments_of(t, at) {
		if f.kind == .Comment_Foot {
			put_comment_lines(t, f, level)
		}
	}
}

// Writes the comment on the line where the value at `at` ends, its body joined on one line.
@(private)
put_tail :: proc(t: ^Writing, at: tape.Node_Index) {
	done := false
	for f in comments_of(t, at) {
		if f.kind != .Comment_Inline {
			continue
		}
		body, _ := write.comment_body(t.w.doc, f)
		if done || !comment_holds(body) {
			t.skipped += {.Comment_Inline}
			continue
		}
		done = true
		write.put(t.out, transmute([]u8)string(" #"))
		for c in body {
			write.put_byte(t.out, ' ' if c == '\n' || c == '\r' else c)
		}
	}
}

// Notes that the comments of the value at `at` are not written, as it stands where TOML holds none.
@(private)
skip_comments :: proc(t: ^Writing, at: tape.Node_Index) {
	for f in comments_of(t, at) {
		t.skipped += {f.kind}
	}
}

// Writes comment `f` as a line for each line of its body at indent `level`.
@(private)
put_comment_lines :: proc(t: ^Writing, f: tape.Fact, level: int) -> bool {
	body, _ := write.comment_body(t.w.doc, f)
	if !comment_holds(body) {
		t.skipped += {f.kind}
		return false
	}
	rest := string(body)
	if len(rest) == 0 {
		put_indent(t, level)
		write.put_byte(t.out, '#')
		write.put_byte(t.out, '\n')
		return true
	}
	for line in strings.split_lines_iterator(&rest) {
		put_indent(t, level)
		write.put_byte(t.out, '#')
		write.put(t.out, transmute([]u8)line)
		write.put_byte(t.out, '\n')
	}
	return true
}

// Whether a comment of body `b` has a TOML spelling: it holds no control character but tab and the line ends.
@(private)
comment_holds :: proc "contextless" (b: []u8) -> bool {
	for c in b {
		if c < 0x20 && c != '\t' && c != '\n' && c != '\r' || c == 0x7F {
			return false
		}
	}
	return true
}
