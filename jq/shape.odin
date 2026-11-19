package jq

// What a compiled program asks of its inputs, for a caller that answers some programs without running them.

import "core:slice"
import core_pkg "../core"
import "../core/rules"

// What a program asks of its inputs:
//	serial     why it needs them in order, on one thread, none when it does not
//	selection  it is `select(PATH op LITERAL)`, unless `select_faults` says why not
//	columns    what it reads of a record whose members are its columns, unless `column_faults` says it reads more
//	spine      it is a filter over the entries of an array that a text's names lead to
Shape :: struct {
	serial:        bit_set[Serial],
	selection:     Selection,
	select_faults: bit_set[Shape_Fault],
	columns:       Columns_Read,
	column_faults: bit_set[Shape_Fault],
	spine:         Spine,
}

// A filter over the entries of the array `names` lead to, of one of the kinds:
//	Length   `length`, or `.NAME... | length`
//	Entries  `.NAME...[]` followed by steps or a pipe, which each entry answers alone: `each` is the program that
//	         answers it, `.NAME...[]` made `.`
//	Collect  `[.NAME...[] | each] | tail` or `.NAME... | map(each) | tail`: `each` (the entries themselves when nil)
//	         collected over the entries, and `tail` run on the array of their outputs, `.` when not `tailed`
Spine :: struct {
	kind:   enum u8 {None, Length, Entries, Collect},
	names:  []string,
	each:   Maybe(Program),
	tail:   Program,
	tailed: bool,
}

// Why a program runs on one thread, its inputs in order:
//	Inputs    it reads inputs (`input`, `inputs`)
//	Position  it reads where its input is (`input_filename`, `input_line_number`)
//	Messages  it writes messages (`debug`, `stderr`)
//	Halts     it halts (`halt`, `halt_error`)
//	Recurses  it runs `recurse` with a filter, or calls a function that calls itself, which needs a deep stack
Serial :: enum u8 {
	Inputs,
	Position,
	Messages,
	Halts,
	Recurses,
}

// The shape of `prog`, its lists and the programs it makes in `allocator`.
shape :: proc(prog: Program, allocator := context.allocator) -> (s: Shape) {
	context.allocator = allocator
	s.serial = serial(prog)
	s.selection, s.select_faults = selection(prog)
	s.columns, s.column_faults = columns(prog)
	names := make([dynamic]string)
	if spine_length(prog, &names) {
		return shaped(s, {kind = .Length}, names)
	}
	clear(&names)
	if each, ok := spine_entries(prog, &names); ok {
		return shaped(s, {kind = .Entries, each = each}, names)
	}
	clear(&names)
	if each, tail, tailed, ok := spine_collect(prog, &names); ok {
		return shaped(s, {kind = .Collect, each = each, tail = tail, tailed = tailed}, names)
	}
	delete(names)
	return
}

@(private = "file")
shaped :: proc(s: Shape, spine: Spine, names: [dynamic]string) -> Shape {
	s := s
	s.spine = spine
	s.spine.names = names[:]
	return s
}

@(private = "file")
serial :: proc(prog: Program) -> bit_set[Serial] {
	w: Serial_Walk
	defer delete(w.on)
	defer delete(w.done)
	body := prog.body
	serial_node(&body, &w)
	return w.why
}

@(private = "file")
with_body :: proc(prog: Program, body: ^Node) -> Program {
	p := prog
	p.body = body
	return p
}

@(private = "file", rodata)
SERIAL_CALLS := [?]struct {
	name: string,
	why:  Serial,
}{
	{"input", .Inputs},
	{"inputs", .Inputs},
	{"input_filename", .Position},
	{"input_line_number", .Position},
	{"debug", .Messages},
	{"stderr", .Messages},
	{"halt", .Halts},
	{"halt_error", .Halts},
}

@(private = "file")
Serial_Walk :: struct {
	on, done: [dynamic]^Func, // the functions whose bodies are being walked, and those walked
	why:      bit_set[Serial],
}

