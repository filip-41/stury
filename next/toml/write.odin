package toml

import "base:runtime"
import "core:io"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import "stury:lib/base/spell"
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
Token_Kind :: write.Token_Kind
Record_Framing :: write.Record_Framing
Refused :: write.Refused
Refusal :: write.Refusal

// The kinds of fact a TOML target writes of any document.
@(private)
HELD :: tape.COMMENTS + {.Style}

// Writes value `opts.node` of `doc`, a document of any format, as a text of `spec` in a buffer from `allocator` that
// the caller owns. The value must be an object. Returns the kinds of the facts `doc` holds that the text does not: a
// comment on an element of an array or a member of a table in braces is not written, nor is any fact but comments,
// styles and, of a TOML document, date-time types. A value with no TOML spelling is `Refused` with its node: a null, a
// number with no decimal text, a key that is a container, a duplicate key, and a root that is no object. `indent` and
// `tab` indent each level of table by that much, and `sort_keys` writes the members of each table in the order of their
// keys' texts. `ascii` and `framing` have no meaning and are `Bad_Option`.
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
	key:      []u8, // the spelling `spell_key` made, the key's own bytes or `tmp`
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

// An open dotted-key table walked iteratively by `put_member`.
@(private)
Dotted_Frame :: struct {
	lo, cur, hi: int,
	dots_len:    int,
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
put_str :: #force_inline proc(t: ^Writing, s: string) {
	write.put(t.out, transmute([]u8)s)
}

@(private)
push_val :: #force_inline proc(t: ^Writing, dst: ^[dynamic]$T, v: T) -> bool {
	if _, err := append(dst, v); err != nil {
		t.w.err = err
		return false
	}
	return true
}

@(private)
push_slice :: #force_inline proc(t: ^Writing, dst: ^[dynamic]$T, b: []T) -> bool {
	if _, err := append(dst, ..b); err != nil {
		t.w.err = err
		return false
	}
	return true
}

// Refuses a `spec` TOML does not have and the options TOML writes no text under.
@(private)
write_check :: proc "contextless" (spec: u8, opts: Write_Options) -> Write_Error {
	if spec > u8(max(Spec)) {
		return tape.Bad_Option{"spec"}
	}
	if opts.format != nil || opts.ascii || opts.framing != .None || opts.grow_header || len(opts.header) > 0 {
		opt := "format" if opts.format != nil else "header" if len(opts.header) > 0 || opts.grow_header else "options"
		return tape.Bad_Option{opt}
	}
	return nil
}

