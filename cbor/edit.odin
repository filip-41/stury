package cbor

// CBOR's edit services. An item is a tree of heads with no separator between its items, and a container's head holds
// its count, so the format commits its edits itself instead of through `core/compose`: the commit writes the item again
// from the root, copies the bytes of every item no edit reaches, and writes a container an edit reaches as its head,
// with the count of members it ends with, its members in their new order, and an indefinite container's break. A
// changed count keeps the width of its head where it fits under `.Cbor`, and takes the shortest head under the specs
// that require one. A deterministic spec writes the members of a map an edit reaches in the order of their encoded
// keys, which a reorder does not change. A tag is a fact of the item it stands before, so a set keeps the item's tags,
// and a tag edit replaces them, but the tag a bignum, a decimal fraction or a bigfloat is spelled with is its number's.
// The result is read again by the walk, so an edit that breaks a rule of the spec is `.Bad_Result`.

import "base:runtime"
import "core:encoding/endian"
import "core:slice"
import core "../core"
import engine "../core/build"
import typed "../core/typed"
import write "../core/write"

// CBOR's edit services, the same table for every spec. A CBOR item keeps its bytes anywhere but its outer tags, which
// are its node's facts.
@(private, rodata)
EDIT := core.Edit_Services {
	value    = edit_value,
	key_text = edit_key_text,
	validate = validate_handle,
	spell    = edit_spell,
	relocate = edit_relocate,
	commit   = edit_commit,
}

// Returns an edit list over `doc`. A document read as a constant spec holds no edit services, so the list takes CBOR's.
edit_list_init :: proc(doc: ^core.Document, spec: Spec, allocator := context.allocator) -> core.Edit_List {
	list := core.edit_list_init(doc, allocator)
	list.edit = &EDIT
	return list
}

// Makes `v` the value at every answer of `path` over `src`, in one call, and returns the new item, which the caller
// frees with `allocator`, keeping every byte the edit does not reach. A `typed.Raw` is the bytes of a CBOR item, a
// struct, a slice or a map is built by `plan`, and any other value is written as a CBOR item. A `Name` the path ends in
// that its map lacks is inserted after the map's last member.
set :: proc(src: []u8, spec: Spec, path: core.Path, v: any, plan: ^typed.Plan = nil, opts := Options{}, read := core.Query_Options{}, allocator := context.allocator) -> (out: []u8, err: core.Error) {
	scratch: write.Scratch
	defer write.scratch_destroy(&scratch)
	in_ := write.edit_input(v, plan, &scratch) or_return
	doc, berr := build(src, spec, opts, read.dups, allocator)
	defer core.destroy(&doc)
	if berr != nil {
		return nil, berr
	}
	list := edit_list_init(&doc, spec, allocator)
	defer core.edit_list_destroy(&list)
	return engine.set_answers(&list, path, in_, read, allocator)
}

// Checks `src` as exactly one item of the document's spec.
@(private)
edit_value :: proc(v: ^core.Token_View, src: []u8, _: runtime.Allocator) -> core.Document_Error {
	if f, bad := validate_text(src, handle_rules(v.as)).?; bad {
		return {kind = .Bad_Value, inner = f}
	}
	return {}
}

// A member's name as a text string.
@(private)
edit_key_text :: proc(_: ^core.Document, name: []u8, text: ^[dynamic]u8) -> bool {
	at := len(text)
	if resize(text, at + 9 + len(name)) != nil {
		return false
	}
	resize(text, at + len(key_bytes(string(name), text[at:])))
	return true
}

// A value an edit writes, as one CBOR item of the document's spec.
@(private)
edit_spell :: proc(doc: ^core.Document, v: core.Value, opts: core.Write_Options, _: string, _: bool, _: u64, allocator: runtime.Allocator) -> ([]u8, core.Error) {
	text, err := write.write_laid(v, doc.as, opts, "", &TOKENS, allocator)
	return text, core.error_of(err)
}

// The item node `node` was read from, without the tags that are its facts.
@(private)
edit_relocate :: proc(doc: ^core.Document, node: core.Node_Index, _: core.Site, allocator: runtime.Allocator) -> ([]u8, bool) {
	_, lo, hi := item_span(doc, node)
	text, failed := slice.clone(doc.src[lo:hi], allocator)
	return text, failed == nil
}

