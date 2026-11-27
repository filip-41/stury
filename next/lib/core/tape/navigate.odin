package tape

import "base:intrinsics"

// The readers that step from a node of a document to the values in it, on a whole document and on a path read's
// partial one alike. A partial container answers `.Not_Loaded` for what it cannot settle, so no reader takes a value
// the read left out for one the text lacks. A step follows the rules of step.odin: null has no member and no element,
// so a step into it is `.Missing`, and it has no children to iterate. `.Default` duplicates are the document format's
// policy, and a key of any scalar kind is named by its text.

// A document and an index of its whole containers, nil for none, which the readers work over. Without an index they
// walk the containers. An index fills as the readers read, so a reader is not shared between threads while it has one.
Reader :: struct {
	doc:   ^Document,
	index: ^Doc_Index,
}

// The root value, `.Not_Loaded` for a partial document that kept none.
@(require_results)
root :: proc "contextless" (r: Reader) -> (Node_Index, Presence) {
	if len(r.doc.nodes) == 0 {
		return NO_NODE, .Not_Loaded if r.doc.partial != nil else .Missing
	}
	return ROOT, .Found
}

// Answer `k` of path `path` of a path read, in document order: the value found, the deepest container reached for
// `.Missing`, or the value a step could not enter for `.Wrong_Kind`. False past the path's last answer, and for a
// document no path read made.
@(require_results)
answer :: proc "contextless" (r: Reader, path, k: int) -> (node: Node_Index, p: Presence, ok: bool) #no_bounds_check {
	x := r.doc.partial
	if x == nil || path < 0 || path + 1 >= len(x.starts) {
		return NO_NODE, .Missing, false
	}
	lo, hi := int(x.starts[path]), int(x.starts[path + 1])
	if k < 0 || k >= hi - lo {
		return NO_NODE, .Missing, false
	}
	a := x.answers[lo + k]
	return a.node, a.outcome, true
}

// The value of the member `name` of the object at `at` under `dups`, `.Missing` when the object or null has none and
// `.Wrong_Kind` for any other value. Every reader takes `NO_NODE`, which a miss gives, as a miss and answers
// `.Missing`.
@(require_results)
member :: proc(r: Reader, at: Node_Index, name: string, dups := Duplicates.Default) -> (Node_Index, Presence) #no_bounds_check {
	if at == NO_NODE {
		return NO_NODE, .Missing
	}
	doc := r.doc
	nodes := raw_data(doc.nodes)
	node := nodes[at]
	if node.kind != .Object {
		return NO_NODE, step_refused(node.kind)
	}
	if intrinsics.expect(doc.ext != nil, false) {
		return member_with_ext(r, at, name, dups)
	}
	return member_plain(r, at, node, name, dups)
}

// Fast leaf lookup for an object with no tabular row extension. Every cold helper takes at most 7 register arguments so
// LLVM tail-calls all of them (`b`) and keeps `member` a leaf procedure on the common unescaped-key path.
@(private = "file", require_results)
member_plain :: #force_inline proc(r: Reader, at: Node_Index, node: Node, name: string, dups: Duplicates) -> (Node_Index, Presence) #no_bounds_check {
	#assert(size_of(Token) == 16 && offset_of(Token, n) == 8)
	#assert(offset_of(Token, kind) == 12 && offset_of(Token, role) == 13 && offset_of(Token, spelling) == 14)
	doc := r.doc
	if intrinsics.expect(names_expanded(doc, name), false) {
		return member_expanded(r, at, name, dups)
	}
	if intrinsics.expect(r.index != nil && node.spelling & CONTAINER_PARTIAL == 0 && int(node.spelling & MAX_CHILDREN) > SMALL_OBJECT, false) {
		return member_indexed(r, at, name, dups)
	}
	policy := read_dups(doc.format, dups)
	partial := node.spelling & CONTAINER_PARTIAL != 0
	// An object that holds each key once has its only match at the first, and a group's first member is its own.
	first := policy != .Last || !partial && keys_known_once(r, at)
	if intrinsics.expect(.Held in doc.flags, false) {
		return member_scan_slow(doc, at, at + 1, NO_NODE, name, first)
	}
	nodes := raw_data(doc.nodes)
	src := raw_data(doc.src)
	end := at + Node_Index(node.n)
	name_len := len(name)
	name_p := raw_data(name)
	found := NO_NODE
	for k := at + 1; k < end; {
		kp := &nodes[k]
		key_n: u32
		when ODIN_ENDIAN == .Little {
			// Single 64-bit load of `n` (bits 0..31), `kind` (32..39), `role` (40..47), `spelling` (48..63).
			hdr := (^u64)(uintptr(kp) + 8)^
			kind_dec := hdr & 0x0001_00FF_0000_0000
			if intrinsics.expect(kind_dec != (u64(Kind.String) << 32), false) {
				if kind_dec != (u64(Kind.Plain) << 32) {
					return member_scan_slow(doc, at, k, found, name, first)
				}
			}
			key_n = u32(hdr)
		} else {
			t := kp^
			if intrinsics.expect(u8(t.kind) - u8(Kind.String) <= 1 && t.spelling & SPELLING_DECODE == 0, true) {
				key_n = t.n
			} else {
				return member_scan_slow(doc, at, k, found, name, first)
			}
		}
		if int(key_n) == name_len {
			a := src[kp.lo:]
			if name_len <= 16 {
				if raw_key_eq_short(a, name_p, name_len) {
					if first {
						return k + 1, .Found
					}
					found = k
				}
			} else if intrinsics.unaligned_load((^u64)(a)) == intrinsics.unaligned_load((^u64)(name_p)) &&
				intrinsics.unaligned_load((^u64)(a[name_len - 8:])) == intrinsics.unaligned_load((^u64)(name_p[name_len - 8:])) {
				return member_scan_slow(doc, at, k, found, name, first)
			}
		}
		when ODIN_ENDIAN == .Little {
			vhdr := (^u64)(uintptr(kp) + 24)^
			k += 1 + (Node_Index(u32(vhdr)) if u8(vhdr >> 32) > u8(Kind.Plain) else 1)
		} else {
			v := nodes[k + 1]
			k = k + 1 + (Node_Index(v.n) if v.kind > .Plain else 1)
		}
	}
	if !partial {
		if found != NO_NODE {
			return found + 1, .Found
		}
		return NO_NODE, .Missing
	}
	return member_partial_finish(doc, at, found, name, first)
}

