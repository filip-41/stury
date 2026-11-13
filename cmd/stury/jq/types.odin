package jq

// Types a filter by the description of its input (core/rules), before any input is read. Each form gives a node
// that every output of the form passes. A rule the typing cannot follow is left out, never assumed. A step that no
// value of the input can take is refused: an index on a kind that holds no member, an operator or a builtin on kinds
// it does not take, and a member that no object of the description describes, where the description lists the
// members of each object. The typing's description starts with the input's nodes, so a member keeps the input's
// description of it and a `$ref` still reaches its target. `unknown` stands for a value the typing cannot describe.
// It takes any value, and nothing read from it is refused. types_eval.odin types the forms, types_builtins.odin the
// builtins.

import "core:math"
import "core:slice"
import "core:strings"
import "../message"
import "../../../core/regex"
import "../../../core/rules"

// How the run reads its inputs: on null under `null_input`, as one array of them under `slurp`, as strings under
// `raw`. Under `cells` an input is a record of a table, whose cells are strings or null, and numbers and booleans
// too under `infer`, and which is an array of its cells under `no_header`. `names` and `values` are the command
// line's variables, and `text` the filter's text, which a refusal points into.
Typing_Input :: struct {
	null_input, slurp, raw:  bool,
	cells, infer, no_header: bool,
	names:                   []string,
	values:                  []Value,
	text:                    string,
}

// The typing of a filter. `d` holds the input's nodes and the typing's, and its `root` is the node every output passes.
Typing :: struct {
	d:        rules.Description,
	refusals: []Compile_Error,
}

@(private)
Ty :: rules.Node_Index

@(private)
Typer :: struct {
	d:        ^rules.Description,
	input:    Typing_Input,
	root:     Ty, // one input value, which `input` gives
	refusals: [dynamic]Compile_Error,
	told:     map[Loc]struct{},
	steps:    int,
	nesting:  int,
	// `quiet` counts the open `try` and `?`, where a step that fails is the filter's own choice. `soft` counts the
	// open paths an update or `path` reads, where a member that is not there is made.
	quiet:    int,
	soft:     int,
	// Counts the open rounds of a fixpoint. Their refusals are told once, on the state it settles on.
	held:     int,
	// The filter's own call of a prelude definition. Refusals inside the definition are told at this call and name it.
	site:     ^Node,
	active:   map[^Func]int,
	resource: Ty,
	unknown, any, never, null, empty: Ty,
	// How many nodes and objects the input's description holds. Those past them are the typing's.
	input_nodes, input_objects: int,
	plain:    map[Ty]rules.Kinds,
	unions:   map[Ty][]Ty,
	split:    map[Ty]Branches,
	memo:     map[string]Ty,
	patterns: rules.Programs,
	scratch:  regex.Scratch,
}

@(private)
Branches :: struct {
	of:       [][dynamic]Ty,
	complete: bool,
}

// Units of work before the rest of the typing is unknown: a form typed, a node made, read or split.
@(private)
TYPE_STEPS :: 200_000

// Forms open at once. A form nested deeper is unknown.
@(private)
MAX_NESTING :: 512

// Calls of one function open at once. A deeper call is unknown.
@(private)
MAX_RECURSION :: 2

// Arms of a choice (the conjunctions a node splits into, or the arms of a union). A choice with more is unknown.
@(private)
MAX_ARMS :: 64

// Rounds of a fixpoint (a fold's state, a recursion's values). One that has not settled by then is unknown.
@(private)
MAX_ROUNDS :: 16

