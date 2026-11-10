package jq

// The builtins, typed (types.odin). What the prelude defines in jq is typed through its definition.

import "core:slice"
import "../../../core/rules"

// What a call of a builtin gives on `dot`, and whether `n` calls one. A builtin of a fixed input refuses an input of no
// kind it takes, and the table (`Builtin`) types what it can.
@(private)
builtin_type :: proc(t: ^Typer, n: ^Node, dot: Ty, f: ^Frame) -> (Ty, bool) {
	b, native := n.native.?
	if !native {
		return 0, false
	}
	arg :: proc(t: ^Typer, n: ^Node, i: int, dot: Ty, f: ^Frame) -> Ty {
		return type_of(t, n.args[i], dot, f)
	}
	kinds :: kinds_node
	arity := len(n.args)
	k, unknown := kinds_of(t, dot)
	if b.takes != {} && !unknown && k != {} && k & closure(b.takes) == {} {
		kind_refusal(t, n, "%s/%d takes %s, not %s", n.name, arity, kinds_text(b.takes), kinds_text(k))
	}
	switch n.name {
	case "select":
		arg(t, n, 0, dot, f)
		if kept, test := type_test(n.args[0]); test {
			return restrict(t, dot, kept), true
		}
		return dot, true
	case "type":
		return type_names(t, dot), true
	case "length":
		if !unknown && k - {.Bool} == {} {
			kind_refusal(t, n, "%s has no length", kinds_text(k))
		}
		return kinds(t, {.Integer} if k & closure({.Number}) == {} else {.Number}), true
	case "path":
		t.soft += 1
		arg(t, n, 0, dot, f)
		t.soft -= 1
		return array_of(t, kinds(t, {.String, .Integer})), true
	case "sub", "gsub":
		// The replacement reads each match's captures.
		for a, i in n.args {
			type_of(t, a, loose(t, {.Object}) if i == 1 else dot, f)
		}
		return kinds(t, {.String}), true
	case "range":
		whole := true
		for i in 0 ..< arity {
			ka, ua := kinds_of(t, arg(t, n, i, dot, f))
			whole &&= !ua && ka & closure({.Number}) == {.Integer}
		}
		return kinds(t, {.Integer} if whole else {.Number}), true
	case "add":
		e := read_iterated(t, dot).value
		ke, ue := kinds_of(t, e)
		if ue {
			return t.unknown, true
		}
		sum, _ := arithmetic(t, .Add, e, e, ke, ke)
		return union_of(t, e, sum, t.null), true
	case "sort", "unique":
		return array_of(t, items_of(t, dot)), true
	case "reverse":
		// A value of length 0 reverses to `[]`.
		reversed := array_of(t, items_of(t, dot)) if .Array in k else t.never
		return union_of(t, reversed, kinds(t, {.String}) if .String in k else t.never, t.empty if k - {.Array, .Bool} != {} else t.never), true
	case "sort_by", "group_by", "unique_by", "min_by", "max_by", "min", "max":
		e := items_of(t, dot)
		if arity > 0 {
			arg(t, n, 0, e, f)
		}
		switch n.name {
		case "group_by":
			return array_of(t, array_of(t, e)), true
		case "min_by", "max_by", "min", "max":
			return union_of(t, e, t.null), true
		}
		return array_of(t, e), true
	case "to_entries":
		return array_of(t, entries(t, dot)), true
	case "first", "last", "limit", "skip":
		for i in 0 ..< arity - 1 {
			arg(t, n, i, dot, f)
		}
		return arg(t, n, arity - 1, dot, f), true
	case "recurse":
		s := Step{n = n, f = f}
		return settle(t, dot, &s), true
	case "input", "inputs":
		return t.root, true
	case "getpath":
		// A literal path reads as its steps do, and fails where they would, but on null.
		if p := n.args[0]; p.kind == .Literal && kind(p.value) == .Array {
			at := dot
			for i in 0 ..< length_of(p.value) {
				step := Node{kind = .Literal, value = array_at(p.value, i), loc = p.loc}
				at = index_type(t, &step, at, &step, dot, f)
			}
			return at, true
		}
	case "setpath", "delpaths":
		arg_all(t, n, dot, f)
		if unknown {
			return t.unknown, true
		}
		changed := loose(t, k + {.Array, .Object} if .Null in k || n.name == "setpath" else k)
		// Setting the input's own path replaces the input, and deleting it gives null.
		if n.name == "setpath" && !nonempty(n.args[0]) {
			return union_of(t, changed, arg(t, n, 1, dot, f)), true
		}
		if n.name == "delpaths" && !nonempty_paths(n.args[0]) {
			return union_of(t, changed, t.null), true
		}
		return changed, true
	case "env":
		return object_of(t, nil, kinds(t, {.String})), true
	}
	arg_all(t, n, dot, f)
	switch b.typed {
	case .Kinds:
		return kinds(t, b.gives), true
	case .Kept:
		return restrict(t, dot, b.gives), true
	case .Array:
		return array_of(t, kinds(t, b.gives)), true
	case .Unknown:
	}
	return t.unknown, true
}