// Inline equality check for two raw byte spans of equal length `n <= 16`.
@(private = "file", require_results)
raw_key_eq_short :: #force_inline proc "contextless" (a, b: [^]u8, n: int) -> bool #no_bounds_check {
	switch {
	case n >= 8:
		return intrinsics.unaligned_load((^u64)(a)) == intrinsics.unaligned_load((^u64)(b)) &&
			intrinsics.unaligned_load((^u64)(a[n - 8:])) == intrinsics.unaligned_load((^u64)(b[n - 8:]))
	case n >= 4:
		return intrinsics.unaligned_load((^u32)(a)) == intrinsics.unaligned_load((^u32)(b)) &&
			intrinsics.unaligned_load((^u32)(a[n - 4:])) == intrinsics.unaligned_load((^u32)(b[n - 4:]))
	case n >= 2:
		return intrinsics.unaligned_load((^u16)(a)) == intrinsics.unaligned_load((^u16)(b)) && a[n - 1] == b[n - 1]
	}
	return n == 0 || a[0] == b[0]
}

@(private = "file", cold, require_results)
member_with_ext :: #force_no_inline proc(r: Reader, at: Node_Index, name: string, dups: Duplicates) -> (Node_Index, Presence) #no_bounds_check {
	if t, row := row_of(r.doc, at); row {
		return row_member(r.doc, t, at, name, row_policy(r.doc, dups))
	}
	return member_plain(r, at, r.doc.nodes[at], name, dups)
}

@(private = "file", cold, require_results)
member_indexed :: #force_no_inline proc(r: Reader, at: Node_Index, name: string, dups: Duplicates) -> (Node_Index, Presence) #no_bounds_check {
	node := r.doc.nodes[at]
	policy := read_dups(r.doc.format, dups)
	// An object whose keys of two kinds may read as one name takes its member by comparing keys, as the finder does.
	if e, ok := object_entry(r, at, child_count(r.doc, at, node)); ok && !e.clash {
		return index_member(r, e, name, policy)
	}
	first := policy != .Last || keys_known_once(r, at)
	return member_scan_slow(r.doc, at, at + 1, NO_NODE, name, first)
}

@(private = "file", cold, require_results)
member_expanded :: #force_no_inline proc "contextless" (r: Reader, at: Node_Index, name: string, dups: Duplicates) -> (Node_Index, Presence) #no_bounds_check {
	doc := r.doc
	node := doc.nodes[at]
	policy := read_dups(doc.format, dups)
	partial := node.spelling & CONTAINER_PARTIAL != 0
	first := policy != .Last || !partial && keys_known_once(r, at)
	found := NO_NODE
	unknown := false
	end := at + Node_Index(node.n)
	for k := at + 1; k < end; k = node_after(doc, k + 1) {
		p := doc.format.expanded(doc, k, name)
		unknown ||= p == .Not_Loaded
		if p == .Found {
			found = k
			if first {
				break
			}
		}
	}
	if found == NO_NODE && unknown {
		return NO_NODE, .Not_Loaded
	}
	if partial {
		return member_partial_finish(doc, at, found, name, first)
	}
	if found != NO_NODE {
		return found + 1, .Found
	}
	return NO_NODE, .Missing
}

