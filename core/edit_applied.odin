package core

import "base:runtime"
import "core:encoding/endian"
import "core:slice"
import "core:strings"

// Whether `got`, a read of the text a commit of `list` made, holds the document the edits make: a set's node replaced,
// an insert's value placed, a removed member gone, a renamed key and a reorder applied. A value an edit wrote, and a
// container one changed, compare as values do. A node no edit reaches is the source's bytes, which the read that made
// `got` has judged, so its kind and the size of its subtree are compared, not its values. `known` is false when an
// edit holds no value to read back: a text the caller spelled, a type tag or an alias set, or a flat text's header
// cell. Works in the context allocator.
reads_as_edited :: proc(list: ^Edit_List, got: Node_Ref) -> (reads, known: bool) {
	a := applied_of(list) or_return
	return reads_applied(&a, ROOT, got), true
}

// Whether `out`, a flat text a commit of `list` made, read as `as` token by token through `walk`, which passes each token
// to `rows_hook`, holds the document the edits make: the source's rows that stay, in order, each with its values that
// stay, named by the header keys the source names them with and holding the text the source value holds or the value a
// set wrote. `known` is false where the list holds an edit this read does not follow, an insert, a rename, a
// reorder or a set of a row, or the table is ragged, and the commit reads `out` whole. Works in the context
// allocator.
reads_rows :: proc(list: ^Edit_List, out: []u8, as: As, walk: proc(src: []u8, as: As, r: ^Row_Read) -> Maybe(Fault)) -> (err: Document_Error, known: bool) {
	r := Row_Read{view = {src = out, as = as}, ctx = context}
	r.a = applied_of(list) or_return
	doc := list.doc
	if len(r.a.inserts) + len(r.a.renames) + len(r.a.orders) > 0 || doc.n_tables == 0 || doc.tables_at[0].width == 0 {
		return {}, false
	}
	for x in r.a.sets {
		if doc.nodes[x.node].kind > .Plain {
			return {}, false
		}
	}
	if fault, bad := walk(out, as, &r).?; bad {
		return {kind = .No_Memory} if fault.kind == .No_Memory else {kind = .Bad_Result, inner = fault}, true
	}
	if r.failed || r.depth != 0 {
		return {kind = .Bad_Result, reason = .Reads_Back_Other}, true
	}
	return {}, true
}

// Where `reads_rows` stands in the output: the source row and value the next token reads as.
Row_Read :: struct {
	a:       Applied,
	view:    Token_View, // the output's
	rows:    Child_Iter,
	pairs:   Pair_Iter, // the values of a row that is an `Object`, with their keys
	items:   Child_Iter, // the values of a row that is an `Array`
	keyed:   bool,
	named:   bool, // a key came, and `member` is the value it names
	judged:  bool, // a row has ended, so the keys of every later row are the header's again, as the first row judged them
	member:  Node_Index,
	depth:   int,
	failed:  bool,
	ctx:     runtime.Context,
}

// The hook a format's walk runs `reads_rows` with. It stops the walk at the first token that does not read as edited.
rows_hook :: proc "contextless" (r: ^Row_Read, s: Hook_Regs, t: Token) -> (Hook_Regs, Action) {
	context = r.ctx
	if !row_reads(r, t) {
		r.failed = true
		return s, .Stop
	}
	return s, .Next
}

