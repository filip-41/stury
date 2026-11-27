package diff

import "core:slice"
import "core:strconv"
import "core:strings"
import "stury:lib/core/tape"

// Fact diffing (comments, tags, anchors, attributes) when `Options.facts` is enabled and both documents' formats
// carry a given `tape.Fact_Kind`.

@(private = "file", rodata)
FACT_KINDS := [?]tape.Fact_Kind{.Comment, .Comment_Inline, .Comment_Foot, .Tag, .Anchor, .Attribute}

@(private = "file")
DIFF_FACT_MASK :: tape.Facts{.Comment, .Comment_Inline, .Comment_Foot, .Tag, .Anchor, .Attribute}

@(private = "file")
spells_facts :: #force_inline proc "contextless" (doc: ^tape.Document) -> bool {
	return doc.format != nil && doc.format.fact_name != nil
}

// Fact kinds both formats carry and at least one document holds (in `present` or spelled via `fact_name`).
@(private, require_results)
init_facts :: proc "contextless" (a, b: ^tape.Document) -> tape.Facts {
	if a.format == nil || b.format == nil {
		return {}
	}
	shared := a.format.facts & b.format.facts & DIFF_FACT_MASK
	present := a.present | b.present
	if .Tag in shared && (spells_facts(a) || spells_facts(b)) {
		present += {.Tag}
	}
	return shared & present
}

// Whether neither subtree holds any active fact (nor spells `.Tag`), so equal subtrees have no fact changes to report.
@(private)
quiet :: proc "contextless" (d: ^Differ, a, b: Val) -> bool {
	if d.active_facts == {} {
		return true
	}
	check_spelled := .Tag in d.active_facts
	for v, side in ([2]Val{a, b}) {
		doc := d.docs[side]
		if check_spelled && spells_facts(doc) {
			return false
		}
		if doc.present & d.active_facts == {} {
			continue
		}
		if len(v.group) > 0 {
			for n in v.group {
				if subtree_has_facts(doc, n) {
					return false
				}
			}
		} else if subtree_has_facts(doc, v.node) {
			return false
		}
	}
	return true
}

// Invariant: `at` is a valid index in `doc.nodes`; `0 <= mid < len(doc.facts)` throughout the search.
@(private = "file")
subtree_has_facts :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> bool #no_bounds_check {
	if len(doc.facts) == 0 {
		return false
	}
	end := tape.node_after(doc, at)
	lo, hi := 0, len(doc.facts)
	for lo < hi {
		mid := lo + (hi - lo) >> 1
		if doc.facts[mid].node < at {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo < len(doc.facts) && doc.facts[lo].node < end
}

// Reports each active `tape.Fact_Kind` whose values differ on nodes `a` and `b`.
@(private)
diff_facts :: proc(d: ^Differ, a, b: tape.Node_Index) -> Error {
	da, db := d.docs[0], d.docs[1]
	check_spelled := .Tag in d.active_facts && (spells_facts(da) || spells_facts(db))
	fa := tape.facts_of(da, a) if len(da.facts) > 0 else nil
	fb := tape.facts_of(db, b) if len(db.facts) > 0 else nil
	if len(fa) == 0 && len(fb) == 0 && !check_spelled {
		return nil
	}
	for kind in FACT_KINDS {
		if kind not_in d.active_facts {
			continue
		}
		old_texts := fact_texts(d, da, a, fa, kind) or_return
		new_texts := fact_texts(d, db, b, fb, kind) or_return
		if !slice.equal(old_texts, new_texts) {
			if d.opts.max_changes > 0 && len(d.changes) >= d.opts.max_changes {
				d.truncated = true
				return nil
			}
			old_joined := strings.join(old_texts, "\n", d.allocator) or_return
			new_joined := strings.join(new_texts, "\n", d.allocator) or_return
			emit(d, {
				op        = .Fact,
				old_node  = tape.NO_NODE,
				new_node  = tape.NO_NODE,
				old_text  = old_joined,
				new_text  = new_joined,
				fact_kind = kind,
			}) or_return
		}
	}
	return nil
}

@(private = "file")
fact_body :: #force_inline proc "contextless" (doc: ^tape.Document, f: tape.Fact) -> string {
	raw := tape.span_bytes(doc, f.lo, f.n)
	lead := min(int(tape.fact_lead(f.spelling)), len(raw))
	tail := min(int(tape.fact_tail(f.spelling)), len(raw) - lead)
	return string(raw[lead : len(raw) - tail])
}

@(private = "file")
fact_texts :: proc(d: ^Differ, doc: ^tape.Document, at: tape.Node_Index, facts: []tape.Fact, kind: tape.Fact_Kind) -> (res: []string, err: Error) {
	out := make([dynamic]string, d.scratch)
	#partial switch kind {
	case .Comment, .Comment_Inline, .Comment_Foot:
		for f in facts {
			if f.kind != kind {
				continue
			}
			body := fact_body(doc, f)
			// Strip one delimiter-adjacent space so `/* x */` and `# x` normalize to `"x"`.
			if tape.fact_lead(f.spelling) > 0 && len(body) > 0 && body[0] == ' ' {
				body = body[1:]
			}
			if tape.fact_tail(f.spelling) > 0 && len(body) > 0 && body[len(body) - 1] == ' ' {
				body = body[:len(body) - 1]
			}
			append(&out, body) or_return
		}
		return out[:], nil
	case .Tag:
		buf: [24]u8 = ---
		for f in facts {
			if f.kind != .Tag {
				continue
			}
			if num, ok := tape.fact_number(doc, f); ok {
				s: string
				#partial switch num.kind {
				case .Int:
					s = strconv.write_int(buf[:], i64(num.bits), 10)
				case .Uint:
					s = strconv.write_uint(buf[:], num.bits, 10)
				}
				if len(s) > 0 {
					cloned := strings.clone(s, d.scratch) or_return
					append(&out, cloned) or_return
					continue
				}
			}
			append(&out, fact_body(doc, f)) or_return
		}
		if len(out) == 0 {
			if name, ok := tape.fact_name(doc, at, .Tag); ok {
				append(&out, name) or_return
			}
		}
		return out[:], nil
	case .Anchor:
		for f in facts {
			if f.kind == .Anchor {
				append(&out, fact_body(doc, f)) or_return
			}
		}
		return out[:], nil
	case .Attribute:
		if doc.format == nil || doc.format.attribute == nil {
			return nil, nil
		}
		kb, vb: [256]u8 = ---, ---
		for f in facts {
			if f.kind != .Attribute {
				continue
			}
			kt, vt := doc.format.attribute(doc, f)
			ks, _, okk := read_token_text(doc, kt, kb[:], d.scratch)
			vs, _, okv := read_token_text(doc, vt, vb[:], d.scratch)
			if d.scratch_gate.failed {
				return nil, .Out_Of_Memory
			}
			if okk && okv {
				pair := strings.concatenate({ks, "=", vs}, d.scratch) or_return
				append(&out, pair) or_return
			}
		}
		slice.sort(out[:])
		return out[:], nil
	}
	return nil, nil
}