@(private)
write_out :: proc(out: ^write.Out, doc: ^tape.Document, spec: u8, opts: Write_Options, allocator: runtime.Allocator) -> (tape.Facts, write.Error) {
	if e := write_check(spec, opts); e != nil {
		return {}, e
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
	if put_comments(t, root, .Comment, 0) {
		write.put_byte(t.out, '\n')
	}
	if !put_table(t, root, &stack, 0) {
		return
	}
	defer if t.w.err == nil {
		put_comments(t, root, .Comment_Foot, 0)
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
		if (len(t.path) > 0 && !push_val(t, &t.path, u8('.'))) || !push_slice(t, &t.path, t.via[item.via_lo:item.via_hi]) || !spell_key(t, item.key) || !push_slice(t, &t.path, t.key) {
			return
		}
		level := len(stack) - 1
		implicit_skip := style_is(t, item.value, "implicit") && only_tables(t, item.value)
		if t.w.err != nil {
			return
		}
		if !implicit_skip {
			if t.wrote {
				write.put_byte(t.out, '\n')
			}
			if item.array != tape.NO_NODE {
				put_comments(t, item.array, .Comment, level)
			}
			put_comments(t, item.value, .Comment, level)
			put_indent(t, level)
			put_str(t, "[[" if item.element else "[")
			write.put(t.out, t.path[:])
			put_str(t, "]]" if item.element else "]")
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
	path_to, first := len(t.path), len(t.pending)
	if !t.sort && t.toml && write.plain_members(&t.w, at) && t.w.nodes[at].kind == .Object {
		// Native TOML has no duplicate keys, so plain tables stream without copying members.
		for k, end := at + 1, at + tape.Node_Index(t.w.nodes[at].n); k < end; {
			key := k
			val := tape.node_after(t.w.doc, key)
			k = tape.node_after(t.w.doc, val)
			if !put_table_member(t, Member{key = key, value = val}, level) {
				return false
			}
		}
	} else {
		lo, hi, ok := collect(t, at, true)
		if !ok {
			return false
		}
		defer release(t, lo)
		for m in t.members[lo:hi] {
			if !put_table_member(t, m, level) {
				return false
			}
		}
	}
	if at != t.root {
		put_comments(t, at, .Comment_Foot, level)
	}
	return push_val(t, stack, Table_Frame{lo = first, cursor = first, end = len(t.pending), path_to = path_to})
}

// Writes member `m` of a table in line, or lists it as a table still to be written under a header.
@(private)
put_table_member :: #force_inline proc(t: ^Writing, m: Member, level: int) -> bool {
	deferred, listed := defer_table(t, m)
	return listed && (deferred || put_member(t, m, level))
}

// Lists the member `m` of a table as a table still to be written when it is written under a header: an object that is
// not in braces or dotted, or an array of objects, each a table of the array. False with the error set when memory or
// a partial container is refused.
@(private)
defer_table :: proc(t: ^Writing, m: Member) -> (deferred, ok: bool) {
	kind := t.w.nodes[m.value].kind
	via_lo := len(t.via)
	switch {
	case kind == .Object && !style_is(t, m.value, "inline") && !style_is(t, m.value, "dotted"):
		if !push_slice(t, &t.via, t.dots[:]) || !push_val(t, &t.pending, Pending{key = m.key, value = m.value, array = tape.NO_NODE, via_lo = via_lo, via_hi = len(t.via)}) {
			return false, false
		}
	case kind == .Array && !style_is(t, m.value, "inline"):
		if !all_tables(t, m.value) {
			return false, t.w.err == nil
		}
		if !push_slice(t, &t.via, t.dots[:]) {
			return false, false
		}
		elements, ok_c := write.children_as_written(&t.w, m.value)
		if !ok_c {
			return false, false
		}
		defer tape.destroy_children(&elements)
		array := m.value
		for {
			_, element, q := tape.next_child(t.reader, &elements, .Group)
			if q != .Found {
				break
			}
			if !push_val(t, &t.pending, Pending{key = m.key, value = element, array = array, element = true, via_lo = via_lo, via_hi = len(t.via)}) {
				return false, false
			}
			array = tape.NO_NODE
		}
	case:
		return false, true
	}
	return true, true
}

// Writes member `m` of a table as a line at indent `level`: its comments, its key, its value in line, or for a table of
// dotted keys each of its members iteratively on a heap stack so deep dotted keys never recurse on the call stack.
@(private)
put_member :: proc(t: ^Writing, m: Member, level: int) -> bool {
	if is_dotted(t, m.value) {
		return put_dotted_member(t, m, level)
	}
	put_comments(t, m.value, .Comment, level)
	put_indent(t, level)
	write.put(t.out, t.dots[:])
	if !spell_key(t, m.key) {
		return false
	}
	write.put(t.out, t.key)
	put_str(t, " = ")
	// A scalar opens no container, so it takes no walk of its own.
	if !(put_scalar(t, m.value) if t.w.nodes[m.value].kind < .Array else put_inline(t, m.value, level)) {
		return false
	}
	put_tail(t, m.value)
	write.put_byte(t.out, '\n')
	t.wrote = true
	return true
}

// Writes a dotted-key table member `m` iteratively on a heap stack so deep dotted keys never recurse on the call stack.
@(private)
put_dotted_member :: proc(t: ^Writing, m: Member, level: int) -> bool {
	dstack: [dynamic]Dotted_Frame
	dstack.allocator = t.w.allocator
	dots_base, members_base := len(t.dots), len(t.members)
	defer {
		delete(dstack)
		release(t, members_base)
		resize(&t.dots, dots_base)
	}
	cur := m
	for {
		if !spell_key(t, cur.key) {
			return false
		}
		put_comments(t, cur.value, .Comment, level)
		dots_len := len(t.dots)
		if !push_slice(t, &t.dots, t.key) || !push_val(t, &t.dots, u8('.')) {
			return false
		}
		lo, hi, ok := collect(t, cur.value, true)
		if !ok || !push_val(t, &dstack, Dotted_Frame{lo = lo, cur = lo, hi = hi, dots_len = dots_len}) {
			return false
		}
		for len(dstack) > 0 {
			f := &dstack[len(dstack) - 1]
			if f.cur == f.hi {
				resize(&t.dots, f.dots_len)
				release(t, f.lo)
				pop(&dstack)
				continue
			}
			inner := t.members[f.cur]
			f.cur += 1
			deferred, listed := defer_table(t, inner)
			if !listed {
				return false
			}
			if deferred {
				continue
			}
			if is_dotted(t, inner.value) {
				cur = inner
				break
			}
			if !put_member(t, inner, level) {
				return false
			}
		}
		if len(dstack) == 0 {
			return true
		}
	}
}

// Whether the array at `at` holds objects and nothing else, at least one.
@(private)
all_tables :: proc(t: ^Writing, at: tape.Node_Index) -> bool {
	c, ok_c := write.children_as_written(&t.w, at)
	if !ok_c {
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
		if kind == .Object && !style_is(t, m.value, "inline") && !style_is(t, m.value, "dotted") {
			continue
		}
		if kind == .Array && !style_is(t, m.value, "inline") && all_tables(t, m.value) {
			continue
		}
		return false
	}
	return true
}

// Appends the children of the container at `at` to `members`, `lo` to `hi`, and under `sort_keys` orders those of an
// object by their keys' texts, which it holds as copies. Refuses duplicate keys in non-TOML objects.
@(private)
collect :: proc(t: ^Writing, at: tape.Node_Index, object: bool) -> (lo, hi: int, ok: bool) {
	lo = len(t.members)
	c, ok_c := write.children_as_written(&t.w, at)
	if !ok_c {
		return lo, lo, false
	}
	defer tape.destroy_children(&c)
	for {
		key, value, p := tape.next_child(t.reader, &c, .Group)
		if p != .Found {
			break
		}
		if !push_val(t, &t.members, Member{key = key, value = value}) {
			return lo, lo, false
		}
	}
	hi = len(t.members)
	if object && t.sort {
		for &m in t.members[lo:hi] {
			if m.key == tape.NO_NODE || t.w.nodes[m.key].kind > .Plain {
				refuse(t, m.key if m.key != tape.NO_NODE else at)
				return lo, hi, false
			}
			s, good := write.text_of(&t.w, m.key)
			if !good {
				return lo, hi, false
			}
			aerr: runtime.Allocator_Error
			if m.name, aerr = strings.clone(s, t.w.allocator); aerr != nil {
				t.w.err = aerr
				return lo, hi, false
			}
		}
		slice.stable_sort_by(t.members[lo:hi], proc(a, b: Member) -> bool {return a.name < b.name})
		if !t.toml {
			for i in lo + 1 ..< hi {
				if t.members[i].name == t.members[i - 1].name {
					refuse(t, t.members[i].key)
					return lo, hi, false
				}
			}
		}
	} else if object && !t.toml && hi - lo > 1 && !check_no_dups(t, at, lo, hi) {
		return lo, hi, false
	}
	return lo, hi, true
}

// Refuses duplicate keys among `t.members[lo:hi]` of a non-TOML object at `at`.
@(private)
check_no_dups :: proc(t: ^Writing, at: tape.Node_Index, lo, hi: int) -> bool {
	Key_Entry :: struct {
		name:  string,
		key:   tape.Node_Index,
		owned: bool,
	}
	n := hi - lo
	inline_buf: [16]Key_Entry
	entries := inline_buf[:n] if n <= len(inline_buf) else nil
	if entries == nil {
		aerr: runtime.Allocator_Error
		if entries, aerr = make([]Key_Entry, n, t.w.allocator); aerr != nil {
			t.w.err = aerr
			return false
		}
	}
	defer {
		for e in entries {
			if e.owned {
				delete(e.name, t.w.allocator)
			}
		}
		if n > len(inline_buf) {
			delete(entries, t.w.allocator)
		}
	}
	for m, i in t.members[lo:hi] {
		k := m.key
		if k == tape.NO_NODE || t.w.nodes[k].kind > .Plain {
			return refuse(t, k if k != tape.NO_NODE else at)
		}
		s, ok := write.text_of(&t.w, k)
		if !ok {
			return false
		}
		owned := raw_data(s) == raw_data(t.w.scratch)
		if owned {
			cloned, aerr := strings.clone(s, t.w.allocator)
			if aerr != nil {
				t.w.err = aerr
				return false
			}
			s = cloned
		}
		entries[i] = {name = s, key = k, owned = owned}
	}
	if n <= 12 {
		for i in 0 ..< n {
			for j in i + 1 ..< n {
				if entries[i].name == entries[j].name {
					return refuse(t, entries[j].key)
				}
			}
		}
		return true
	}
	slice.sort_by(entries, proc(a, b: Key_Entry) -> bool {return a.name < b.name})
	for i in 1 ..< n {
		if entries[i].name == entries[i - 1].name {
			return refuse(t, entries[i].key)
		}
	}
	return true
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
			if !push_val(t, &stack, frame) {
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
					put_comments(t, f.node, .Comment_Foot, f.level + 1)
					put_indent(t, f.level)
				} else {
					for fact in comments_of(t, f.node) {
						if fact.kind == .Comment_Foot {
							t.skipped += {.Comment_Foot}
						}
					}
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
				put_comments(t, m.value, .Comment, f.level + 1)
				put_indent(t, f.level + 1)
				f.last = m.value
			} else if !f.first {
				put_str(t, ", ")
			}
			f.first = false
			if f.object {
				if !spell_key(t, m.key) {
					return false
				}
				if is_dotted(t, m.value) {
					// The members of a table of dotted keys stand in this one's, each under the key and a point.
					dots_len := len(t.dots)
					if !push_slice(t, &t.dots, t.key) || !push_val(t, &t.dots, u8('.')) {
						return false
					}
					lo, hi, ok := collect(t, m.value, true)
					if !ok || !push_val(t, &stack, Inline_Frame{lo = lo, cur = lo, hi = hi, node = m.value, last = tape.NO_NODE, level = f.level, object = true, first = true, dotted = true, dots_len = dots_len}) {
						return false
					}
					// The separator before the first of them is written, so each after it takes its own.
					continue
				}
				write.put(t.out, t.dots[:])
				write.put(t.out, t.key)
				put_str(t, " = ")
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

// Whether the array or inline table at `at`, whose children are `members[lo:hi]`, holds a comment, between its brackets
// or on a child, which a broken layout can write.
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

// Writes a TOML date/time span, inserting `:00` for TOML 1.1 no-seconds times when targeting TOML 1.0.
@(private)
put_datetime :: proc(t: ^Writing, span: []u8, dk: Date_Kind) {
	if !t.v11 {
		if (dk == .Local_Time && len(span) == 5) || (dk == .Local_Datetime && len(span) == 16) {
			write.put(t.out, span)
			write.put(t.out, transmute([]u8)string(":00"))
			return
		}
		if dk == .Datetime && len(span) > 16 && span[16] != ':' {
			write.put(t.out, span[:16])
			write.put(t.out, transmute([]u8)string(":00"))
			write.put(t.out, span[16:])
			return
		}
	}
	write.put(t.out, span)
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
		encoded, ok := write.bytes_base64(&t.w, at)
		if !ok {
			return false
		}
		defer delete(encoded, t.w.allocator)
		spell_basic(t, encoded, false, true)
	case .String, .Plain:
		if t.toml {
			if dk := date_kind(n); dk != .None {
				put_datetime(t, tape.span_bytes(t.w.doc, n.lo, n.n), dk)
				return true
			}
		}
		s, ok := write.text_of(&t.w, at)
		if !ok {
			return false
		}
		return put_string(t, s, style_name(t, at))
	case:
		return refuse(t, at)
	}
	return t.w.err == nil
}

// Writes the number at `at`: in the base a TOML document wrote it in, with a point when it was a float, and an infinite
// or not-a-number float as `inf` and `nan`.
@(private)
put_number :: proc(t: ^Writing, at: tape.Node_Index) -> bool {
	buf: [write.NUMBER_ROOM]u8 = ---
	base := 0
	value: spell.Number
	if t.toml {
		#partial switch Number_Spelling(t.w.nodes[at].spelling & tape.NUMBER_KIND) {
		case .Plain, .Decimal:
		case .Hex:    base = 16
		case .Octal:  base = 8
		case .Binary: base = 2
		case:         value, _ = tape.node_number(t.w.doc, at)
		}
		if base != 0 {
			value, _ = tape.node_number(t.w.doc, at)
		}
	} else {
		style := style_name(t, at)
		base = 16 if style == "hex" else 8 if style == "octal" else 2 if style == "binary" else 0
		value, _ = tape.node_number(t.w.doc, at)
	}
	if value.kind == .Float {
		if f := transmute(f64)value.bits; math.is_nan(f) || math.is_inf(f) {
			put_str(t, "nan" if math.is_nan(f) else "inf" if f > 0 else "-inf")
			return true
		}
	}
	if base != 0 && (value.kind == .Uint || value.kind == .Int && i64(value.bits) >= 0) {
		put_str(t, "0x" if base == 16 else "0o" if base == 8 else "0b")
		put_str(t, strconv.write_bits(buf[:], value.bits, base, false, 64, "0123456789abcdef", {}))
		return true
	}
	s, ok := write.number_text(&t.w, at, &buf)
	if !ok || !t.toml && (!write.is_json_number(transmute([]u8)s) || value.kind != .Int && !strings.contains_any(s, ".eE")) {
		return refuse(t, at)
	}
	put_str(t, s)
	if !t.toml && style_name(t, at) == "float" && !strings.contains_any(s, ".eE") {
		put_str(t, ".0")
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

// The name a TOML document gives how node `at` is written, empty for another document and a node that has none.
@(private)
style_name :: proc(t: ^Writing, at: tape.Node_Index) -> string {
	if !t.styled {
		return ""
	}
	if t.toml {
		name, _ := spelled_fact(t.w.doc, at, .Style)
		return name
	}
	name, _ := tape.fact_name(t.w.doc, at, .Style)
	return name
}

@(private)
style_is :: proc(t: ^Writing, at: tape.Node_Index, name: string) -> bool {
	return t.styled && style_name(t, at) == name
}

// Whether `s` is a valid TOML bare key (non-empty ASCII letters, digits, `_`, `-`).
@(private)
is_bare_key :: proc "contextless" (s: string) -> bool {
	if len(s) == 0 {
		return false
	}
	for c in transmute([]u8)s {
		if !bare_byte(c) {
			return false
		}
	}
	return true
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
	// A key of a TOML text that was not quoted is made of the bytes a bare key has.
	if t.toml && t.w.nodes[at].spelling & tape.SPELLING_QUOTED == 0 {
		t.key = transmute([]u8)s
		return true
	}
	style := style_name(t, at)
	if is_bare_key(s) && (style == "" || style == "bare") {
		t.key = transmute([]u8)s
		return true
	}
	if style == "literal" && is_literal(s, false) {
		if !literal_string(t, s, false) {
			return false
		}
	} else if !basic_string(t, s) {
		return false
	}
	t.key = t.tmp[:]
	return true
}

// Whether `s` can be written between single quotes: valid UTF-8, no single quote, and no control character but tab,
// and for a multi-line string a line feed too, but not three quotes in a row.
@(private)
is_literal :: proc(s: string, multi: bool) -> bool {
	high: u8 = 0
	for c in transmute([]u8)s {
		high |= c
		if c < 0x20 && c != '\t' && !(multi && c == '\n') || c == 0x7F || c == '\'' && !multi {
			return false
		}
	}
	if high >= 0x80 && !utf8.valid_string(s) {
		return false
	}
	return !multi || !strings.contains(s, "'''")
}

// Makes the literal string of `s` in `t.tmp`.
@(private)
literal_string :: proc(t: ^Writing, s: string, multi: bool) -> bool {
	clear(&t.tmp)
	quote := "'''\n" if multi else "'"
	return push_slice(t, &t.tmp, transmute([]u8)quote) &&
		push_slice(t, &t.tmp, transmute([]u8)s) &&
		push_slice(t, &t.tmp, transmute([]u8)(quote[:3] if multi else quote))
}

// Writes string `s` as TOML spells it by `style`, a basic string when `s` has no spelling in that one.
@(private)
put_string :: proc(t: ^Writing, s: string, style: string) -> bool {
	ok := true
	switch {
	case style == "literal" && is_literal(s, false):          ok = literal_string(t, s, false)
	case style == "multiline_literal" && is_literal(s, true): ok = literal_string(t, s, true)
	case style == "multiline":                                ok = basic_string(t, s, true)
	case:
		spell_basic(t, s, false, true)
		return true
	}
	if ok {
		write.put(t.out, t.tmp[:])
	}
	return ok
}

// Makes the basic string of `s` in `t.tmp`: a quote, a backslash and the control bytes escaped, each other character
// as itself, and with `multi` between triple quotes with its line feeds as they are. A string of invalid UTF-8 has no
// TOML spelling, so each bad byte is a replacement character.
@(private)
basic_string :: proc(t: ^Writing, s: string, multi := false) -> bool {
	clear(&t.tmp)
	return spell_basic(t, s, multi, false)
}

// `basic_string` of `s`, appended to `t.tmp` or with `DIRECT` written to the output.
@(private)
spell_basic :: proc(t: ^Writing, s: string, multi: bool, $DIRECT: bool) -> bool {
	emit :: #force_inline proc(t: ^Writing, b: []u8, $DIRECT: bool) -> bool {
		when DIRECT {
			write.put(t.out, b)
			return true
		} else {
			return push_slice(t, &t.tmp, b)
		}
	}
	quote := transmute([]u8)string("\"\"\"\n" if multi else "\"")
	if !emit(t, quote, DIRECT) {
		return false
	}
	hex := "0123456789abcdef"
	run := 0
	for i := 0; i < len(s); {
		i += write.clean_prefix(transmute([]u8)s[i:], .Toml_Basic)
		if i == len(s) {
			break
		}
		c := s[i]
		if c >= 0x80 {
			r, width := utf8.decode_rune_in_string(s[i:])
			if !(r == utf8.RUNE_ERROR && width == 1) {
				i += width
				continue
			}
		}
		if !emit(t, transmute([]u8)s[run:i], DIRECT) {
			return false
		}
		i += 1
		run = i
		escape: [6]u8
		n := 2
		escape[0] = '\\'
		switch {
		case c == '"':               escape[1] = '"'
		case c == '\\':              escape[1] = '\\'
		case c == '\n' && multi:     escape[0], n = '\n', 1
		case c == '\n':              escape[1] = 'n'
		case c == '\t':              escape[1] = 't'
		case c == '\r':              escape[1] = 'r'
		case c == '\b':              escape[1] = 'b'
		case c == '\f':              escape[1] = 'f'
		case c < 0x20 || c == 0x7F:  escape, n = {'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]}, 6
		case:                        escape, n = {0xEF, 0xBF, 0xBD, 0, 0, 0}, 3
		}
		if !emit(t, escape[:n], DIRECT) {
			return false
		}
	}
	return emit(t, transmute([]u8)s[run:], DIRECT) && emit(t, transmute([]u8)string("\"\"\"" if multi else "\""), DIRECT)
}

// Writes the indent of `level` levels.
@(private)
put_indent :: proc(t: ^Writing, level: int) {
	for _ in 0 ..< level {
		write.put(t.out, t.unit)
	}
}

// The comments of the value at `at`, none for a document that holds no comment.
@(private)
comments_of :: proc(t: ^Writing, at: tape.Node_Index) -> []tape.Fact {
	return tape.facts_of(t.w.doc, at) if t.comments else nil
}

// Writes the comments of `kind` on `at` as lines at indent `level`, each line of a body after a `#`.
@(private)
put_comments :: proc(t: ^Writing, at: tape.Node_Index, kind: tape.Fact_Kind, level: int) -> (wrote: bool) {
	for f in comments_of(t, at) {
		if f.kind == kind {
			wrote = put_comment_lines(t, f, level) || wrote
		}
	}
	return
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
		put_str(t, " #")
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
		put_str(t, "#\n")
		return true
	}
	for line in strings.split_lines_iterator(&rest) {
		put_indent(t, level)
		write.put_byte(t.out, '#')
		put_str(t, line)
		write.put_byte(t.out, '\n')
	}
	return true
}

// Whether a comment of body `b` has a TOML spelling: valid UTF-8 and no control character but tab and the line ends.
@(private)
comment_holds :: proc(b: []u8) -> bool {
	high: u8 = 0
	for c in b {
		high |= c
		if c < 0x20 && c != '\t' && c != '\n' && c != '\r' || c == 0x7F {
			return false
		}
	}
	return high < 0x80 || utf8.valid_string(string(b))
}
