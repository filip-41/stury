package diff

import "core:slice"
import "core:strconv"
import "core:strings"
import "stury:lib/core/tape"

// Fact diffing (comments, tags, anchors, attributes) when `Options.facts` is enabled and both documents' formats
// carry a given `tape.Fact_Kind`.

@(private, rodata)
FACT_KINDS := [?]tape.Fact_Kind{.Comment, .Comment_Inline, .Comment_Foot, .Tag, .Anchor, .Attribute}

@(private)
doc_carries :: proc "contextless" (doc: ^tape.Document, kind: tape.Fact_Kind) -> bool {
	return doc.format != nil && kind in doc.format.facts
}

@(private)
spells_facts :: #force_inline proc "contextless" (doc: ^tape.Document) -> bool {
	return doc.format != nil && doc.format.fact_name != nil
}

// Whether neither subtree holds any fact (nor spells any), so equal subtrees have no fact changes to report.
@(private)
quiet :: proc "contextless" (d: ^Differ, a, b: tape.Node_Index) -> bool {
	return !subtree_has_facts(d.docs[0], a) && !subtree_has_facts(d.docs[1], b)
}

@(private)
quiet_val :: proc "contextless" (d: ^Differ, a, b: Val) -> bool {
	if len(a.group) > 0 {
		for n in a.group {
			if subtree_has_facts(d.docs[0], n) {
				return false
			}
		}
	} else if subtree_has_facts(d.docs[0], a.node) {
		return false
	}
	if len(b.group) > 0 {
		for n in b.group {
			if subtree_has_facts(d.docs[1], n) {
				return false
			}
		}
	} else if subtree_has_facts(d.docs[1], b.node) {
		return false
	}
	return true
}

@(private = "file")
subtree_has_facts :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> bool #no_bounds_check {
	if spells_facts(doc) {
		return true
	}
	if len(doc.facts) == 0 {
		return false
	}
	end := tape.node_after(doc, at)
	lo, hi := 0, len(doc.facts)
	for lo < hi {
		mid := (lo + hi) / 2
		if doc.facts[mid].node < at {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo < len(doc.facts) && doc.facts[lo].node < end
}

// Reports each `tape.Fact_Kind` in `FACT_KINDS` whose values differ on nodes `a` and `b`, when both formats carry it.
@(private)
diff_facts :: proc(d: ^Differ, a, b: tape.Node_Index) -> Error {
	da, db := d.docs[0], d.docs[1]
	if len(da.facts) + len(db.facts) == 0 && !spells_facts(da) && !spells_facts(db) {
		return nil
	}
	for kind, i in FACT_KINDS {
		if !d.carries[0][i] || !d.carries[1][i] {
			continue
		}
		old_texts := fact_texts(d, da, a, kind) or_return
		new_texts := fact_texts(d, db, b, kind) or_return
		if !slice.equal(old_texts, new_texts) {
			old_joined := strings.join(old_texts, "\n", d.allocator) or_return
			new_joined := strings.join(new_texts, "\n", d.allocator) or_return
			emit_fact(d, old_joined, new_joined, kind) or_return
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
fact_texts :: proc(d: ^Differ, doc: ^tape.Document, at: tape.Node_Index, kind: tape.Fact_Kind) -> (res: []string, err: Error) {
	out := make([dynamic]string, d.scratch)
	#partial switch kind {
	case .Comment, .Comment_Inline, .Comment_Foot:
		if kind not_in doc.present {
			return nil, nil
		}
		for f in tape.facts_of(doc, at) {
			if f.kind != kind {
				continue
			}
			body := fact_body(doc, f)
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
		if .Tag in doc.present {
			for f in tape.facts_of(doc, at) {
				if f.kind != .Tag {
					continue
				}
				if doc.format != nil && .Binary in doc.format.caps {
					if num, ok := tape.fact_number(doc, f); ok {
						buf: [32]u8
						#partial switch num.kind {
						case .Int:
							s := strconv.write_int(buf[:], i64(num.bits), 10)
							cloned := strings.clone(s, d.scratch) or_return
							append(&out, cloned) or_return
							return out[:], nil
						case .Uint:
							s := strconv.write_uint(buf[:], num.bits, 10)
							cloned := strings.clone(s, d.scratch) or_return
							append(&out, cloned) or_return
							return out[:], nil
						}
					}
				}
				append(&out, fact_body(doc, f)) or_return
				return out[:], nil
			}
		}
		if name, ok := tape.fact_name(doc, at, .Tag); ok {
			append(&out, name) or_return
		}
		return out[:], nil
	case .Anchor:
		if .Anchor not_in doc.present {
			return nil, nil
		}
		for f in tape.facts_of(doc, at) {
			if f.kind == .Anchor {
				append(&out, fact_body(doc, f)) or_return
			}
		}
		return out[:], nil
	case .Attribute:
		if doc.format == nil || doc.format.attribute == nil || .Attribute not_in doc.present {
			return nil, nil
		}
		for f in tape.facts_of(doc, at) {
			if f.kind != .Attribute {
				continue
			}
			kt, vt := doc.format.attribute(doc, f)
			kb, vb: [256]u8
			ks, ko, okk := read_token_text(doc, kt, kb[:], d.scratch)
			vs, vo, okv := read_token_text(doc, vt, vb[:], d.scratch)
			defer {
				if ko != nil {
					delete(ko, d.scratch)
				}
				if vo != nil {
					delete(vo, d.scratch)
				}
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