// Adds why the node `p^` and those under it run on one thread to `w.why`. Returns false, so every node is walked.
@(private = "file")
serial_node :: proc(p: ^^Node, w: ^Serial_Walk) -> bool {
	n := p^
	if n == nil || n.kind != .Call {
		return n != nil && any_child(n, w, serial_node)
	}
	for c in SERIAL_CALLS {
		w.why += {c.why} if n.name == c.name else {}
	}
	w.why += {.Recurses} if n.name == "recurse" && len(n.args) > 0 else {}
	// A call of a filter parameter runs its argument, which the walk sees where it is passed.
	if f := n.callee; f != nil && !n.is_param && !slice.contains(w.done[:], f) {
		if slice.contains(w.on[:], f) {
			w.why += {.Recurses}
			return false
		}
		append(&w.on, f)
		serial_node(&f.body, w)
		pop(&w.on)
		append(&w.done, f)
	}
	return any_child(n, w, serial_node)
}

// The comparison of a `select(PATH op LITERAL)`, in the order of `Op`'s.
Comparison :: enum u8 {
	None,
	Eq,
	Ne,
	Lt,
	Le,
	Gt,
	Ge,
}

// `select(PATH op LITERAL)`: `path` is the text of PATH in the program's, and a value prints whole where its PATH's
// answer compares to `literal` so.
Selection :: struct {
	path:    string,
	op:      Comparison,
	literal: core_pkg.Value,
}

// Why a program is not the shape asked of it:
//	Not_Select      no call of `select`
//	Redefined       its `select` is one the program, a module or `~/.jq` defines
//	Not_Comparison  `select`'s argument compares nothing with a scalar literal
//	Not_Path        what it compares is no path of names and indexes
//	Not_Columns     none of the shapes `Columns_Read` tells
//	Select_Columns  `select`'s argument reads more of the record than `.name`
//	Object_Key      an object's key is no literal string
//	Object_Member   an object's value is no `.name`
Shape_Fault :: enum u8 {
	Not_Select,
	Redefined,
	Not_Comparison,
	Not_Path,
	Not_Columns,
	Select_Columns,
	Object_Key,
	Object_Member,
}

@(private = "file")
selection :: proc(prog: Program) -> (s: Selection, faults: bit_set[Shape_Fault]) {
	n := prog.body
	if n.kind != .Call || n.name != "select" || len(n.args) != 1 {
		return {}, {.Not_Select}
	}
	if !is_select(n) {
		return {}, {.Redefined}
	}
	cmp := n.args[0]
	if cmp.kind != .Binary || cmp.op < .Eq || cmp.op > .Ge || cmp.b.kind != .Literal {
		return {}, {.Not_Comparison}
	}
	if k := kind(cmp.b.value); k == .Array || k == .Object {
		return {}, {.Not_Comparison}
	}
	for x := cmp.a; x.kind != .Identity; x = x.a {
		if x.kind != .Field && x.kind != .Index || x.opt {
			return {}, {.Not_Path}
		}
	}
	return {prog.text[cmp.a.loc.start:cmp.a.loc.end], Comparison(int(cmp.op) - int(Op.Eq) + int(Comparison.Eq)), cmp.b.value}, {}
}

#assert(int(Op.Ge) - int(Op.Eq) == int(Comparison.Ge) - int(Comparison.Eq))

// Whether `v`, the answer of a selection's path (nil for none), compares to its literal as the selection asks.
selects :: proc(s: Selection, v: core_pkg.Value) -> bool {
	// A container is above every literal a selection holds.
	c := 1
	if k := kind(v); k != .Array && k != .Object {
		deep: bool
		c = compare(&deep, scalar(v), s.literal, eq = s.op == .Eq || s.op == .Ne)
	}
	return s.op != .None && compared(Op(int(s.op) - int(Comparison.Eq) + int(Op.Eq)), c)
}

// Whether `n` calls the builtin `select`, not a definition of that name.
@(private = "file")
is_select :: proc(n: ^Node) -> bool {
	b, bound := n.native.?
	return bound && b.native == native_select
}