// Types `prog`, as `check` returns it, against the description `input` of what it reads. Every allocation is made
// in `context.allocator`, which the caller frees as a whole.
type_filter :: proc(prog: ^Node, input: ^rules.Description, opts: Typing_Input) -> Typing {
	t := new(Typer)
	t.d = new(rules.Description)
	t.d^ = input^
	t.d.nodes = slice.clone_to_dynamic(input.nodes[:])
	t.d.arrays = slice.clone_to_dynamic(input.arrays[:])
	t.d.objects = slice.clone_to_dynamic(input.objects[:])
	t.d.texts = {}
	t.d.allocator = context.allocator
	// Draft 4's integer refuses `1.0` and no 2020-12 keyword can say so, so the typing uses 2020-12 integers.
	for &n in t.d.nodes {
		n.integer_spelled = false
	}
	t.input = opts
	t.input_nodes = len(t.d.nodes)
	t.resource = input.nodes[input.root].resource if len(input.nodes) > 0 else 0
	t.unknown = made(t, blank(t, rules.EVERY_KIND))
	t.any = kinds_node(t, rules.EVERY_KIND)
	t.never = kinds_node(t, {})
	t.null = kinds_node(t, {.Null})
	t.empty = array_of(t, t.never)
	record := cells_record(t) if opts.cells else t.d.root
	t.input_objects = len(t.d.objects)
	switch {
	case opts.raw:
		t.root = kinds_node(t, {.String})
	case opts.slurp:
		t.root = array_of(t, record)
	case:
		t.root = record
	}
	out := type_of(t, prog, t.null if opts.null_input else t.root, nil)
	t.d.root = out
	return {t.d^, t.refusals[:]}
}

// A record of a table, as `check --schema` reads a table: an element of the array the description's root
// describes. It is an object of the members the root's `items` list, each a cell, required where every row object
// requires it. Where a row object leaves its other members undescribed, the record does too. Where a schema takes
// them, or a row may be anything, the record takes any other member as a cell. Under `no_header` a record is an
// array of cells. A root that takes no array describes no table, and so no record.
@(private = "file")
cells_record :: proc(t: ^Typer) -> Ty {
	cell := kinds_node(t, {.String, .Null} + ({.Number, .Bool} if t.input.infer else {}))
	if t.input.no_header {
		return array_of(t, cell)
	}
	members := make([dynamic]rules.Member, context.temp_allocator)
	required := make(map[string]int, context.temp_allocator)
	listed := make(map[string]struct{}, context.temp_allocator)
	tables := branches(t, t.d.root)
	open, undescribed, described, objects := !tables.complete, false, false, 0
	for table in tables.of {
		if .Array not_in branch_kinds(t, table[:]) {
			continue
		}
		described = true
		items := false
		for id in table {
			n := &t.d.nodes[id]
			if n.array < 0 || t.d.arrays[n.array].items == rules.NONE {
				continue
			}
			items = true
			split := branches(t, t.d.arrays[n.array].items)
			open ||= !split.complete
			for b in split.of {
				for row in b {
					r := &t.d.nodes[row]
					if r.object < 0 {
						continue
					}
					o := &t.d.objects[r.object]
					objects += 1
					for m in o.members {
						if m.required {
							required[m.name] += 1
						}
						if !m.only_required && m.name not_in listed {
							listed[m.name] = {}
							append(&members, rules.Member{name = m.name, node = cell})
						}
					}
					undescribed ||= o.additional == rules.NONE
					open ||= len(o.patterns) > 0 || o.additional != rules.NONE && t.d.nodes[o.additional].kinds != {}
				}
			}
		}
		open ||= !items
	}
	if !described {
		return t.never
	}
	for &m in members {
		m.required = !open && required[m.name] == objects
	}
	return object_of(t, members[:], cell if open || len(members) == 0 else rules.NONE if undescribed else t.never)
}

// ---- Nodes

// A node of `kinds` and no rule, in the input's root resource.
@(private)
blank :: proc(t: ^Typer, kinds: rules.Kinds) -> rules.Node {
	return {kinds = kinds, array = -1, object = -1, resource = t.resource}
}

@(private)
made :: proc(t: ^Typer, n: rules.Node) -> Ty {
	t.steps += 1
	if t.steps > TYPE_STEPS {
		return t.unknown
	}
	append(&t.d.nodes, n)
	return Ty(len(t.d.nodes) - 1)
}