// A commit's state. `order` holds each edit as its node in the high half and its index in the low, sorted, so the
// edits of a subtree are one run of it.
@(private = "file")
Commit :: struct {
	doc:     ^core.Document,
	edits:   []core.Edit,
	order:   []u64,
	spec:    Spec,
	a:       runtime.Allocator,
	dropped: int,
	err:     core.Document_Error,
}

// A member of a container: an object's key and value, or an array's element with no key.
@(private = "file")
Member :: struct {
	key, value: core.Node_Index,
}

// A member written for a sorted map: where its key, its value and its end lie in the map's buffer, and its key's bytes.
@(private = "file")
Written :: struct {
	lo, mid, hi: int,
	key:         []u8,
}

// CBOR's commit: the item `list`'s edits make, written as spec `spec`.
@(private)
edit_commit :: proc(list: ^core.Edit_List, spec: u8, allocator: runtime.Allocator) -> (out: []u8, dropped: int, err: core.Document_Error) {
	doc := list.doc
	if doc == nil || doc.partial {
		return nil, 0, {kind = .Bad_Index}
	}
	arena := runtime.Arena{backing_allocator = allocator, minimum_block_size = 64 * 1024}
	defer runtime.arena_destroy(&arena)
	c := Commit{doc = doc, edits = list.edits[:], spec = Spec(spec), a = runtime.arena_allocator(&arena), err = {kind = .No_Memory}}
	order, failed := make([]u64, len(list.edits), c.a)
	if failed != nil {
		return nil, 0, c.err
	}
	for e, i in list.edits {
		order[i] = u64(e.node) << 32 | u64(i)
	}
	slice.sort(order)
	c.order = order
	made, _ := make([dynamic]u8, 0, len(doc.src), c.a)
	if !put_item(&c, &made, core.ROOT) {
		return nil, 0, c.err
	}
	if out, failed = slice.clone(made[:], allocator); failed != nil {
		return nil, 0, {kind = .No_Memory}
	}
	if fault, bad := validate_text(out, {doc.as.max_depth, doc.as.tolerate, c.spec}).?; bad {
		delete(out, allocator)
		return nil, 0, {kind = .Bad_Result, inner = fault}
	}
	return out, c.dropped, {}
}