@(private = "file")
row_reads :: proc(r: ^Row_Read, t: Token) -> bool {
	doc := r.a.doc
	if t.role != .Value && t.role != .Key {
		// A comment is no value, and an edit of one holds no value to read back.
		return true
	}
	if t.kind == .End {
		switch r.depth {
		case 1:
			if _, more := kept_child(r, &r.rows); more {
				return false
			}
		case 2:
			if r.keyed {
				for _, v in doc_pair_next(&r.pairs) {
					if !has(r.a.gone, v) {
						return false
					}
				}
			} else if _, more := kept_child(r, &r.items); more {
				return false
			}
		}
		r.judged ||= r.depth == 2
		r.depth -= 1
		return r.depth >= 0 && !r.named
	}
	if t.kind == .Object || t.kind == .Array {
		switch r.depth {
		case 0:
			if doc.nodes[ROOT].kind != t.kind {
				return false
			}
			r.rows = doc_children(doc, ROOT)
		case 1:
			row := kept_child(r, &r.rows) or_return
			if doc.nodes[row].kind != t.kind || has(r.a.is_set, row) {
				return false
			}
			r.keyed = t.kind == .Object
			r.pairs, r.items = doc_pairs(doc, row), doc_children(doc, row)
		case:
			return false
		}
		r.depth += 1
		return true
	}
	if r.depth != 2 || r.named == (t.role == .Key) && r.keyed {
		return false
	}
	if t.role == .Key {
		if !r.keyed {
			return false
		}
		key, v := kept_pair(r) or_return
		r.member, r.named = v, true
		if r.judged {
			return true
		}
		text := token_text(r.view.readers, &r.view, t, context.allocator) or_return
		return key_equals(doc, key, text)
	}
	text := token_text(r.view.readers, &r.view, t, context.allocator) or_return
	if r.keyed {
		r.named = false
	} else {
		r.member = kept_child(r, &r.items) or_return
	}
	if has(r.a.is_set, r.member) {
		read := Document{view = r.view, nodes = []Node{t}}
		return equal(set_of(&r.a, r.member), Node_Ref{&read, ROOT}, read_plain = true)
	}
	want, ok := token_text(doc.readers, &doc.view, doc.nodes[r.member], context.allocator)
	return ok && want == text
}

// The next node `it` gives that no edit removes.
@(private = "file")
kept_child :: proc(r: ^Row_Read, it: ^Child_Iter) -> (Node_Index, bool) {
	for v in doc_child_next(it) {
		if !has(r.a.gone, v) {
			return v, true
		}
	}
	return NO_NODE, false
}

// The next key and value of the row that no edit removes.
@(private = "file")
kept_pair :: proc(r: ^Row_Read) -> (key, v: Node_Index, ok: bool) {
	for k, x in doc_pair_next(&r.pairs) {
		if !has(r.a.gone, x) {
			return k, x, true
		}
	}
	return NO_NODE, NO_NODE, false
}

// A scalar or key an edit wrote, where the commit put it in its output: `lo` through `hi`, the bytes of its text.
Written :: struct {
	lo, hi: u64,
	want:   Value,
	key:    bool,
}

// Whether `out`, a text a commit made, read as `as` token by token through `walk`, which passes each token to
// `written_hook`, holds each of `written`, sorted by `lo`, as one token that spans its bytes and reads as the value
// written. The bytes between are the source's, which its read judged, and the walk judges the whole text. Works in the
// context allocator.
reads_written :: proc(out: []u8, as: As, written: []Written, walk: proc(src: []u8, as: As, w: ^Written_Read) -> Maybe(Fault)) -> Document_Error {
	w := Written_Read{view = {src = out, as = as}, written = written, ctx = context}
	if fault, bad := walk(out, as, &w).?; bad {
		return {kind = .No_Memory} if fault.kind == .No_Memory else {kind = .Bad_Result, inner = fault}
	}
	if w.failed || w.next != len(written) {
		return {kind = .Bad_Result, reason = .Reads_Back_Other}
	}
	return {}
}

// Where `reads_written` stands in the output: the next value written that a token must read as.
Written_Read :: struct {
	view:    Token_View, // the output's
	written: []Written,
	next:    int,
	failed:  bool,
	ctx:     runtime.Context,
}

// The hook a format's walk runs `reads_written` with. It stops the walk at the first token that starts at or past the
// next value written and does not read as it.
written_hook :: proc "contextless" (w: ^Written_Read, s: Hook_Regs, t: Token) -> (Hook_Regs, Action) {
	if w.next == len(w.written) || (t.role != .Value && t.role != .Key) {
		return s, .Next
	}
	lo, hi := scalar_ends(t)
	if lo < w.written[w.next].lo {
		return s, .Next
	}
	context = w.ctx
	x := w.written[w.next]
	w.next += 1
	if lo != x.lo || hi != x.hi || t.kind == .Array || t.kind == .Object || (t.role == .Key) != x.key {
		w.failed = true
		return s, .Stop
	}
	if x.key {
		text, ok := token_text(w.view.readers, &w.view, t, context.allocator)
		w.failed = !ok || text != x.want.(string)
	} else {
		read := Document{view = w.view, nodes = []Node{t}}
		w.failed = !reads_back_as(x.want, Node_Ref{&read, ROOT})
	}
	return s, .Stop if w.failed else .Next
}

