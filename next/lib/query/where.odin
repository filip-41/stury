package query

import "stury:lib/core/tape"
import "stury:lib/ops/edit"

// Source positions (`where`) for values backed by a `tape.Document`.

// Extracts the `(Doc_Block, Node_Index)` origin of `v` when `v` came from a document
// (`.Node`, `.Overlay` backed by a base node, or `BLOCK_HAS_DOC` `.String`). Rejects `BLOCK_SYNTHETIC` documents unless `allow_synthetic` is true.
@(private)
value_doc_origin :: #force_inline proc "contextless" (v: Value, allow_synthetic := false) -> (d: ^Doc_Block, at: tape.Node_Index, ok: bool) {
	if v.kind == .Node {
		d = (^Doc_Block)(v.p)
		if !allow_synthetic && d.flags & BLOCK_SYNTHETIC != 0 {
			return nil, tape.NO_NODE, false
		}
		return d, tape.Node_Index(v.n), true
	}
	if v.kind == .Overlay {
		ob := (^Overlay_Block)(v.p)
		if ob != nil && ob.doc_block != nil {
			if n, nok := edit.get_node_by_idx(ob.ov, v.n); nok && n.base != tape.NO_NODE {
				d = ob.doc_block
				if !allow_synthetic && d.flags & BLOCK_SYNTHETIC != 0 {
					return nil, tape.NO_NODE, false
				}
				return d, n.base, true
			}
		}
		return nil, tape.NO_NODE, false
	}
	if v.kind == .String && v.held {
		sb := (^Str_Block)(block_of(v))
		if sb != nil && sb.flags & BLOCK_HAS_DOC != 0 {
			d = str_doc_slot(sb)^
			if !allow_synthetic && d.flags & BLOCK_SYNTHETIC != 0 {
				return nil, tape.NO_NODE, false
			}
			return d, tape.Node_Index(sb.node), true
		}
	}
	return nil, tape.NO_NODE, false
}

// Whether `v` carries a source document origin (not synthesized or constructed).
has_doc_origin :: #force_inline proc "contextless" (v: Value) -> bool {
	_, _, ok := value_doc_origin(v)
	return ok
}

// Resolves `v`'s source position via its `Doc_Block.index` lazy line table.
// Returns `ok = false` for synthesized, constructed, or `fromjson` values.
@(require_results)
value_place :: proc(h: ^Heap, v: Value) -> (place: tape.Place, ok: bool) {
	d, at, from_doc := value_doc_origin(v)
	if !from_doc {
		return {}, false
	}
	place = tape.node_place(&d.doc, &d.index, at, heap_allocator(h))
	return place, place.ok
}