// What a program reads of a record whose members are its columns: `.a, .b` (`Column`), `[.a, .b]` (`Array`),
// `{a, b: .c}` (`Object`, `keys` the members' keys) or `.` (`Object` with `every`), and `select(F)` (`Select`) where F
// reads the record only as `.name`. `names` are the columns in output order, or those F reads.
Columns_Read :: struct {
	shape: Columns_Shape,
	every: bool,
	names: [dynamic]string,
	keys:  [dynamic]string,
}

Columns_Shape :: enum u8 {
	Column,
	Array,
	Object,
	Select,
}

// The columns `prog` reads, its lists in `context.allocator`, or why it reads more. An object's faults are each found.
@(private = "file")
columns :: proc(prog: Program) -> (cols: Columns_Read, faults: bit_set[Shape_Fault]) {
	n := prog.body
	#partial switch n.kind {
	case .Identity:
		cols.shape, cols.every = .Object, true
	case .Call:
		if n.name != "select" || len(n.args) != 1 {
			return cols, {.Not_Columns}
		}
		if !is_select(n) {
			return cols, {.Redefined}
		}
		cols.shape = .Select
		if !only_columns(n.args[0], &cols.names) {
			return cols, {.Select_Columns}
		}
	case .Object:
		cols.shape = .Object
		for i := 0; i < len(n.args); i += 2 {
			key, value := n.args[i], n.args[i + 1]
			k, is_text := key.value.(string)
			if key.kind != .Literal || !is_text {
				faults += {.Object_Key}
			}
			if value != nil && !is_column(value) {
				faults += {.Object_Member}
			}
			name := k if value == nil else value.name
			// A repeated key keeps its place and takes the later value, as in jq.
			if at, repeated := slice.linear_search(cols.keys[:], k); repeated {
				cols.names[at] = name
				continue
			}
			append(&cols.keys, k)
			append(&cols.names, name)
		}
	case:
		cols.shape = .Array if n.kind == .Array else .Column
		if !add_columns(&cols.names, n.a if n.kind == .Array else n) {
			return cols, {.Not_Columns}
		}
	}
	return
}

// Whether `n` is `.name`.
@(private = "file")
is_column :: proc(n: ^Node) -> bool {
	return n.kind == .Field && !n.opt && n.a.kind == .Identity
}

// Appends the columns of `n`, `.a` or `.a, .b`, to `names` in order. Returns false for any other `n`.
@(private = "file")
add_columns :: proc(names: ^[dynamic]string, n: ^Node) -> bool {
	switch {
	case n == nil:
	case n.kind == .Comma:
		return add_columns(names, n.a) && add_columns(names, n.b)
	case is_column(n):
		append(names, n.name)
		return true
	}
	return false
}

// Whether the expression `n`, run on a record, reads it only as `.name`, whose names it appends to `watch`. The right
// side of a `|` does not run on the record. Any other use of `.`, a call that reads `.`, a binding, or an `if` without
// `else` reads more. A nested `select` runs its argument on the same input as `n`.
@(private = "file")
only_columns :: proc(n: ^Node, watch: ^[dynamic]string) -> bool {
	if n == nil {
		return true
	}
	#partial switch n.kind {
	case .Field:
		if n.a.kind != .Identity {
			return only_columns(n.a, watch)
		}
		if !slice.contains(watch[:], n.name) {
			append(watch, n.name)
		}
		return true
	case .Literal, .Var:
		return true
	case .Pipe, .Try:
		return only_columns(n.a, watch)
	case .Index, .Slice, .Iterate, .Array, .Neg, .Comma, .Binary, .And, .Or, .Alt:
		return only_columns(n.a, watch) && only_columns(n.b, watch) && only_columns(n.c, watch)
	case .If:
		return n.c != nil && only_columns(n.a, watch) && only_columns(n.b, watch) && only_columns(n.c, watch)
	case .Call:
		return n.name == "select" && len(n.args) == 1 && only_columns(n.args[0], watch)
	}
	return false
}

// `prog` with the iteration of the spine array at its start, `.NAME...[]`, made `.`, and the names appended to `names`:
// the program each entry answers what the text answers through the array. False for any other program, and for a step
// whose argument is not a literal, which reads the text and not the entry.
@(private = "file")
spine_entries :: proc(prog: Program, names: ^[dynamic]string) -> (entry: Program, ok: bool) {
	body := strip_spine(prog.body, names) or_return
	return with_body(prog, body), true
}