// Whether `got` reads as node `n` with the edits of `a` made. A container whose members the edits set, insert, remove
// or rename is compared member by member against the source, with no copy of it built. An object that holds its
// members in another order, or repeats a key, is compared by sorted keys.
@(private = "file")
reads_applied :: proc(a: ^Applied, n: Node_Index, got: Value) -> bool {
	if has(a.is_set, n) {
		return reads_as(set_of(a, n), got)
	}
	doc := a.doc
	k := doc.nodes[n].kind
	if (k != .Object && k != .Array) || !has(a.dirty, n) {
		return reads_as(Node_Ref{doc, n}, got)
	}
	_, reordered := order_of(a, n)
	if reordered || (k == .Object && is_markup(doc)) || value_kind(got) != k {
		return reads_as(applied(a, n), got)
	}
	inserts := inserts_of(a, n)
	if k == .Array {
		mine, theirs := doc_children(doc, n), value_children(got)
		i := 0
		for v in doc_child_next(&mine) {
			defer i += 1
			if !reads_inserts(inserts, i, &theirs) {
				return false
			}
			if has(a.gone, v) {
				continue
			}
			if y, more := value_child_next(&theirs); !more || !reads_applied(a, v, y) {
				return false
			}
		}
		if !reads_inserts(inserts, i, &theirs) {
			return false
		}
		_, extra := value_child_next(&theirs)
		return !extra
	}
	mine, theirs := doc_pairs(doc, n), value_pairs(got)
	i := 0
	for key, v in doc_pair_next(&mine) {
		defer i += 1
		if !reads_inserts(inserts, i, &theirs) {
			return reads_as(applied(a, n), got)
		}
		if has(a.gone, v) {
			continue
		}
		name, y, more := value_pair_next(&theirs)
		named := key_equals(doc, key, name)
		if renamed, is_renamed := renamed_of(a, v); is_renamed {
			named = name == renamed
		}
		if !more || !named || !reads_applied(a, v, y) {
			return reads_as(applied(a, n), got)
		}
	}
	if !reads_inserts(inserts, i, &theirs) {
		return reads_as(applied(a, n), got)
	}
	if _, _, extra := value_pair_next(&theirs); extra {
		return reads_as(applied(a, n), got)
	}
	return true
}

// Whether the next members `it` gives are the values of `inserts` placed at member `at`, under their keys in an object.
@(private = "file")
reads_inserts :: proc(inserts: []Applied_Insert, at: int, it: ^Value_Iter) -> bool {
	for p in inserts {
		if int(p.at) != at {
			continue
		}
		if value_kind(it.v) == .Object {
			name, y, more := value_pair_next(it)
			if !more || name != p.key || !reads_as(p.v, y) {
				return false
			}
		} else if y, more := value_child_next(it); !more || !reads_as(p.v, y) {
			return false
		}
	}
	return true
}

@(private = "file")
reads_as :: proc(want, got: Value) -> bool {
	#partial switch w in want {
	case Node_Ref:
		g, node := got.(Node_Ref)
		if !node || kind(w.doc, w.node) != kind(g.doc, g.node) || subtree_size(w.doc, w.node) != subtree_size(g.doc, g.node) {
			return false
		}
		return !g.doc.readers.floats_apart || same_number_types(want, got)
	case ^Array:
		if value_kind(got) != .Array || value_length(got) != len(w.items) {
			return false
		}
		it := value_children(got)
		for x in w.items {
			y, _ := value_child_next(&it)
			if !reads_as(x, y) {
				return false
			}
		}
		return true
	case ^Object:
		if value_kind(got) != .Object {
			return false
		}
		keys, read := sorted_keys(want), sorted_keys(got)
		if !slice.equal(keys, read) {
			return false
		}
		for k in keys {
			x, _ := value_member(want, k)
			y, _ := value_member(got, k)
			if !reads_as(x, y) {
				return false
			}
		}
		return true
	}
	return reads_back_as(want, got)
}

// Whether `got`, a value read back from the text an edit wrote, is the value `want` the edit wrote: equal as values,
// with a cell or a markup text read as the kind of the value it stands for, and of `want`'s number types where `got`
// is a node of a format that tells an integer from a float.
reads_back_as :: proc(want, got: Value) -> bool {
	if !equal(want, got, read_plain = true) {
		return false
	}
	r, is_node := got.(Node_Ref)
	return !is_node || !r.doc.readers.floats_apart || same_number_types(want, got)
}