// The node of `kinds` and no rule, made once per set. `Number` includes the integers, and is written without them.
@(private)
kinds_node :: proc(t: ^Typer, of: rules.Kinds) -> Ty {
	kinds := closure(of)
	key := message.build_temp("k%d", transmute(u8)kinds)
	if id, found := t.memo[key]; found {
		return id
	}
	id := made(t, blank(t, kinds if kinds == rules.EVERY_KIND else kinds - {.Integer} if .Number in kinds else kinds))
	if id != t.unknown {
		t.plain[id] = kinds
		t.memo[strings.clone(key)] = id
	}
	return id
}

// The node `key` names in `t.memo`, or else a new one made of `n` and kept under `key`.
@(private)
memoized :: proc(t: ^Typer, key: string, n: rules.Node) -> Ty {
	if id, found := t.memo[key]; found {
		return id
	}
	id := made(t, n)
	if id != t.unknown {
		t.memo[strings.clone(key)] = id
	}
	return id
}

@(private)
array_of :: proc(t: ^Typer, items: Ty) -> Ty {
	key := message.build_temp("a%d", items)
	if id, found := t.memo[key]; found {
		return id
	}
	append(&t.d.arrays, rules.Array{items = items})
	n := blank(t, {.Array})
	n.array = i32(len(t.d.arrays) - 1)
	return memoized(t, key, n)
}

// An object of `members` whose other members pass `additional`: `never` for a closed object.
@(private)
object_of :: proc(t: ^Typer, members: []rules.Member, additional: Ty) -> Ty {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, 'o')
	for m in members {
		message.write(&b, "%q:%d:%d,", m.name, m.node, int(m.required))
	}
	message.write(&b, "%d", additional)
	key := strings.to_string(b)
	if id, found := t.memo[key]; found {
		return id
	}
	append(&t.d.objects, rules.Object{members = slice.clone(members), additional = additional, keys = rules.NONE})
	n := blank(t, {.Object})
	n.object = i32(len(t.d.objects) - 1)
	return memoized(t, key, n)
}

// An array or object whose elements or members the typing does not know.
@(private)
loose :: proc(t: ^Typer, kinds: rules.Kinds) -> Ty {
	parts: [3]Ty = {kinds_node(t, kinds - {.Array, .Object}), t.never, t.never}
	if .Array in kinds {
		parts[1] = array_of(t, t.unknown)
	}
	if .Object in kinds {
		parts[2] = object_of(t, nil, t.unknown)
	}
	return union_of(t, ..parts[:])
}

// The value `v`: a constant for a scalar, an array of its elements' values, an object of exactly its members.
@(private)
value_type :: proc(t: ^Typer, v: Value) -> Ty {
	#partial switch kind(v) {
	case .Null:
		return t.null
	case .Array:
		parts := make([dynamic]Ty, context.temp_allocator)
		it := iterate(v)
		for _, m in next_member(&it) {
			append(&parts, value_type(t, m))
		}
		return array_of(t, union_of(t, ..parts[:]))
	case .Object:
		members := make([dynamic]rules.Member, context.temp_allocator)
		it := iterate(v)
		for k, m in next_member(&it) {
			append(&members, rules.Member{name = k, node = value_type(t, m), required = true})
		}
		return object_of(t, members[:], t.never)
	}
	n := blank(t, value_kinds(v))
	n.const_of = scalar(v)
	return memoized(t, message.build_temp("c%s", to_json(v, allocator = context.temp_allocator)), n)
}

// The kinds of `values`. A whole number counts as an integer.
@(private)
value_kinds :: proc(values: ..Value) -> (k: rules.Kinds) {
	for v in values {
		switch kind(v) {
		case .Null:         k += {.Null}
		case .False, .True: k += {.Bool}
		case .String:       k += {.String}
		case .Array:        k += {.Array}
		case .Object:       k += {.Object}
		case .Number:
			x, _ := number_of(v)
			k += {.Integer} if !math.is_inf(x.f) && x.f == math.trunc(x.f) else {.Number}
		}
	}
	return
}