@(private = "file")
strip_spine :: proc(n: ^Node, names: ^[dynamic]string) -> (stripped: ^Node, ok: bool) {
	if n == nil {
		return nil, false
	}
	#partial switch n.kind {
	case .Iterate:
		lead := n.a
		for lead.kind == .Field {
			lead = lead.a
		}
		if lead.kind == .Identity {
			for f := n.a; f.kind == .Field; f = f.a {
				inject_at(names, 0, f.name)
			}
			return new_clone(Node{kind = .Identity}), true
		}
	case .Index, .Slice:
		for arg in ([]^Node{n.b, n.c}) {
			if arg != nil && arg.kind != .Literal {
				return nil, false
			}
		}
	case .Pipe, .Field:
	case:
		return nil, false
	}
	a := strip_spine(n.a, names) or_return
	stripped = new_clone(n^)
	stripped.a = a
	return stripped, true
}

// Whether `prog` is `length` on its input, or `.NAME... | length` with the names appended to `names`.
@(private = "file")
spine_length :: proc(prog: Program, names: ^[dynamic]string) -> bool {
	n := prog.body
	return is_length(n) || n.kind == .Pipe && is_length(n.b) && names_of(n.a, names) && len(names) > 0
}

// `prog` split into the program collected over the entries of an array, `[.NAME...[] | each] | tail` or
// `.NAME... | map(each) | tail`, and the tail run on the array of their outputs, the names that lead to the array
// appended to `names`. With no `| each` the entries themselves are collected, and with no `| tail` (`tailed` false)
// the tail is `.`. False when `prog` is no such program.
@(private = "file")
spine_collect :: proc(prog: Program, names: ^[dynamic]string) -> (each: Maybe(Program), tail: Program, tailed, ok: bool) {
	f, t: ^Node
	c := prog.body
	for c.kind == .Pipe && names_of(c.a, names) {
		c = c.b
	}
	if c.kind == .Pipe {
		c, t = c.a, c.b
	}
	switch {
	case c.kind == .Call && c.name == "map" && len(c.args) == 1 && c.def != nil && c.def.in_prelude:
		f = c.args[0]
	case c.kind == .Array && c.a != nil:
		it := c.a
		for it.kind == .Pipe && names_of(it.a, names) {
			it = it.b
		}
		if it.kind == .Pipe {
			it, f = it.a, it.b
		}
		if it.kind != .Iterate || it.opt || !names_of(it.a, names) {
			return
		}
	case:
		return
	}
	if f != nil {
		each = with_body(prog, f)
	}
	tailed = t != nil
	if !tailed {
		t = new_clone(Node{kind = .Identity})
	}
	return each, with_body(prog, t), tailed, true
}

// Whether `n` is `.` or `.NAME...` with no `?`, whose names are appended to `names`.
@(private = "file")
names_of :: proc(n: ^Node, names: ^[dynamic]string) -> bool {
	at := len(names)
	x := n
	for ; x.kind == .Field && !x.opt; x = x.a {
		inject_at(names, at, x.name)
	}
	if x.kind != .Identity {
		resize(names, at)
		return false
	}
	return true
}

// How the run reads its inputs: on null under `null_input`, as one array of them under `slurp`, as strings under
// `raw`. Under `cells` an input is a record of a table, whose cells are strings or null, and numbers and booleans
// too under `infer`, and which is an array of its cells under `no_header`.
Typing_Input :: struct {
	null_input, slurp, raw:  bool,
	cells, infer, no_header: bool,
}

// The description every output of `prog` passes, typed against the description `input` of what it reads, and the
// steps that no input it describes can take, each told as jq tells a compile error. Every allocation is made in
// `context.allocator`, which the caller frees as a whole.
check_types :: proc(prog: Program, input: ^rules.Description, opts: Typing_Input) -> (outputs: rules.Description, refusals: []string) {
	typing := type_filter(prog, input, opts)
	refusals = make([]string, len(typing.refusals))
	for e, i in typing.refusals {
		refusals[i] = locate(prog.text, e)
	}
	return typing.d, refusals
}