// A value `list`'s edits make, at its path in the edited document: `want` the value the path reads there, or no value
// when `gone`, as a removed member's name and the place past an array's last element are.
Edited_Region :: struct {
	path: Path,
	want: Value,
	gone: bool,
}

// The regions of `list`'s document that its edits make, built in the context allocator: each value a set or an insert
// writes, each name a removal or a rename leaves free, the end of each array that gains or loses elements, and the
// whole of a container its edits reorder. A value no edit reaches is not among them. `known` is false as for
// `reads_as_edited`. The regions come in the edited document's order. `fits` is false when the regions are no paths a
// read answers alone: a path past `MAX_STEPS`, a flat text, whose paths do not group names as its read does, or an
// object on the way that repeats a key. A markup document's paths name its elements, not the grouped value's arrays,
// so its regions fit only as one set of an element's content that is no array, through the first element of each name
// on the way, which a read under `.First` answers. Its read of several paths builds the document.
edited_regions :: proc(list: ^Edit_List) -> (regions: []Edited_Region, known, fits: bool) {
	a := applied_of(list) or_return
	markup := is_markup(list.doc)
	if is_flat(list.doc) || (markup && !one_content_set(list)) {
		return nil, true, false
	}
	r := Regions{a = &a, fits = true, markup = markup}
	regions_of(&r, ROOT)
	return r.out[:], true, r.fits && (!markup || len(r.out) <= 1)
}

// Whether `list` sets the content of one element of a markup document to a value that is no array.
@(private = "file")
one_content_set :: proc(list: ^Edit_List) -> bool {
	if len(list.edits) != 1 {
		return false
	}
	e := list.edits[0]
	_, many := e.value.(^Array)
	return e.op == .Set && e.role == .Value && e.node != ROOT && !many && !key_equals(list.doc, e.node - 1, MARKUP_TEXT)
}

// The edits of `list` gathered by the node they change, each list sorted by node, with each container on the way to one
// marked dirty.
@(private = "file")
applied_of :: proc(list: ^Edit_List) -> (a: Applied, known: bool) {
	doc := list.doc
	a.doc = doc
	words := (len(doc.nodes) + 63) / 64
	a.dirty, a.is_set, a.gone = make([]u64, words), make([]u64, words), make([]u64, words)
	sets := make([dynamic]Applied_Set, 0, len(list.edits))
	inserts: [dynamic]Applied_Insert
	renames: [dynamic]Applied_Rename
	orders: [dynamic]Applied_Order
	for e in list.edits {
		switch e.op {
		case .Set:
			if e.role == .Key {
				append(&renames, Applied_Rename{e.node + 1, string(e.text)})
				on_way(&a, e.node + 1, false)
			} else if e.value == nil || doc.nodes[e.node].role == .Key {
				return {}, false
			} else {
				append(&sets, Applied_Set{e.node, e.value})
				mark(a.is_set, e.node)
				on_way(&a, e.node, false)
			}
		case .Insert:
			if e.value == nil {
				return {}, false
			}
			append(&inserts, Applied_Insert{node = e.node, at = e.at, key = string(e.key), v = e.value})
			on_way(&a, e.node, true)
		case .Remove:
			mark(a.gone, e.node)
			on_way(&a, e.node, false)
		case .Reorder:
			append(&orders, Applied_Order{e.node, e.text})
			on_way(&a, e.node, true)
		case .Set_Fact, .Remove_Fact:
			if e.role == .Tag || e.role == .Alias || e.role == .Anchor {
				return {}, false
			}
		}
	}
	a.sets, a.inserts, a.renames, a.orders = by_node(sets[:]), by_node(inserts[:]), by_node(renames[:]), by_node(orders[:])
	if !slice.is_sorted(a.reached[:]) {
		slice.sort(a.reached[:])
	}
	resize(&a.reached, len(slice.unique(a.reached[:])))
	return a, true
}

// `xs` sorted by node, the entries of one node in their order.
@(private = "file")
by_node :: proc(xs: []$T) -> []T {
	before :: proc(x, y: T) -> bool {return x.node < y.node}
	if !slice.is_sorted_by(xs, before) {
		slice.stable_sort_by(xs, before)
	}
	return xs
}