// The first entry of `c.order` whose node is `node` or after it.
@(private = "file")
first_at :: proc(c: ^Commit, node: core.Node_Index) -> int {
	lo, hi := 0, len(c.order)
	for lo < hi {
		mid := (lo + hi) / 2
		if c.order[mid] >> 32 < u64(node) {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

@(private = "file")
conflict :: proc(c: ^Commit, at: u64) -> bool {
	c.err = {kind = .Conflicting_Edits, at = at}
	return false
}

@(private = "file")
put :: proc(out: ^[dynamic]u8, b: []u8) -> bool {
	_, failed := append(out, ..b)
	return failed == nil
}

@(private = "file")
push :: proc(d: ^[dynamic]$T, v: T) -> bool {
	_, failed := append(d, v)
	return failed == nil
}

// Writes node `i`'s item with its tags: its bytes as they are when no edit reaches it, else its edits' text.
@(private = "file")
put_item :: proc(c: ^Commit, out: ^[dynamic]u8, i: core.Node_Index) -> bool {
	doc := c.doc
	tags, lo, hi := item_span(doc, i)
	own, inside, end := first_at(c, i), first_at(c, i + 1), first_at(c, i + core.Node_Index(core.subtree_size(doc, i)))
	set, tag := -1, -1
	shaped := false
	for k in own ..< inside {
		at := int(u32(c.order[k]))
		e := c.edits[at]
		switch e.op {
		case .Set:
			if set >= 0 {
				return conflict(c, lo)
			}
			set = at
		case .Set_Fact, .Remove_Fact:
			if e.role != .Tag {
				c.dropped += 1
				continue
			}
			if tag >= 0 {
				return conflict(c, tags)
			}
			tag = at
		case .Insert, .Reorder:
			shaped = true
		case .Remove:
		}
	}
	if tag >= 0 {
		put_tags(c, out, c.edits[tag]) or_return
	} else {
		put(out, doc.src[tags:lo]) or_return
	}
	if set >= 0 {
		if shaped || inside < end {
			return conflict(c, lo)
		}
		e := c.edits[set]
		if e.role == .Key {
			return edit_key_text(doc, e.text, out)
		}
		return put(out, e.text)
	}
	if !shaped && inside == end {
		return put(out, doc.src[lo:hi])
	}
	return put_container(c, out, i, lo, hi)
}

// Writes the tag a tag edit sets, whose body is its decimal digits, in place of every tag of its node.
@(private = "file")
put_tags :: proc(c: ^Commit, out: ^[dynamic]u8, e: core.Edit) -> bool {
	if e.op == .Remove_Fact {
		return true
	}
	tag, ok := tag_number(e.text)
	if !ok {
		c.err = {kind = .Bad_Fact}
		return false
	}
	head: [9]u8
	return put(out, head[:write.put_head(raw_data(head[:]), tag, TREE, .Tag)])
}

// The number decimal `digits` spell, when they are one to twenty digits that fit a u64.
@(private = "file")
tag_number :: proc(digits: []u8) -> (n: u64, ok: bool) {
	if len(digits) == 0 || len(digits) > 20 {
		return 0, false
	}
	for d in digits {
		if d < '0' || d > '9' || n > (max(u64) - u64(d - '0')) / 10 {
			return 0, false
		}
		n = n * 10 + u64(d - '0')
	}
	return n, true
}

// Writes container `i`, whose item lies at `lo ..< hi`, with the inserts, removals and reorder its edits make.
@(private = "file")
put_container :: proc(c: ^Commit, out: ^[dynamic]u8, i: core.Node_Index, lo, hi: u64) -> bool {
	doc := c.doc
	object := doc.nodes[i].kind == .Object
	members, _ := make([dynamic]Member, 0, core.length(doc, i), c.a)
	if object {
		it := core.pairs(doc, i)
		for key, value in core.pair_next(&it) {
			push(&members, Member{key, value}) or_return
		}
	} else {
		it := core.children(doc, i)
		for value in core.child_next(&it) {
			push(&members, Member{core.NO_NODE, value}) or_return
		}
	}
	removed := removals(c, members[:]) or_return
	inserts := inserts_of(c, i) or_return
	order, reordered := reorder_of(c, i, lo) or_return
	n := len(members)
	entries, _ := make([dynamic]int, 0, n + len(inserts), c.a)
	if reordered {
		named, failed := make([]bool, n + len(inserts), c.a)
		if failed != nil {
			return false
		}
		for k in 0 ..< len(order) / 4 {
			at := int(endian.unchecked_get_u32le(order[4 * k:]))
			if at >= len(named) || named[at] || at < n && removed[at] {
				c.err = {kind = .Bad_Index}
				return false
			}
			named[at] = true
			push(&entries, at) or_return
		}
		for k in 0 ..< len(named) {
			if !named[k] && (k >= n || !removed[k]) {
				c.err = {kind = .Bad_Index}
				return false
			}
		}
	} else {
		next := 0
		for m in 0 ..= n {
			for ; next < len(inserts) && int(c.edits[inserts[next]].at) <= m; next += 1 {
				push(&entries, n + next) or_return
			}
			if m < n && !removed[m] {
				push(&entries, m) or_return
			}
		}
	}
	src := doc.src
	b := src[lo]
	ai := b & 31
	head_hi := lo + 1
	if ai != 31 {
		_, width, _ := read_head(src, int(lo), ai)
		head_hi = lo + u64(width)
	}
	if ai == 31 || len(entries) == n {
		put(out, src[lo:head_hi]) or_return
	} else {
		put_count(out, b >> 5, len(entries), ai if c.spec == .Cbor else 0) or_return
	}
	if object && c.spec >= .Deterministic {
		put_sorted(c, out, members[:], inserts, entries[:]) or_return
	} else {
		for k in entries {
			put_member(c, out, members[:], inserts, k) or_return
		}
	}
	return ai != 31 || put(out, src[hi - 1:hi])
}

// Member `k` of a container, its own when `k` is below the count of `members`, else insert `k - len(members)`.
@(private = "file")
put_member :: proc(c: ^Commit, out: ^[dynamic]u8, members: []Member, inserts: []int, k: int) -> bool {
	if k < len(members) {
		m := members[k]
		if m.key != core.NO_NODE {
			put_item(c, out, m.key) or_return
		}
		return put_item(c, out, m.value)
	}
	e := c.edits[inserts[k - len(members)]]
	if e.role == .Key && !edit_key_text(c.doc, e.key, out) {
		return false
	}
	return put(out, e.text)
}

// Writes the members `entries` names in the order of their encoded keys, as the commit's spec sorts them.
@(private = "file")
put_sorted :: proc(c: ^Commit, out: ^[dynamic]u8, members: []Member, inserts: []int, entries: []int) -> bool {
	buf, _ := make([dynamic]u8, 0, 64, c.a)
	spans, failed := make([]Written, len(entries), c.a)
	if failed != nil {
		return false
	}
	for k, j in entries {
		spans[j].lo = len(buf)
		if k < len(members) {
			put_item(c, &buf, members[k].key) or_return
		} else if !edit_key_text(c.doc, c.edits[inserts[k - len(members)]].key, &buf) {
			return false
		}
		spans[j].mid = len(buf)
		if k < len(members) {
			put_item(c, &buf, members[k].value) or_return
		} else {
			put(&buf, c.edits[inserts[k - len(members)]].text) or_return
		}
		spans[j].hi = len(buf)
	}
	for &s in spans {
		s.key = buf[s.lo:s.mid]
	}
	if c.spec == .Length_First {
		slice.sort_by(spans, proc(a, b: Written) -> bool {return key_before(a.key, b.key, .Length_First)})
	} else {
		slice.sort_by(spans, proc(a, b: Written) -> bool {return key_before(a.key, b.key, .Deterministic)})
	}
	for s in spans {
		put(out, buf[s.lo:s.hi]) or_return
	}
	return true
}

// Which of `members` a removal names. A removal of a member another edit reaches inside, other than the member's own
// tag edits, or a second removal of one member, is a conflict.
@(private = "file")
removals :: proc(c: ^Commit, members: []Member) -> ([]bool, bool) {
	removed, failed := make([]bool, len(members), c.a)
	if failed != nil {
		return nil, false
	}
	for m, k in members {
		first := m.key if m.key != core.NO_NODE else m.value
		_, lo, _ := item_span(c.doc, first)
		own, inside := first_at(c, m.value), first_at(c, m.value + 1)
		for j in own ..< inside {
			if c.edits[u32(c.order[j])].op == .Remove {
				if removed[k] {
					return nil, conflict(c, lo)
				}
				removed[k] = true
			}
		}
		if !removed[k] {
			continue
		}
		if first_at(c, first) < own || first_at(c, m.value + core.Node_Index(core.subtree_size(c.doc, m.value))) > inside {
			return nil, conflict(c, lo)
		}
		for j in own ..< inside {
			if op := c.edits[u32(c.order[j])].op; op != .Remove && op != .Set_Fact && op != .Remove_Fact {
				return nil, conflict(c, lo)
			}
		}
	}
	return removed, true
}

// The inserts into container `i`, in the order of their `at` and then of their recording.
@(private = "file")
inserts_of :: proc(c: ^Commit, i: core.Node_Index) -> (inserts: []int, ok: bool) {
	// Each insert as its position in the high half and its index in the low.
	keyed, _ := make([dynamic]u64, 0, 4, c.a)
	for k in first_at(c, i) ..< first_at(c, i + 1) {
		if at := u32(c.order[k]); c.edits[at].op == .Insert {
			push(&keyed, u64(c.edits[at].at) << 32 | u64(at)) or_return
		}
	}
	slice.sort(keyed[:])
	failed: runtime.Allocator_Error
	if inserts, failed = make([]int, len(keyed), c.a); failed != nil {
		return nil, false
	}
	for k, j in keyed {
		inserts[j] = int(u32(k))
	}
	return inserts, true
}

// The positions container `i`'s reorder holds, and whether it has one. A second reorder is a conflict.
@(private = "file")
reorder_of :: proc(c: ^Commit, i: core.Node_Index, lo: u64) -> (order: []u8, found: bool, ok: bool) {
	for k in first_at(c, i) ..< first_at(c, i + 1) {
		if e := c.edits[u32(c.order[k])]; e.op == .Reorder {
			if found {
				return nil, false, conflict(c, lo)
			}
			order, found = e.text, true
		}
	}
	return order, found, true
}

// Appends the head of a container of `major` holding `count` members, as wide as the head `ai` names when that holds
// `count`, else the shortest.
@(private = "file")
put_count :: proc(out: ^[dynamic]u8, major: u8, count: int, ai: u8) -> bool {
	n := u64(count)
	need := u8(n) if n < 24 else 24 if n <= 0xff else 25 if n <= 0xffff else 26 if n <= 0xffff_ffff else 27
	if ai >= 24 && ai <= 27 && ai > need {
		need = ai
	}
	width := 0 if need < 24 else 1 << (need - 24)
	head: [9]u8
	head[0] = major << 5 | need
	for k in 0 ..< width {
		head[1 + k] = u8(n >> (8 * uint(width - 1 - k)))
	}
	return put(out, head[:1 + width])
}
