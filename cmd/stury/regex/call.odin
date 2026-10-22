package regex

// Subexpression calls \g<...> as Oniguruma tunes them before it compiles, each resolved to its group by the
// parser: the groups a call reaches (tune_call2), the groups whose body reaches themselves
// through calls (recursive_call_check_trav), and a recursion that never ends, in a group every path of
// which calls it again, or calls it before reading a byte (infinite_recursive_call_check_trav).

@(private = "file")
EXIST: int : 1
@(private = "file")
MUST: int : 2
@(private = "file")
INFINITE: int : 4

Calls :: struct {
	groups:       []^Node,
	called:       []bool,
	recursive:    []bool,
	mark1, mark2: []bool, // Oniguruma's MARK1 (the group being checked) and MARK2 (a group on the way)
	measured:     []bool, // a group's least byte length, as node_min_byte_len caches it (FIXED_MIN)
	empty:        []bool, // that length is 0
}

// Fills `called` and `recursive` by group number for the calls in `root`, each resolved to its group in `groups` by
// the parser, or Oniguruma's message.
check_calls :: proc(root: ^Node, groups: []^Node, called, recursive: []bool) -> string {
	r := Calls {
		groups    = groups,
		called    = called,
		recursive = recursive,
		mark1     = make([]bool, len(groups), context.temp_allocator),
		mark2     = make([]bool, len(groups), context.temp_allocator),
		measured  = make([]bool, len(groups), context.temp_allocator),
		empty     = make([]bool, len(groups), context.temp_allocator),
	}
	reach(&r, root, true)
	find_recursion(&r, root, false)
	return "never ending recursion" if never_ends(&r, root) else ""
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

// Whether `n` reaches the group marked mark1 through calls.
@(private = "file")
reaches_mark1 :: proc(r: ^Calls, n: ^Node) -> bool {
	#partial switch n.kind {
	case .Call:
		return reaches_mark1(r, n.target)
	case .Group:
		g := n.group
		if r.mark2[g] {
			return false
		}
		if r.mark1[g] {
			return true
		}
		r.mark2[g] = true
		found := reaches_mark1(r, n.kids[0])
		r.mark2[g] = false
		return found
	}
	found := false
	for k in n.kids {
		found = reaches_mark1(r, k) || found
	}
	return found
}

@(private = "file")
find_recursion :: proc(r: ^Calls, n: ^Node, in_recursion: bool) {
	in_recursion := in_recursion
	if n.kind == .Group {
		g := n.group
		if (r.called[g] || in_recursion) && !r.recursive[g] {
			r.mark1[g] = true
			r.recursive[g] = reaches_mark1(r, n.kids[0])
			r.mark1[g] = false
		}
		in_recursion ||= r.recursive[g]
	}
	for k in n.kids {
		find_recursion(r, k, in_recursion)
	}
}

@(private = "file")
never_ends :: proc(r: ^Calls, n: ^Node) -> bool {
	if n.kind == .Group && r.recursive[n.group] && r.called[n.group] {
		r.mark1[n.group] = true
		ret := recursion_of(r, n.kids[0], true)
		r.mark1[n.group] = false
		if ret & (MUST | INFINITE) != 0 {
			return true
		}
	}
	for k in n.kids {
		if never_ends(r, k) {
			return true
		}
	}
	return false
}

// How `n` reaches the group marked mark1: EXIST on some path, MUST on every path, INFINITE before a byte is
// read (`head`).
@(private = "file")
recursion_of :: proc(r: ^Calls, n: ^Node, head: bool) -> int {
	#partial switch n.kind {
	case .Cat:
		head := head
		out := 0
		for k in n.kids {
			ret := recursion_of(r, k, head)
			if ret & INFINITE != 0 {
				return ret
			}
			out |= ret
			head &&= can_be_empty(k, r)
		}
		return out
	case .Alt:
		out, must := 0, MUST
		for k in n.kids {
			ret := recursion_of(r, k, head)
			if ret & INFINITE != 0 {
				return ret
			}
			out |= ret & EXIST
			must &= ret
		}
		return out | must
	case .Cond:
		yes := recursion_of(r, n.kids[0], head)
		if yes & INFINITE != 0 {
			return yes
		}
		no := recursion_of(r, n.kids[1], head)
		if no & INFINITE != 0 {
			return no
		}
		return yes | no & EXIST if no & MUST != 0 else (yes | no) & EXIST
	case .Repeat:
		if n.max == 0 {
			return 0
		}
		ret := recursion_of(r, n.kids[0], head)
		return ret & ~MUST if n.min == 0 else ret
	case .Look:
		return recursion_of(r, n.kids[0], head)
	case .Call:
		return recursion_of(r, n.target, head)
	case .Group:
		g := n.group
		if r.mark2[g] {
			return 0
		}
		if r.mark1[g] {
			return EXIST | MUST | INFINITE if head else EXIST | MUST
		}
		r.mark2[g] = true
		ret := recursion_of(r, n.kids[0], head)
		r.mark2[g] = false
		return ret
	case .Absent:
		// Oniguruma looks for the absent in a repeat that may stop at once, and runs exp after it.
		if len(n.kids) == 0 {
			return 0
		}
		out := recursion_of(r, n.kids[0], head)
		if out & INFINITE != 0 || len(n.kids) == 1 {
			return out & ~MUST
		}
		ret := recursion_of(r, n.kids[1], head)
		return ret if ret & INFINITE != 0 else out & ~MUST | ret
	}
	return 0
}

// Whether `n` can match without a byte. With `r`, as Oniguruma's node_min_byte_len counts while it checks
// recursion: an atomic group by its body, and a backreference or call by its groups, where a group being
// checked, or within its own count, counts none, and a group's count is kept once made. Without, a
// look-around, backreference or call may.
can_be_empty :: proc(n: ^Node, r: ^Calls = nil) -> bool {
	switch n.kind {
	case .Empty, .Assert, .Keep:
		return true
	case .Char, .Any, .Class, .Linebreak, .Grapheme:
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
	if r.measured[g] {
		return r.empty[g]
	}
	if r.mark1[g] {
		return true
	}
	r.mark1[g] = true
	empty := can_be_empty(n.kids[0], r)
	r.mark1[g] = false
	r.empty[g], r.measured[g] = empty, true
	return empty
}
