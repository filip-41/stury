package regex

// What the parser checks once the whole pattern is read: callout tags, named and numbered references, and calls.

import "core:slice"
import "core:strings"

// Each tag a MAX or CMP reads, which a callout anywhere in the pattern must have.
@(private)
resolve_tags :: proc(p: ^Parser) {
	for c in p.callouts {
		for &o in c.sides {
			if o.tag == "" {
				continue
			}
			if !slice.contains(p.tags[:], o.tag) {
				fail(p, "invalid callout tag name")
				return
			}
			for d in p.callouts {
				if d.tag == o.tag && (d.kind == .Count || d.kind == .Total_Count || d.kind == .Max) {
					o.ref = d
				}
			}
		}
	}
}

// A named reference's groups: those of its name so far, as Oniguruma looks a name up where it meets it.
@(private)
resolve_name :: proc(p: ^Parser, n: ^Node) -> bool {
	for name, g in p.names {
		if g > 0 && name == n.name {
			if n.kind == .Cond {
				n.group = g
			} else {
				append(&n.refs, g)
			}
		}
	}
	if len(n.refs) == 0 && n.group == 0 {
		fail(p, strings.concatenate({"undefined name <", n.name, "> reference"}))
		return false
	}
	return true
}

// A backreference or condition, checked once every group is known (`resolve_refs`). A backreference within a
// group it names is marked, as Oniguruma's parser marks one to a group not yet closed.
@(private)
add_ref :: proc(p: ^Parser, n: ^Node) {
	for g in n.refs {
		n.recursion ||= slice.contains(p.open[:], g)
	}
	append(&p.refs, n)
}

// Numbered backreferences and conditions may name groups that come later, so they are checked at the end,
// and the groups they read marked.
@(private)
resolve_refs :: proc(p: ^Parser, referenced: []bool) {
	for n in p.refs {
		if n.name != "" {
			continue
		}
		g := n.group if n.kind == .Cond else n.refs[0]
		if g <= 0 || g >= len(p.names) {
			fail(p, "invalid backref number/name")
			return
		}
	}
	for n in p.refs {
		if n.kind == .Cond {
			referenced[n.group] = true
		}
		for g in n.refs {
			referenced[g] = true
		}
	}
}

// Each call's group (check_call_reference). A call of the whole pattern puts it under a group 0 of its own.
@(private)
resolve_calls :: proc(p: ^Parser) {
	for n in p.calls {
		g := n.group
		if g < 0 {
			for name, k in p.names {
				if k > 0 && name == n.name {
					if g >= 0 {
						fail(p, strings.concatenate({"multiplex definition name <", n.name, "> call"}))
						return
					}
					g = k
				}
			}
			if g < 0 {
				fail(p, strings.concatenate({"undefined name <", n.name, "> reference"}))
				return
			}
		} else if g >= len(p.names) {
			fail(p, strings.concatenate({"undefined group <", n.name, "> reference"}))
			return
		}
		if g == 0 && p.groups[0] == nil {
			p.groups[0] = new_node(.Group)
		}
		n.target = p.groups[g]
	}
}
