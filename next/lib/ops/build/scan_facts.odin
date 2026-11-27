package build

import "stury:lib/core/hook"
import "stury:lib/core/tape"

// Fact (comment, tag, attribute, instruction, doctype, directive) tracking for `Scanner` when `Demand.facts` is set.

// With `facts`, keeps comment or tag `t` as a fact of a node the scan keeps. A comment or a tag before a token goes to
// the node that token is stored at, an inline comment to the value before it unless the walk passed that value
// unstored, and a foot to the open container. `.Stop` when memory for the facts is refused.
// `#no_bounds_check` invariant: when `builder_fact` returns `.Next`, it just appended an entry so `len(h.b.doc.facts) >= 1`.
@(private, cold)
scan_fact :: #force_no_inline proc "contextless" (h: ^Scanner, s: hook.Regs, t: tape.Token) -> hook.Action #no_bounds_check {
	#partial switch tape.fact_kind(t.role) {
	case .Comment_Foot, .Instruction_Foot:
		// A foot after a key is a markup element's with no child element, which marks the value as a comment does. After
		// a key no step took, it waits as a comment does, and it lies inside the value's span, as no container's foot
		// lies inside the value that follows it.
		if !h.has_key {
			at := builder_cursor(&h.b, s)
			if h.wait_at != at {
				h.wait_at, h.wait_from = at, len(h.b.doc.facts)
			}
			break
		}
		fallthrough
	case .Comment, .Tag, .Anchor, .Alias, .Attribute, .Instruction, .Doctype:
		// After a key, the token is its value, stored past the key's node.
		at := builder_cursor(&h.b, s)
		if h.wait_at != at {
			h.wait_at, h.wait_from = at, len(h.b.doc.facts)
		}
		a := builder_fact(&h.b, s.a, s.b, t)
		if a == .Next {
			h.b.doc.facts[len(h.b.doc.facts) - 1].node = at + tape.Node_Index(h.has_key)
		}
		return a
	case .Comment_Inline:
		if h.passed == builder_cursor(&h.b, s) {
			return .Next
		}
	case .Directive:
	case:
		return .Next
	}
	return builder_fact(&h.b, s.a, s.b, t)
}

// Drops the facts before the token at `lo` the walk passed unstored, and the feet inside its span.
// `#no_bounds_check` invariant: `h.wait_from <= len(h.b.doc.facts)` (facts only grow until `scan_check_facts`).
@(private, cold)
scan_unwait :: #force_no_inline proc "contextless" (h: ^Scanner, lo: u64) #no_bounds_check {
	for &f in h.b.doc.facts[h.wait_from:] {
		#partial switch f.kind {
		case .Comment, .Tag, .Anchor, .Alias, .Attribute, .Instruction, .Doctype:
			f.node = tape.NO_NODE
		case .Comment_Foot, .Instruction_Foot:
			if f.lo >= lo {
				f.node = tape.NO_NODE
			}
		}
	}
	h.wait_at = tape.NO_NODE
}

// Drops the comments whose node the scan did not keep, such as one before a token never read or a foot of a root not
// kept.
@(private, cold)
scan_check_facts :: proc "contextless" (h: ^Scanner, regs: hook.Regs) #no_bounds_check {
	nodes := h.b.doc.nodes[:builder_cursor(&h.b, regs)]
	facts := h.b.doc.facts
	kept := 0
	h.b.doc.present = {}
	// A fact past every node of a scan that read the whole text lies past the root, which the build gives the root.
	past := len(nodes) + 1 if .Stopped not_in h.flags && h.end_of != .Settled else len(nodes)
	for f in facts {
		if int(f.node) < past {
			facts[kept] = f
			kept += 1
			if f.kind != .Comment {
				h.b.doc.present += {f.kind}
			}
		}
	}
	h.b.doc.facts = facts[:kept]
}