// Whether `id` is a constant finite number, and whether that constant is not zero.
@(private)
finite :: proc(t: ^Typer, id: Ty) -> (finite, nonzero: bool) {
	c, has := t.d.nodes[id].const_of.?
	if !has || kind(c) != .Number {
		return
	}
	x, _ := number_of(c)
	return !math.is_inf(x.f) && !math.is_nan(x.f), x.f != 0
}

// A string that is one of `names`.
@(private)
names_node :: proc(t: ^Typer, names: []string, note := "") -> Ty {
	n := blank(t, {.String})
	n.description = note
	values := make([]Value, len(names))
	for s, i in names {
		values[i] = s
	}
	if len(values) == 1 {
		n.const_of = values[0]
	} else {
		n.enum_of, n.has_enum = values, true
	}
	return made(t, n)
}

// Any value of `parts`. Equal arms merge, plain kinds join into one, `never` drops out and `unknown` takes the
// rest. The empty array drops out beside an arm that takes it.
@(private)
union_of :: proc(t: ^Typer, parts: ..Ty) -> Ty {
	arms := make([dynamic]Ty, 0, 8, context.temp_allocator)
	kinds: rules.Kinds
	for p in parts {
		if !gather(t, p, &arms, &kinds) {
			return t.unknown
		}
	}
	if kinds != {} {
		append(&arms, kinds_node(t, kinds))
	}
	slice.sort(arms[:])
	kept := slice.unique(arms[:])
	if at, found := slice.linear_search(kept, t.empty); found {
		takes_empty := .Array in kinds
		for arm in kept {
			takes_empty ||= arm != t.empty && takes_empty_array(t, arm)
		}
		if takes_empty {
			kept = slice.concatenate([][]Ty{kept[:at], kept[at + 1:]}, context.temp_allocator)
		}
	}
	switch {
	case len(kept) == 0:
		return t.never
	case len(kept) == 1:
		return kept[0]
	case len(kept) > MAX_ARMS:
		return t.unknown
	}
	key := strings.concatenate({"|", string(slice.to_bytes(kept))}, context.temp_allocator)
	if id, found := t.memo[key]; found {
		return id
	}
	n := blank(t, rules.EVERY_KIND)
	n.any_of = slice.clone(kept)
	id := memoized(t, key, n)
	if id != t.unknown {
		t.unions[id] = n.any_of
	}
	return id
}

// Whether `[]` passes `id` by its own keywords, where `id` applies no other schema in place.
@(private = "file")
takes_empty_array :: proc(t: ^Typer, id: Ty) -> bool {
	n := &t.d.nodes[id]
	if .Array not_in n.kinds || n.rules.min_items > 0 || n.const_of != nil || n.has_enum || n.not != nil {
		return false
	}
	if n.array >= 0 && t.d.arrays[n.array].contains != nil {
		return false
	}
	return len(n.any_of) + len(n.all_of) + len(n.one_of) == 0 && n.ref == nil && n.dynamic_ref == nil && n.cond.test == nil
}

@(private = "file")
gather :: proc(t: ^Typer, id: Ty, arms: ^[dynamic]Ty, kinds: ^rules.Kinds) -> bool {
	switch {
	case id == t.unknown:
		return false
	case t.d.nodes[id].kinds == {}:
	case id in t.unions:
		for arm in t.unions[id] {
			gather(t, arm, arms, kinds) or_return
		}
	case id in t.plain:
		kinds^ += t.plain[id]
	case:
		append(arms, id)
	}
	return true
}

// A value that passes every one of `parts`. `unknown` adds nothing beside other parts, and alone gives unknown.
@(private)
all_of :: proc(t: ^Typer, parts: []Ty) -> Ty {
	kept := make([dynamic]Ty, 0, len(parts), context.temp_allocator)
	unknown := false
	for p in parts {
		switch {
		case p == t.unknown:
			unknown = true
		case t.d.nodes[p].kinds == {}:
			return t.never
		case p != t.any && !slice.contains(kept[:], p):
			append(&kept, p)
		}
	}
	switch len(kept) {
	case 0:
		return t.unknown if unknown else t.any
	case 1:
		return kept[0]
	}
	slice.sort(kept[:])
	key := strings.concatenate({"&", string(slice.to_bytes(kept[:]))}, context.temp_allocator)
	n := blank(t, rules.EVERY_KIND)
	n.all_of = slice.clone(kept[:])
	return memoized(t, key, n)
}

