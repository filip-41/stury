package diff

import core ".."

// The hash of every node of a document, 0 for one not computed yet, and which fact roles its format carries.
@(private)
Memo :: struct {
	doc:     ^core.Document,
	hashes:  []u64,
	carries: [len(FACT_ROLES)]bool,
}

@(private)
memo_of :: proc(d: ^Differ, doc: ^core.Document) -> int {
	for t, i in d.memos {
		if t.doc == doc {
			return i
		}
	}
	t := Memo {
		doc    = doc,
		hashes = make([]u64, len(doc.nodes), context.temp_allocator),
	}
	for role, i in FACT_ROLES {
		t.carries[i] = carries(doc, role)
	}
	append(&d.memos, t)
	return len(d.memos) - 1
}

@(private = "file")
SEED :: u64(0xcbf29ce484222325)

@(private = "file")
mix :: #force_inline proc(h, x: u64) -> u64 {
	return (h ~ x) * 0x100000001b3
}

// `core.hash` of `v`, which a node of a document computes once from the hashes of its children, so that comparing the
// values at every depth of a walk costs the size of the document once. The composition is `core.hash`'s own.
@(private)
hash_of :: proc(d: ^Differ, v: core.Value) -> u64 {
	r, is_node := core.plain(v).(core.Node_Ref)
	if !is_node || int(r.node) >= len(r.doc.nodes) {
		return core.hash(v)
	}
	at := memo_of(d, r.doc)
	hashes := d.memos[at].hashes
	if h := hashes[r.node]; h != 0 {
		return h
	}
	k := core.kind(r)
	h := core.hash(r)
	#partial switch k {
	case .Array:
		h = mix(SEED, u64(k))
		it := core.children(r)
		for m in core.child_next(&it) {
			h = mix(h, hash_of(d, m))
		}
	case .Object:
		sum: u64
		context.allocator = context.temp_allocator
		for m in core.sorted_members(r) {
			sum += mix(core.hash(m.key), hash_of(d, m.val))
		}
		h = mix(mix(SEED, u64(k)), sum)
	}
	hashes[r.node] = h if h != 0 else 1
	return hashes[r.node]
}

@(private)
equal :: proc(d: ^Differ, a, b: core.Value) -> bool {
	return hash_of(d, a) == hash_of(d, b) && core.equal(a, b)
}