// The entries of `xs`, sorted by node, that node `n` holds.
@(private = "file")
of_node :: proc(xs: []$T, n: Node_Index) -> []T {
	lo := first_of(xs, n)
	end := lo
	for end < len(xs) && xs[end].node == n {
		end += 1
	}
	return xs[lo:end]
}

// The first entry of `xs`, sorted by node, at or past node `n`.
@(private = "file")
first_of :: proc(xs: []$T, n: Node_Index) -> int {
	lo, hi := 0, len(xs)
	for lo < hi {
		mid := (lo + hi) / 2
		if xs[mid].node < n {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

@(private = "file")
set_of :: proc(a: ^Applied, n: Node_Index) -> Value {
	// A read in document order asks for the sets in node order, so each is the entry the last one left off at.
	at := a.set_at
	if at >= len(a.sets) || a.sets[at].node != n {
		at = first_of(a.sets, n)
	}
	v := a.sets[at].v
	for at < len(a.sets) && a.sets[at].node == n {
		at += 1
	}
	a.set_at = at
	return v
}

@(private = "file")
inserts_of :: proc(a: ^Applied, n: Node_Index) -> []Applied_Insert {
	return of_node(a.inserts, n)
}

@(private = "file")
renamed_of :: proc(a: ^Applied, n: Node_Index) -> (string, bool) {
	r := of_node(a.renames, n)
	if len(r) == 0 {
		return "", false
	}
	return r[0].key, true
}

@(private = "file")
order_of :: proc(a: ^Applied, n: Node_Index) -> ([]u8, bool) {
	o := of_node(a.orders, n)
	if len(o) == 0 {
		return nil, false
	}
	return o[0].order, true
}

// Marks each container from the root down to node `x` dirty, and `x` itself when `itself`, with the member each holds
// on the way. A container's subtree is the nodes that follow it within its count, so the member that holds `x` is
// found by subtree sizes with no table of parents. While the way follows the last call's, the search in a container
// starts at the member that call found there when it lies at or before `x`, so edits given in node order step over
// each member once.
@(private = "file")
on_way :: proc(a: ^Applied, x: Node_Index, itself: bool) {
	n, depth, same := ROOT, 0, true
	for n != x {
		mark(a.dirty, n)
		c := n + 1
		same &&= depth < len(a.way)
		if same && a.way[depth] <= x {
			c = a.way[depth]
		}
		for c + Node_Index(subtree_size(a.doc, c)) <= x {
			c += Node_Index(subtree_size(a.doc, c))
		}
		if same && c != a.way[depth] {
			resize(&a.way, depth)
			same = false
		}
		if !same {
			append(&a.way, c)
			append(&a.reached, c)
		}
		n = c
		depth += 1
	}
	resize(&a.way, depth)
	append(&a.reached, x)
	if itself {
		mark(a.dirty, x)
	}
}

@(private = "file")
Applied :: struct {
	doc:     ^Document,
	sets:    []Applied_Set,
	inserts: []Applied_Insert,
	renames: []Applied_Rename,
	orders:  []Applied_Order,
	is_set:  []u64, // bit n: node n is in `sets`
	gone:    []u64, // bit n: node n is removed
	dirty:   []u64, // bit n: node n is a container an edit changes, or one that holds such a container
	reached: [dynamic]Node_Index, // each edit's node and each member on the way to one, sorted once the edits are read
	way:     [dynamic]Node_Index, // the member held at each depth on the last call of `on_way`
	set_at:  int, // the entry of `sets` past the node the last `set_of` found, where the next search starts
}

@(private = "file")
has :: #force_inline proc(bits: []u64, n: Node_Index) -> bool {
	return bits[n >> 6] & (1 << (u64(n) & 63)) != 0
}

@(private = "file")
mark :: #force_inline proc(bits: []u64, n: Node_Index) {
	bits[n >> 6] |= 1 << (u64(n) & 63)
}

@(private = "file")
Applied_Set :: struct {
	node: Node_Index,
	v:    Value,
}

@(private = "file")
Applied_Insert :: struct {
	node: Node_Index, // the container
	at:   u32,
	key:  string,
	v:    Value,
}

@(private = "file")
Applied_Rename :: struct {
	node: Node_Index, // the value whose key is renamed
	key:  string,
}

@(private = "file")
Applied_Order :: struct {
	node:  Node_Index,
	order: []u8,
}

// The value of node `n` with the edits of `a` made.
@(private = "file")
applied :: proc(a: ^Applied, n: Node_Index) -> Value {
	if has(a.is_set, n) {
		return set_of(a, n)
	}
	doc := a.doc
	if k := doc.nodes[n].kind; (k != .Object && k != .Array) || !has(a.dirty, n) {
		return Node_Ref{doc, n}
	}
	Member :: struct {
		key: string,
		v:   Node_Index,
	}
	object := doc.nodes[n].kind == .Object
	read := make([dynamic]Member)
	if object {
		it := doc_pairs(doc, n)
		for k, v in doc_pair_next(&it) {
			append(&read, Member{node_string(doc, k), v})
		}
	} else {
		it := doc_children(doc, n)
		for v in doc_child_next(&it) {
			append(&read, Member{"", v})
		}
	}
	members := read[:]
	if order, reordered := order_of(a, n); reordered {
		members = make([]Member, len(read))
		for &m, i in members {
			m = read[endian.unchecked_get_u32le(order[4 * i:])]
		}
	}
	b := Applied_Build{object = object, markup = object && is_markup(doc), o = new_object(), arr = new_array(len(members))}
	inserts := inserts_of(a, n)
	for i in 0 ..= len(members) {
		for p in inserts {
			if int(p.at) == i {
				applied_put(&b, p.key, p.v)
			}
		}
		if i == len(members) || has(a.gone, members[i].v) {
			continue
		}
		key := members[i].key
		if renamed, is_renamed := renamed_of(a, members[i].v); is_renamed {
			key = renamed
		}
		applied_put(&b, key, applied(a, members[i].v))
	}
	return b.o if object else b.arr
}

@(private = "file")
Regions :: struct {
	a:          ^Applied,
	steps:      [dynamic]Step, // the path from the root to the node being walked
	out:        [dynamic]Edited_Region,
	fits:       bool,
	markup:     bool,
	reached_at: int, // the entry of the applied edits' reached nodes past the last container the walk read
}

@(private = "file")
region :: proc(r: ^Regions, step: Maybe(Step), want: Value, gone := false) {
	path := make([]Step, len(r.steps) + (1 if step != nil else 0))
	copy(path, r.steps[:])
	if s, has := step.?; has {
		path[len(path) - 1] = s
	}
	append(&r.out, Edited_Region{path = {steps = path}, want = want, gone = gone})
}

// Adds the regions under node `n`, at the path `r.steps`, to `r`.
@(private = "file")
regions_of :: proc(r: ^Regions, n: Node_Index) {
	a := r.a
	doc := a.doc
	if has(a.is_set, n) {
		region(r, nil, set_of(a, n))
		return
	}
	if !has(a.dirty, n) || !r.fits {
		return
	}
	if _, reordered := order_of(a, n); reordered {
		region(r, nil, applied(a, n))
		return
	}
	if len(r.steps) >= MAX_STEPS - 1 {
		r.fits = false
		return
	}
	inserts := inserts_of(a, n)
	// The members of `n` an edit reaches are the reached nodes within its subtree that no other reached node holds. A
	// walk in document order enters each reached node at the entry the last one left off at.
	touched := make([dynamic]Node_Index)
	end := n + Node_Index(subtree_size(doc, n))
	k := r.reached_at + 1
	if r.reached_at >= len(a.reached) || a.reached[r.reached_at] != n {
		k, _ = slice.binary_search(a.reached[:], n + 1)
	}
	for k < len(a.reached) && a.reached[k] < end {
		v := a.reached[k]
		append(&touched, v)
		for past := v + Node_Index(subtree_size(doc, v)); k < len(a.reached) && a.reached[k] < past; {
			k += 1
		}
	}
	r.reached_at = k
	if doc.nodes[n].kind == .Object {
		object_regions(r, n, touched[:], inserts)
		return
	}
	if r.markup {
		r.fits = false
		return
	}
	resized := len(inserts) > 0
	for v in touched {
		resized ||= has(a.gone, v)
	}
	// An array that keeps its length keeps each element's index, so the walk ends at the last member an edit reaches.
	at, t, i := 0, 0, 0
	it := doc_children(doc, n)
	for v in doc_child_next(&it) {
		if !resized && t == len(touched) {
			break
		}
		defer i += 1
		for p in inserts {
			if int(p.at) == i {
				region(r, Index(at), p.v)
				at += 1
			}
		}
		reached := t < len(touched) && touched[t] == v
		t += int(reached)
		switch {
		case reached && has(a.gone, v):
			continue
		case reached:
			append(&r.steps, Index(at))
			regions_of(r, v)
			pop(&r.steps)
		}
		at += 1
	}
	for p in inserts {
		if int(p.at) == i {
			region(r, Index(at), p.v)
			at += 1
		}
	}
	if resized {
		region(r, Index(at), nil, true)
	}
}

// Adds the regions of object `n` to `r`: the members `touched` names, each name a removal or a rename frees, and each
// of `inserts`. A name the object holds more than once among those the edits reach, as an insert of a name it holds
// does, is no path a read answers alone, but for the first element of the name in a markup object.
@(private = "file")
object_regions :: proc(r: ^Regions, n: Node_Index, touched: []Node_Index, inserts: []Applied_Insert) {
	a := r.a
	doc := a.doc
	names := make([dynamic]string, 0, len(touched) + len(inserts))
	for v in touched {
		append(&names, node_string(doc, v - 1))
	}
	for p in inserts {
		append(&names, p.key)
	}
	for name, i in names {
		held, first := int(i >= len(touched)), NO_NODE
		it := doc_pairs(doc, n)
		for k, v in doc_pair_next(&it) {
			if key_equals(doc, k, name) {
				held += 1
				first = v if first == NO_NODE else first
			}
		}
		if held > 1 && !(r.markup && first == touched[i]) {
			r.fits = false
			return
		}
	}
	start := len(r.out)
	for v, i in touched {
		name := names[i]
		renamed, is_renamed := renamed_of(a, v)
		switch {
		case has(a.gone, v) || is_renamed:
			region(r, Name(name), nil, true)
			if is_renamed && !has(a.gone, v) {
				region(r, Name(renamed), applied(a, v))
			}
		case:
			append(&r.steps, Name(name))
			regions_of(r, v)
			pop(&r.steps)
		}
	}
	for p in inserts {
		region(r, Name(p.key), p.v)
	}
	// A name freed and written again in one object holds what is written.
	for i := start; i < len(r.out); i += 1 {
		o := r.out[i]
		if !o.gone || len(o.path.steps) != len(r.steps) + 1 {
			continue
		}
		for w in r.out[start:] {
			if !w.gone && len(w.path.steps) == len(o.path.steps) && w.path.steps[len(w.path.steps) - 1] == o.path.steps[len(o.path.steps) - 1] {
				ordered_remove(&r.out, i)
				i -= 1
				break
			}
		}
	}
}

// A container being built from its members in order, `last` the key of the member put last.
@(private = "file")
Applied_Build :: struct {
	object, markup: bool,
	o:              ^Object,
	arr:            ^Array,
	last:           string,
}

// Puts member `key` of value `v` in `b`. A markup object groups a repeated name as its reading does: an array an edit
// writes is an element of the name for each item, and a text that follows a text joins it, as a read of the output
// joins them.
@(private = "file")
applied_put :: proc(b: ^Applied_Build, key: string, v: Value) {
	switch {
	case !b.object:
		array_append(b.arr, v)
		return
	case !b.markup:
		object_append(b.o, key, v)
		return
	}
	if items, many := v.(^Array); many {
		for item in items.items {
			applied_put(b, key, item)
		}
		return
	}
	defer b.last = key
	if key != MARKUP_TEXT || b.last != MARKUP_TEXT {
		markup_put(b.o, key, v)
		return
	}
	at := &b.o.vals[object_slot(b.o, key)]
	if group, grouped := at.(^Array); grouped {
		at = &group.items[len(group.items) - 1]
	}
	at^ = strings.concatenate({text_of(at^), text_of(v)})
}

@(private = "file")
text_of :: proc(v: Value) -> string {
	#partial switch x in v {
	case string:
		return x
	case Node_Ref:
		return node_string(x.doc, x.node)
	}
	return ""
}