// The values of `id` that are of `kinds`, a union narrowed arm by arm. They keep the rules `id` has.
@(private)
restrict :: proc(t: ^Typer, id: Ty, kinds: rules.Kinds) -> Ty {
	if arms, is_union := t.unions[id]; is_union {
		kept := make([dynamic]Ty, 0, len(arms), context.temp_allocator)
		for arm in arms {
			append(&kept, restrict(t, arm, kinds))
		}
		return union_of(t, ..kept[:])
	}
	have, unknown := kinds_of(t, id)
	switch {
	case unknown:
		return loose(t, kinds)
	case have <= closure(kinds):
		return id
	case have & closure(kinds) == {}:
		return t.never
	}
	return all_of(t, {id, kinds_node(t, kinds)})
}

// `kinds` with the integers that `Number` takes.
@(private)
closure :: proc(kinds: rules.Kinds) -> rules.Kinds {
	return kinds + {.Integer} if .Number in kinds else kinds
}

// ---- Reading a description

// The conjunctions that `id` alternates between (`rules.branches`), split once per node.
@(private)
branches :: proc(t: ^Typer, id: Ty) -> Branches {
	if s, found := t.split[id]; found {
		return s
	}
	of, complete := rules.branches(t.d, {id}, true, MAX_ARMS, context.allocator)
	for b in of {
		t.steps += len(b)
	}
	t.split[id] = {of, complete}
	return {of, complete}
}

// The kinds a conjunction takes, narrowed by its `enum` and `const`.
@(private)
branch_kinds :: proc(t: ^Typer, b: []Ty) -> rules.Kinds {
	k := rules.kinds_of(t.d, b)
	for id in b {
		n := &t.d.nodes[id]
		if c, has := n.const_of.?; has {
			k &= closure(value_kinds(c))
		}
		if n.has_enum {
			k &= closure(value_kinds(..n.enum_of))
		}
	}
	return k
}

// The kinds a value of `id` may have, and whether the typing does not know it.
@(private)
kinds_of :: proc(t: ^Typer, id: Ty) -> (k: rules.Kinds, unknown: bool) {
	split := branches(t, id)
	if !split.complete {
		return rules.EVERY_KIND, true
	}
	for b in split.of {
		if slice.contains(b[:], t.unknown) {
			return rules.EVERY_KIND, true
		}
		k += branch_kinds(t, b[:])
	}
	return
}

// What a step finds in a value. `value` is what it reads where it reads something. `absent` and `nulls` say whether
// it may find nothing or a null instead, `holds` whether a value of the kind it reads may be there, and `described`
// whether the description says what it reads. `others` are the other kinds it may meet, `unknown` says the typing
// does not know the value, and `names` are the members the description names, for a suggestion.
@(private)
Read :: struct {
	value:                  Ty,
	unknown, absent, nulls: bool,
	holds, described:       bool,
	others:                 rules.Kinds,
	names:                  [dynamic]string,
}

@(private)
Reading :: enum {
	Member,  // `.[name]` of an object
	Element, // `.[at]` of an array, or under a negative `at` what `.[]` reads from one
	Values,  // `.[]` of an object
}

