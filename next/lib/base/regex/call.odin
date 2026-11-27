#+private
package regex

// Subexpression calls \g<...> as Oniguruma tunes them before it compiles, each resolved to its group by the
// parser: the groups a call reaches (tune_call2), the groups whose body reaches themselves
// through calls (recursive_call_check_trav), and a recursion that never ends, in a group every path of
// which calls it again, or calls it before reading a byte (infinite_recursive_call_check_trav).

@(private = "file")
Rec_Flag :: enum u8 { Exist, Must, Infinite }
@(private = "file")
Rec :: bit_set[Rec_Flag; u8]

@(private = "file")
Group_Flag :: enum u8 { Mark1, Mark2, Measured, Empty } // MARK1/MARK2, FIXED_MIN measured and empty

@(private = "file")
Calls :: struct {
	groups:    []^Node,
	called:    []bool,
	recursive: []bool,
	state:     []bit_set[Group_Flag; u8],
}

// Fills `called` and `recursive` by group number for the calls in `root`, each resolved to its group in `groups` by
// the parser, or Oniguruma's message.
check_calls :: proc(root: ^Node, groups: []^Node, called, recursive: []bool) -> string {
	r := Calls {
		groups    = groups,
		called    = called,
		recursive = recursive,
		state     = make([]bit_set[Group_Flag; u8], len(groups)),
	}
	if gate_failed(context.allocator) {
		return MEMORY_ERROR
	}
	reach(&r, root, true)
	return "never ending recursion" if find_recursion(&r, root, false) else ""
}

// Marks the groups a call reaches, from the pattern outside repeats of none (`top`) and from the groups they
// call, whatever those hold.
@(private = "file")
reach :: proc(r: ^Calls, n: ^Node, top: bool) {
	if top && n.kind == .Repeat && n.max == 0 {
		return
	}
	if n.kind == .Call && !r.called[n.target.group] {
		r.called[n.target.group] = true
		reach(r, n.target, false)
	}
	for k in n.kids {
		reach(r, k, top)
	}
}

// Marks the groups whose body reaches themselves, in the pattern's order, and whether a called one of them
// never ends.
@(private = "file")
find_recursion :: proc(r: ^Calls, n: ^Node, in_recursion: bool) -> (never_ends: bool) {
	in_recursion := in_recursion
	if n.kind == .Group {
		g := n.group
		r.state[g] += {.Mark1}
		if (r.called[g] || in_recursion) && !r.recursive[g] {
			r.recursive[g] = .Exist in recursion_of(r, n.kids[0], false, true)
		}
		never_ends = r.recursive[g] && r.called[g] && recursion_of(r, n.kids[0], true) & {.Must, .Infinite} != {}
		r.state[g] -= {.Mark1}
		in_recursion ||= r.recursive[g]
	}
	for k in n.kids {
		never_ends = never_ends || find_recursion(r, k, in_recursion)
	}
	return
}

// How `n` reaches the group marked Mark1: Exist on some path, Must on every path, Infinite before a byte is
// read (`head`). A repeat of none reaches nothing, but `in_none` for whether a group's body calls itself.
@(private = "file")
recursion_of :: proc(r: ^Calls, n: ^Node, head: bool, in_none := false) -> Rec {
	#partial switch n.kind {
	case .Cat:
		head := head
		out: Rec
		for k in n.kids {
			ret := recursion_of(r, k, head, in_none)
			if .Infinite in ret {
				return ret
			}
			out += ret
			head &&= can_be_empty(k, r)
		}
		return out
	case .Alt, .Cond:
		out, must := Rec{}, Rec{.Must}
		for k in n.kids {
			ret := recursion_of(r, k, head, in_none)
			if .Infinite in ret {
				return ret
			}
			out += ret & {.Exist}
			must &= ret
		}
		return out | must
	case .Repeat:
		if n.max == 0 && !in_none {
			return {}
		}
		ret := recursion_of(r, n.kids[0], head, in_none)
		return ret - {.Must} if n.min == 0 else ret
	case .Look:
		return recursion_of(r, n.kids[0], head, in_none)
	case .Call:
		return recursion_of(r, n.target, head, in_none)
	case .Group:
		g := n.group
		if .Mark2 in r.state[g] {
			return {}
		}
		if .Mark1 in r.state[g] {
			return {.Exist, .Must, .Infinite} if head else {.Exist, .Must}
		}
		r.state[g] += {.Mark2}
		ret := recursion_of(r, n.kids[0], head, in_none)
		r.state[g] -= {.Mark2}
		return ret
	case .Absent:
		// Oniguruma looks for the absent in a repeat that may stop at once, and runs exp after it.
		if len(n.kids) == 0 {
			return {}
		}
		out := recursion_of(r, n.kids[0], head, in_none)
		if .Infinite in out || len(n.kids) == 1 {
			return out - {.Must}
		}
		ret := recursion_of(r, n.kids[1], head, in_none)
		return ret if .Infinite in ret else (out - {.Must}) | ret
	}
	return {}
}

// Whether `n` can match without a byte. With `r`, as Oniguruma's node_min_byte_len counts while it checks
// recursion: an atomic group by its body, and a backreference or call by its groups, where a group being
// checked, or within its own count, counts none, and a group's count is kept once made. Without, a
// look-around, backreference or call may.
can_be_empty :: proc(n: ^Node, r: ^Calls = nil) -> bool {
	switch n.kind {
	case .Empty, .Assert, .Keep:
		return true
	case .Char, .Str, .Any, .Class, .Linebreak, .Grapheme:
		return false
	case .Look:
		return r == nil || n.look != .Atomic || can_be_empty(n.kids[0], r)
	case .Cat:
		all := true
		for k in n.kids {
			all = can_be_empty(k, r) && all // each one, for the counts `r` keeps
		}
		return all
	case .Alt, .Cond:
		any := false
		for k in n.kids {
			any = can_be_empty(k, r) || any
		}
		return any
	case .Group:
		return group_empty(r, n) if r != nil else can_be_empty(n.kids[0])
	case .Repeat:
		return n.min == 0 || can_be_empty(n.kids[0], r)
	case .Backref:
		if r == nil || n.recursion {
			return true
		}
		any := false
		for g in n.refs {
			any = group_empty(r, r.groups[g]) || any
		}
		return any
	case .Call:
		return r == nil || group_empty(r, n.target)
	case .Absent:
		return len(n.kids) < 2 || can_be_empty(n.kids[1], r)
	}
	return true
}

@(private = "file")
group_empty :: proc(r: ^Calls, n: ^Node) -> bool {
	g := n.group
	if .Measured in r.state[g] {
		return .Empty in r.state[g]
	}
	if .Mark1 in r.state[g] {
		return true
	}
	r.state[g] += {.Mark1}
	empty := can_be_empty(n.kids[0], r)
	r.state[g] -= {.Mark1}
	r.state[g] += {.Measured, .Empty} if empty else {.Measured}
	return empty
}