@(private = "file", cold, require_results)
member_scan_slow :: #force_no_inline proc "contextless" (doc: ^Document, at, start_k, init_found: Node_Index, name: string, first: bool) -> (Node_Index, Presence) #no_bounds_check {
	node := doc.nodes[at]
	partial := node.spelling & CONTAINER_PARTIAL != 0
	found := init_found
	end := at + Node_Index(node.n)
	for k := start_k; k < end; k = node_after(doc, k + 1) {
		if doc_names(doc, doc.nodes[k], name) {
			found = k
			if first {
				break
			}
		}
	}
	if partial {
		return member_partial_finish(doc, at, found, name, first)
	}
	if found != NO_NODE {
		return found + 1, .Found
	}
	return NO_NODE, .Missing
}

@(private = "file", cold, require_results)
member_partial_finish :: #force_no_inline proc "contextless" (doc: ^Document, at, found: Node_Index, name: string, first: bool) -> (Node_Index, Presence) #no_bounds_check {
	node := doc.nodes[at]
	if found != NO_NODE {
		// When `partial` holds, `first` equals `policy != .Last`.
		if first || doc.partial != nil && doc.partial.dups != .First && child_count(doc, at, node) >= 0 {
			return found + 1, .Found
		}
		return NO_NODE, .Not_Loaded
	}
	if named_missing(doc.partial, at, name) {
		return NO_NODE, .Missing
	}
	return NO_NODE, .Not_Loaded
}

// The element `index` of the array at `at`, negative from the end, `.Missing` past either end of an array and for
// null, and `.Wrong_Kind` for any other value.
@(require_results)
element :: proc(r: Reader, at: Node_Index, index: int) -> (Node_Index, Presence) #no_bounds_check {
	if at == NO_NODE {
		return NO_NODE, .Missing
	}
	doc := r.doc
	node := doc.nodes[at]
	if node.kind != .Array {
		return NO_NODE, step_refused(node.kind)
	}
	count := child_count(doc, at, node)
	if index < 0 && count < 0 {
		return NO_NODE, .Not_Loaded
	}
	place, in_array := index_in(i64(index), u64(count) if count >= 0 else max(u64))
	if !in_array {
		return NO_NODE, .Missing
	}
	i := int(place)
	if node.spelling & CONTAINER_PARTIAL == 0 {
		first := at + 1
		if intrinsics.expect(doc.ext != nil, false) {
			if t, table := table_of(doc, at); table {
				if t.width != 0 {
					return t.first_row + Node_Index(i) * Node_Index(t.width + 1), .Found
				}
				first = t.first_row
			}
		}
		if r.index != nil && i >= INDEX_ELEMENTS {
			if e, ok := array_entry(r, at, first, count); ok {
				return e.elements[i], .Found
			}
		}
		return nth_child(doc, first, i), .Found
	}
	return element_partial(r, at, node, i)
}

@(private = "file", cold, require_results)
element_partial :: #force_no_inline proc(r: Reader, at: Node_Index, node: Node, i: int) -> (Node_Index, Presence) #no_bounds_check {
	doc := r.doc
	if doc.partial == nil {
		return NO_NODE, .Not_Loaded
	}
	when size_of(int) > 4 {
		if i > int(max(u32)) {
			return NO_NODE, .Not_Loaded
		}
	}
	if r.index != nil && i >= INDEX_ELEMENTS {
		if e, ok := partial_array_entry(r, at, node); ok {
			return kept_lookup(e.kept, u32(i))
		}
	}
	end := at + Node_Index(node.n)
	c := Children{container = at, next = at + 1, kept = kept_from(doc.partial, at)}
	for ; c.next < end; c.next = node_after(doc, c.next) {
		if place, ok := kept_place(doc.partial, &c); ok {
			if place == u32(i) {
				return c.next, .Found
			}
			if place > u32(i) {
				break
			}
		}
	}
	return NO_NODE, .Not_Loaded
}

// Looks up original array index `want` in `kept`, the direct kept children of a partial array sorted by index.
@(private = "file", require_results)
kept_lookup :: #force_inline proc "contextless" (kept: []Kept_Child, want: u32) -> (Node_Index, Presence) #no_bounds_check {
	if uint(want) < uint(len(kept)) && kept[want].index == want {
		return kept[want].node, .Found
	}
	lo, hi := 0, len(kept)
	for lo < hi {
		mid := (lo + hi) / 2
		if kept[mid].index < want {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	if lo < len(kept) && kept[lo].index == want {
		return kept[lo].node, .Found
	}
	return NO_NODE, .Not_Loaded
}

// The child count of the container `node` at `at`, -1 when a partial document does not know it.
child_count :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index, node: Node) -> int {
	count := node.spelling & MAX_CHILDREN
	if count < MAX_CHILDREN {
		return int(count)
	}
	return saturated_count(doc, at)
}