// What a step reads from a value of `id`. A branch that lists no member, no pattern and no rule on the others
// describes every member.
@(private)
read :: proc(t: ^Typer, id: Ty, how: Reading, name := "", at := -1) -> (r: Read) {
	t.steps += 1
	split := branches(t, id)
	if !split.complete || t.steps > TYPE_STEPS {
		return {value = t.unknown, unknown = true, holds = true, described = true}
	}
	holder: rules.Kinds = {.Array} if how == .Element else {.Object}
	values := make([dynamic]Ty, context.temp_allocator)
	r.names = make([dynamic]string, context.temp_allocator)
	for b in split.of {
		if slice.contains(b[:], t.unknown) {
			return {value = t.unknown, unknown = true, holds = true, described = true}
		}
		k := branch_kinds(t, b[:])
		r.nulls ||= .Null in k
		r.others += k - holder - {.Null}
		if k & holder == {} {
			continue
		}
		r.holds = true
		conj := make([dynamic]Ty, context.temp_allocator)
		required := how == .Values || how == .Element && at < 0
		listed, described := false, false
		for node in b {
			n := &t.d.nodes[node]
			switch how {
			case .Member:
				constant_member(t, n, name, &conj, &listed, &described)
				evaluated := false
				if n.object >= 0 {
					// An object the filter builds is not a description of what may be there.
					described ||= int(n.object) >= t.input_objects
					evaluated = member(t, &t.d.objects[n.object], name, &conj, &r, &required, &listed, &described)
				}
				if u, has := n.unevaluated_properties.?; has {
					listed = true
					described ||= t.d.nodes[u].kinds != {}
					// A node that applies no other schema in place evaluates only the members its own object does.
					if !evaluated && !applies_in_place(t, n) {
						append(&conj, u)
					}
				}
			case .Element:
				if n.array < 0 {
					continue
				}
				a := &t.d.arrays[n.array]
				items := t.any if a.items == rules.NONE else a.items
				switch {
				case at >= 0 && at < len(a.prefix):
					append(&conj, a.prefix[at])
				case at >= 0:
					append(&conj, items)
				case:
					parts := make([dynamic]Ty, context.temp_allocator)
					append(&parts, ..a.prefix)
					append(&parts, items)
					append(&conj, union_of(t, ..parts[:]))
				}
			case .Values:
				if n.object < 0 {
					continue
				}
				o := &t.d.objects[n.object]
				parts := make([dynamic]Ty, context.temp_allocator)
				for &m in o.members {
					if !m.only_required {
						append(&parts, member_node(t, &m))
					}
				}
				for p in o.patterns {
					append(&parts, p.node)
				}
				append(&parts, t.any if o.additional == rules.NONE else o.additional)
				append(&conj, union_of(t, ..parts[:]))
			}
		}
		v := all_of(t, conj[:])
		if v == t.never {
			r.absent = true
			continue
		}
		r.described ||= described || !listed
		r.absent ||= !required
		append(&values, v)
	}
	r.value = union_of(t, ..values[:])
	return
}

// What one object of a conjunction says of its member `name`, and whether it evaluates the member.
@(private = "file")
member :: proc(t: ^Typer, o: ^rules.Object, name: string, conj: ^[dynamic]Ty, r: ^Read, required, listed, described: ^bool) -> (evaluated: bool) {
	named, matched := false, false
	for &m in o.members {
		if m.only_required {
			required^ ||= m.name == name
			continue
		}
		listed^ = true
		append(&r.names, m.name)
		if m.name == name {
			named, required^ = true, required^ || m.required
			append(conj, member_node(t, &m))
		}
	}
	for p in o.patterns {
		listed^ = true
		if matches(t, p.expression, name) {
			matched = true
			append(conj, p.node)
		}
	}
	if !named && !matched && o.additional != rules.NONE {
		listed^ = true
		append(conj, o.additional)
		described^ ||= t.d.nodes[o.additional].kinds != {}
	}
	described^ ||= named || matched
	// A dependent schema applies when its member is present, so the members it describes may be present.
	for x in o.dependents {
		dependent, has := x.node.?
		if !has || described^ {
			continue
		}
		if t.nesting >= MAX_NESTING {
			described^ = true
			continue
		}
		t.nesting += 1
		described^ ||= read(t, dependent, .Member, name).described
		t.nesting -= 1
	}
	return named || matched || o.additional != rules.NONE
}