// Whether `p` gives only paths that are not empty: a literal of them, or `[e]` with one output of `e`.
@(private = "file")
nonempty :: proc(p: ^Node) -> bool {
	#partial switch p.kind {
	case .Literal:
		return kind(p.value) == .Array && length_of(p.value) > 0
	case .Array:
		return p.a != nil && yields_one(p.a)
	}
	return false
}

// Whether `p` gives arrays of paths that are not empty, as `delpaths` takes them.
@(private = "file")
nonempty_paths :: proc(p: ^Node) -> bool {
	each :: proc(e: ^Node) -> bool {
		return each(e.a) && each(e.b) if e.kind == .Comma else nonempty(e)
	}
	if p.kind == .Array {
		return p.a != nil && each(p.a)
	}
	if p.kind != .Literal || kind(p.value) != .Array {
		return false
	}
	it := iterate(p.value)
	for _, path in next_member(&it) {
		if kind(path) != .Array || length_of(path) == 0 {
			return false
		}
	}
	return true
}

@(private = "file")
arg_all :: proc(t: ^Typer, n: ^Node, dot: Ty, f: ^Frame) {
	for a in n.args {
		type_of(t, a, dot, f)
	}
}

// `{key, value}` for a member of `dot`.
@(private = "file")
entries :: proc(t: ^Typer, dot: Ty) -> Ty {
	members := []rules.Member {
		{name = "key", node = kinds_node(t, {.String, .Integer}), required = true},
		{name = "value", node = read_iterated(t, dot).value, required = true},
	}
	return object_of(t, members, t.never)
}

// What `type` names a value of `dot`: in a format that reads byte strings, a string of `contentEncoding: base64` is
// "bytes".
@(private = "file")
type_names :: proc(t: ^Typer, dot: Ty) -> Ty {
	names: [dynamic]string
	names.allocator = context.temp_allocator
	add :: proc(names: ^[dynamic]string, name: string) {
		for s in names {
			if s == name {
				return
			}
		}
		append(names, name)
	}
	split := branches(t, dot)
	if !split.complete {
		return kinds_node(t, {.String})
	}
	for b in split.of {
		if slice.contains(b[:], t.unknown) {
			return kinds_node(t, {.String})
		}
		k := branch_kinds(t, b[:])
		for kind in JQ_KINDS {
			if kind.kinds & k == {} {
				continue
			}
			if kind.name == "string" && t.input.bytes && encoded(t, b[:]) {
				add(&names, "bytes")
			} else {
				add(&names, kind.name)
			}
		}
	}
	return names_node(t, names[:]) if len(names) > 0 else t.never
}

@(private = "file")
encoded :: proc(t: ^Typer, b: []Ty) -> bool {
	for id in b {
		if t.d.nodes[id].content_encoding == "base64" {
			return true
		}
	}
	return false
}