@(private = "file")
saturated_count :: proc "contextless" (doc: ^Document, at: Node_Index) -> int #no_bounds_check {
	lo := by_node(doc.counts, at, false)
	if lo < len(doc.counts) && doc.counts[lo].node == at {
		return int(doc.counts[lo].count)
	}
	return -1
}

// The first entry of `list`, a list sorted by node, whose node is at or past `at`, or past it under `PAST`.
@(private = "file")
by_node :: #force_inline proc "contextless" (list: []$T, at: Node_Index, $PAST: bool) -> int #no_bounds_check {
	lo, hi := 0, len(list)
	for lo < hi {
		mid := (lo + hi) / 2
		if list[mid].node < at || PAST && list[mid].node == at {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// The child `i` of a whole container whose first child is `first`, which it has. Each step waits on the load of the
// child before, so the nodes `NTH_AHEAD` past it are fetched ahead, as the walk only goes forward, and the step past a
// container is the branch the walk predicts. A fetch past the nodes reads nothing.
@(private = "file")
nth_child :: proc "contextless" (doc: ^Document, first: Node_Index, i: int) -> Node_Index #no_bounds_check {
	nodes := raw_data(doc.nodes)
	k := first
	for _ in 0 ..< i {
		t := nodes[k]
		intrinsics.prefetch_read_data(&nodes[k + NTH_AHEAD], 3)
		if intrinsics.expect(t.kind > .Plain, true) {
			k += Node_Index(t.n)
		} else {
			k += 1
		}
	}
	return k
}

@(private)
NTH_AHEAD :: 64

// The node after the value at `at` and its subtree.
node_after :: #force_inline proc "contextless" (doc: ^Document, at: Node_Index) -> Node_Index #no_bounds_check {
	n := doc.nodes[at]
	return at + Node_Index(n.n) if n.kind > .Plain else at + 1
}

// Whether the object at `at` is recorded as having no member `name`, by a search that rests on `Partial.missing` being
// sorted by node.
@(private)
named_missing :: proc "contextless" (x: ^Partial, at: Node_Index, name: string) -> bool #no_bounds_check {
	if x == nil {
		return false
	}
	lo := by_node(x.missing, at, false)
	for m in x.missing[lo:] {
		if m.node != at {
			break
		}
		if string(x.names[m.lo:][:m.n]) == name {
			return true
		}
	}
	return false
}

// The first `kept` entry past the node `at`, by a search that rests on `Partial.kept` being sorted by node.
@(private)
kept_from :: proc "contextless" (x: ^Partial, at: Node_Index) -> u32 #no_bounds_check {
	if x == nil {
		return 0
	}
	return u32(by_node(x.kept, at, true))
}

// The index of the kept element `c.next` of a partial array, which moves `c.kept` past it. A read that keeps only some
// elements of an array gives each it keeps a `kept` entry, so one with none has no known index.
@(private)
kept_place :: proc "contextless" (x: ^Partial, c: ^Children) -> (index: u32, ok: bool) #no_bounds_check {
	for int(c.kept) < len(x.kept) && x.kept[c.kept].node < c.next {
		c.kept += 1
	}
	if int(c.kept) < len(x.kept) && x.kept[c.kept].node == c.next {
		return x.kept[c.kept].index, true
	}
	return 0, false
}

// Whether `name` is one the format of `doc` reads as an expanded name.
@(private)
names_expanded :: #force_inline proc "contextless" (doc: ^Document, name: string) -> bool {
	return doc.format.expanded != nil && len(name) > 0 && name[0] == '{'
}

// Whether key `t` of `doc` reads as `name`.
@(private)
doc_names :: #force_inline proc "contextless" (doc: ^Document, t: Token, name: string) -> bool {
	src, at := node_src(doc, t)
	return key_names(doc.format, src, at, name)
}

// Whether keys `a` and `b` of `doc` read as the same text.
@(private)
doc_same_keys :: #force_inline proc "contextless" (doc: ^Document, a, b: Token) -> bool {
	src_a, at_a := node_src(doc, a)
	src_b, at_b := node_src(doc, b)
	return same_keys(doc.format, src_a, at_a, src_b, at_b)
}

// Whether keys `a` and `b` of `doc`, of any kinds, read as the same text.
@(private)
doc_same_text :: #force_inline proc "contextless" (doc: ^Document, a, b: Token) -> bool {
	src_a, at_a := node_src(doc, a)
	src_b, at_b := node_src(doc, b)
	return doc.format.same_text(src_a, at_a, src_b, at_b)
}

@(private)
doc_key_hash :: #force_inline proc "contextless" (doc: ^Document, t: Token) -> u32 {
	src, at := node_src(doc, t)
	return doc.format.key_hash(src, at)
}