// Whether `n` applies a schema in place beside its own keywords. That schema may evaluate members its object does not.
@(private = "file")
applies_in_place :: proc(t: ^Typer, n: ^rules.Node) -> bool {
	dependents := n.object >= 0 && len(t.d.objects[n.object].dependents) > 0
	return len(n.all_of) + len(n.any_of) + len(n.one_of) > 0 || n.ref != nil || n.dynamic_ref != nil || n.cond.test != nil || dependents
}

// What a node's `const` or `enum` of objects says of the member `name`: the values they hold for it.
@(private = "file")
constant_member :: proc(t: ^Typer, n: ^rules.Node, name: string, conj: ^[dynamic]Ty, listed, described: ^bool) {
	one: [1]Value
	values: []Value
	if n.has_enum {
		values = n.enum_of
	}
	if c, has := n.const_of.?; has {
		one[0] = c
		values = one[:]
	}
	parts := make([dynamic]Ty, context.temp_allocator)
	objects := false
	for v in values {
		if kind(v) != .Object {
			continue
		}
		objects = true
		it := iterate(v)
		for k, m in next_member(&it) {
			if k == name {
				append(&parts, value_type(t, m))
			}
		}
	}
	if objects {
		listed^ = true
		described^ ||= len(parts) > 0
		append(conj, union_of(t, ..parts[:]))
	}
}

// The node of a member with the rules the member adds, made once per member.
@(private = "file")
member_node :: proc(t: ^Typer, m: ^rules.Member) -> Ty {
	if m.rules == {} {
		return m.node
	}
	n := t.d.nodes[m.node]
	merged, clash := rules.merged(&n, m.rules)
	if clash != "" {
		return m.node
	}
	n.rules = merged
	return memoized(t, message.build_temp("m%d", uintptr(m)), n)
}

// Whether the ECMA pattern `expression` finds a match in `name`. A pattern that does not compile matches, since
// that can only take more values.
@(private = "file")
matches :: proc(t: ^Typer, expression, name: string) -> bool {
	re, compile_err := rules.program_of(&t.patterns, expression, context.allocator)
	if compile_err != "" {
		return true
	}
	found, err := regex.search((^regex.Regex)(re), name, 0, nil, &t.scratch)
	return found || err != ""
}

// What `.[]` reads from an array.
@(private)
items_of :: proc(t: ^Typer, id: Ty) -> Ty {
	return read(t, id, .Element).value
}

// What `.[]` reads from an array or an object.
@(private)
read_iterated :: proc(t: ^Typer, id: Ty) -> (r: Read) {
	e, v := read(t, id, .Element), read(t, id, .Values)
	r = e
	r.value = union_of(t, e.value, v.value)
	r.holds ||= v.holds
	r.others = (e.others & v.others) - {.Object, .Array}
	return
}

// ---- Refusals

// Tells a refusal at `at`, or at the call of the prelude definition it is in, once per place. Nothing is told inside
// a fixpoint's rounds.
@(private)
refuse :: proc(t: ^Typer, at: Loc, format: string, args: ..any) {
	loc := t.site.loc if t.site != nil else at
	if t.held > 0 || loc in t.told {
		return
	}
	t.told[loc] = {}
	append(&t.refusals, Compile_Error{msg = message.build(format, ..args), loc = loc})
}

// The kinds as jq's `type` names them, joined with "or".
@(private)
kinds_text :: proc(kinds: rules.Kinds) -> string {
	b := strings.builder_make(context.temp_allocator)
	for k in JQ_KINDS {
		if k.kinds & kinds != {} {
			if strings.builder_len(b) > 0 {
				strings.write_string(&b, " or ")
			}
			strings.write_string(&b, k.name)
		}
	}
	return strings.to_string(b)
}

// jq's names of the kinds, in the order jq sorts them.
@(private, rodata)
JQ_KINDS := [?]struct {
	name:  string,
	kinds: rules.Kinds,
} {{"null", {.Null}}, {"boolean", {.Bool}}, {"number", {.Integer, .Number}}, {"string", {.String}}, {"array", {.Array}}, {"object", {.Object}}}
