// Compares the edit list with a plain tree of values: a random document is read into the tree, the same edits are
// applied to the tree and to a list over the document, and the committed text must read as the tree. A second check
// holds one edit of each round against the current tree's `json.set`, `insert` and `remove` by path.
// `make test-oracle` builds this package from a copy of next/.
package json_oracle

import "base:intrinsics"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import cur "stury:json"
import core "../../../core"
import json "../.."
import gen "../gen"
import walktest "../../../walktest"

// `Edit_Model` holds a document value as a plain tree: its kind, its decoded text or number, its key if it is a
// member, and the node it was read from. `node` is an edit's target and `key_node` a member's key node, which `set` may
// change on its own.
Edit_Model :: struct {
	kind:     core.Kind,
	text:     string,
	num:      core.Number,
	key:      string,
	key_node: u32,
	node:     u32,
	ord:      int, // its index among its parent's original members, -1 for a value from text
	path:     string,
	kids:     []Edit_Model,
}

@(private)
model_of :: proc(doc: ^core.Document, i: u32, path: string) -> Edit_Model {
	m := Edit_Model{kind = core.kind(doc, i), node = i, path = path}
	switch m.kind {
	case .String:
		buf: [4096]u8
		if s, ok := core.text(doc, i, buf[:], context.temp_allocator); ok {
			m.text = strings.clone(s, context.temp_allocator)
		}
	case .Number:
		m.num = core.number(doc, i)
	case .Array, .Map:
		kids := make([dynamic]Edit_Model, 0, 4, context.temp_allocator)
		it := core.children(doc, i)
		index := 0
		for {
			v, ok := core.child_next(&it)
			if !ok {
				break
			}
			kp := path
			key: string
			if m.kind == .Map {
				buf: [4096]u8
				if s, kok := core.text(doc, v - 1, buf[:], context.temp_allocator); kok {
					key = strings.clone(s, context.temp_allocator)
				}
				kp = path_name(path, key)
			} else {
				kp = path_index(path, index)
			}
			kid := model_of(doc, v, kp)
			kid.ord = index
			kid.key = key
			if m.kind == .Map {
				kid.key_node = v - 1
			}
			append(&kids, kid)
			index += 1
		}
		m.kids = kids[:]
	case .Null, .False, .True, .Plain, .End:
	}
	return m
}

// Clears every node and key node of a tree read from text, so an edit cannot target it and its labels do not collide
// with the document's.
@(private)
detach :: proc(m: ^Edit_Model) {
	m.node = core.NO_NODE
	m.key_node = core.NO_NODE
	m.ord = -1
	for i in 0 ..< len(m.kids) {
		detach(&m.kids[i])
	}
}

// Returns a member's path: a bare name where jq reads one, else a quoted name.
@(private)
path_name :: proc(path, name: string) -> string {
	bare := len(name) > 0
	for c in name {
		bare &&= c == '_' || c == '$' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'
	}
	if bare && !(name[0] >= '0' && name[0] <= '9') {
		return fmt.tprintf("%s.%s", path, name)
	}
	q, _ := cur.marshal(name)
	defer delete(q)
	return fmt.tprintf("%s[%s]", path, string(q))
}

@(private)
path_index :: proc(path: string, i: int) -> string {
	return fmt.tprintf("%s[%d]", path, i)
}

@(private)
model_at :: proc(m: ^Edit_Model, node: u32) -> ^Edit_Model {
	if node != core.NO_NODE && m.node == node {
		return m
	}
	for i in 0 ..< len(m.kids) {
		if p := model_at(&m.kids[i], node); p != nil {
			return p
		}
	}
	return nil
}

// Returns the member whose key node is `key_node`, or nil.
@(private)
model_key_at :: proc(m: ^Edit_Model, key_node: u32) -> ^Edit_Model {
	if key_node != core.NO_NODE && m.key_node == key_node {
		return m
	}
	for i in 0 ..< len(m.kids) {
		if p := model_key_at(&m.kids[i], key_node); p != nil {
			return p
		}
	}
	return nil
}

@(private)
model_parent :: proc(m: ^Edit_Model, node: u32) -> (^Edit_Model, int) {
	for i in 0 ..< len(m.kids) {
		if m.kids[i].node == node {
			return m, i
		}
		if p, k := model_parent(&m.kids[i], node); p != nil {
			return p, k
		}
	}
	return nil, -1
}

// Builds `src` as the run-time `spec`.
@(private)
build_spec :: proc(src: []u8, spec: json.Spec) -> (core.Document, core.Document_Error) {
	switch spec {
	case .Json:
		return json.build(src, .Json)
	case .Jsonc:
		return json.build(src, .Jsonc)
	case .Json5:
		return json.build(src, .Json5)
	}
	return {}, {kind = .Bad_Value}
}

// Returns the tree `text` reads as under `spec`, or false if it does not read.
@(private)
model_text :: proc(text: []u8, spec: json.Spec) -> (Edit_Model, bool) {
	doc, err := build_spec(text, spec)
	defer core.destroy(&doc)
	if err.kind != .None {
		return {}, false
	}
	m := model_of(&doc, core.ROOT, ".")
	detach(&m)
	return m, true
}

// Inserts `kid` before the member whose original index is `at`. An insert position is resolved against the document
// the list was made from, so a member another edit removed leaves its place to the new one.
@(private)
model_insert :: proc(m: ^Edit_Model, at: int, kid: Edit_Model, key: string, has_key: bool) {
	n := len(m.kids)
	pos := n
	for j in 0 ..< n {
		if m.kids[j].ord >= at {
			pos = j
			break
		}
	}
	out := make([]Edit_Model, n + 1, context.temp_allocator)
	copy(out[:pos], m.kids[:pos])
	out[pos] = kid
	if has_key {
		out[pos].key = key
	}
	copy(out[pos + 1:], m.kids[pos:])
	m.kids = out
}

// Removes member `index` from the tree.
@(private)
model_remove :: proc(m: ^Edit_Model, index: int) {
	n := len(m.kids)
	out := make([]Edit_Model, n - 1, context.temp_allocator)
	copy(out[:index], m.kids[:index])
	copy(out[index:], m.kids[index + 1:])
	m.kids = out
}

// Returns the key `text` names, decoded under `spec`, or false.
@(private)
key_value :: proc(text: []u8, spec: json.Spec) -> (string, bool) {
	buf, aerr := make([]u8, len(text) + 4)
	if aerr != nil {
		return "", false
	}
	defer delete(buf)
	buf[0] = '{'
	copy(buf[1:], text)
	buf[len(text) + 1] = ':'
	buf[len(text) + 2] = '0'
	buf[len(text) + 3] = '}'
	doc, err := build_spec(buf, spec)
	defer core.destroy(&doc)
	if err.kind != .None || len(doc.nodes) < 2 {
		return "", false
	}
	out: [4096]u8
	s, ok := core.text(&doc, 1, out[:], context.temp_allocator)
	if !ok {
		return "", false
	}
	return strings.clone(s, context.temp_allocator), true
}

// `Node_Ref` is a node an edit may name: its node index, kind, path, and for a member its index among its parent's
// members.
Node_Ref :: struct {
	node:  u32,
	kind:  core.Kind,
	path:  string,
	index: int,
}

@(private)
Gather :: struct {
	values:     [dynamic]Node_Ref,
	members:    [dynamic]Node_Ref,
	containers: [dynamic]Node_Ref,
	maps:       [dynamic]Node_Ref,
	arrays:     [dynamic]Node_Ref,
	keys:       [dynamic]Node_Ref,
}

@(private)
gather_init :: proc(g: ^Gather) {
	g.values = make([dynamic]Node_Ref, 0, 8, context.temp_allocator)
	g.members = make([dynamic]Node_Ref, 0, 8, context.temp_allocator)
	g.containers = make([dynamic]Node_Ref, 0, 8, context.temp_allocator)
	g.maps = make([dynamic]Node_Ref, 0, 8, context.temp_allocator)
	g.arrays = make([dynamic]Node_Ref, 0, 8, context.temp_allocator)
	g.keys = make([dynamic]Node_Ref, 0, 8, context.temp_allocator)
}

// `Touched` holds the nodes and containers an edit already touched. A second edit of one of them, or one inside a
// replaced value, would conflict at the commit, so a round does not edit them again.
@(private)
Touched :: struct {
	nodes:      [16]u32,
	n_nodes:    int,
	containers: [16]u32,
	n_containers: int,
}

@(private)
touch_node :: proc(x: ^Touched, node: u32) {
	if x.n_nodes < len(x.nodes) {
		x.nodes[x.n_nodes] = node
		x.n_nodes += 1
	}
}

@(private)
touch_container :: proc(x: ^Touched, node: u32) {
	if x.n_containers < len(x.containers) {
		x.containers[x.n_containers] = node
		x.n_containers += 1
	}
}

@(private)
node_touched :: proc(x: ^Touched, node: u32) -> bool {
	for i in 0 ..< x.n_nodes {
		if x.nodes[i] == node {
			return true
		}
	}
	return false
}

@(private)
container_touched :: proc(x: ^Touched, node: u32) -> bool {
	for i in 0 ..< x.n_containers {
		if x.containers[i] == node {
			return true
		}
	}
	return false
}

@(private)
gather :: proc(m: ^Edit_Model, index: int, g: ^Gather, x: ^Touched) {
	if m.node != core.NO_NODE && !node_touched(x, m.node) {
		ref := Node_Ref{node = m.node, kind = m.kind, path = m.path, index = index}
		append(&g.values, ref)
		if index >= 0 {
			append(&g.members, ref)
		}
		#partial switch m.kind {
		case .Array, .Map:
			if !container_touched(x, m.node) {
				append(&g.containers, ref)
			}
			if m.kind == .Map {
				append(&g.maps, ref)
			} else {
				append(&g.arrays, ref)
			}
		}
		if m.kind == .Map {
			for i in 0 ..< len(m.kids) {
				if m.kids[i].key_node != core.NO_NODE {
					append(&g.keys, Node_Ref{node = m.kids[i].key_node, kind = .String, path = m.kids[i].path, index = i})
				}
			}
		}
	}
	for i in 0 ..< len(m.kids) {
		gather(&m.kids[i], i, g, x)
	}
}

@(private)
model_agrees :: proc(t: ^testing.T, m: Edit_Model, doc: ^core.Document, i: u32, what: string) -> bool {
	k := core.kind(doc, i)
	if !testing.expectf(t, k == m.kind, "%s: kind %v, model %v", what, k, m.kind) {
		return false
	}
	switch k {
	case .String:
		buf: [4096]u8
		s, ok := core.text(doc, i, buf[:], context.temp_allocator)
		if !testing.expectf(t, ok && s == m.text, "%s: text %q, model %q", what, s, m.text) {
			return false
		}
	case .Number:
		n := core.number(doc, i)
		if !testing.expectf(t, n.kind == m.num.kind && n.bits == m.num.bits, "%s: number %v, model %v", what, n, m.num) {
			return false
		}
	case .Array, .Map:
		if !testing.expectf(t, core.length(doc, i) == len(m.kids), "%s: %d members, model %d", what, core.length(doc, i), len(m.kids)) {
			return false
		}
		it := core.children(doc, i)
		for kid, idx in m.kids {
			v, ok := core.child_next(&it)
			if !testing.expectf(t, ok, "%s: member %d is missing", what, idx) {
				return false
			}
			if k == .Map {
				buf: [4096]u8
				key, kok := core.text(doc, v - 1, buf[:], context.temp_allocator)
				if !testing.expectf(t, kok && key == kid.key, "%s: member %d key %q, model %q", what, idx, key, kid.key) {
					return false
				}
			}
			if !model_agrees(t, kid, doc, v, fmt.tprintf("%s/%d", what, idx)) {
				return false
			}
		}
	case .Null, .False, .True, .Plain, .End:
	}
	return true
}


@(private)
span_lo :: proc(doc: ^core.Document, i: u32) -> u64 {
	return u64(intrinsics.ptr_sub(raw_data(core.span(doc, i)), raw_data(doc.src)))
}

@(private)
find_byte :: proc(b: []u8, at: int, c: u8) -> int {
	for x, i in b[at:] {
		if x == c {
			return at + i
		}
	}
	return -1
}

// `member_extent` returns a member's byte extent as `commit` reads it: from its key's first byte or its own, including
// the comments above it, to one past its value or its trailing comments, stopping at a following comma.
@(private)
member_extent :: proc(doc: ^core.Document, v: u32) -> (lo, hi: u64) {
	lo = span_lo(doc, v)
	if v > 0 && doc.nodes[v-1].role == .Key {
		lo = min(lo, span_lo(doc, v-1))
	}
	for f in doc.facts {
		if f.node == v && f.lo < lo {
			lo = f.lo
		}
	}
	hi = span_lo(doc, v) + u64(len(core.span(doc, v)))
	for f in doc.facts {
		if f.node != v {
			continue
		}
		if f.lo < hi {
			continue
		}
		if k := find_byte(doc.src, int(hi), ','); k >= 0 && u64(k) < f.lo {
			return lo, u64(k)
		}
		hi = f.lo + u64(f.n)
	}
	return
}

// Returns the byte an insert into `e.node` at `e.at` is written at: the member's first byte, the last member's end,
// or the first byte inside an empty container.
@(private)
insert_pos :: proc(doc: ^core.Document, e: core.Edit) -> (u64, bool) {
	it := core.children(doc, e.node)
	i := 0
	last: u64
	last_node := core.NO_NODE
	have := false
	for {
		v, ok := core.child_next(&it)
		if !ok {
			break
		}
		lo, hi := member_extent(doc, v)
		if i == int(e.at) {
			return lo, true
		}
		last, last_node, have = hi, v, true
		i += 1
	}
	if have {
		// A trailing comma serves as the new member's separator, so the insert is written before the close.
		if close := doc.spelling.close_end(doc, e.node); true {
			if k := find_byte(doc.src, int(last), ','); k >= 0 && u64(k) < close {
				return close - 1, true
			}
		}
		// A `//` comment at the last member's end puts the new member after its line end.
		for f in doc.facts {
			if f.node != last_node {
				continue
			}
			if f.lo + u64(f.n) == last && f.n >= 2 && doc.src[f.lo] == '/' && doc.src[f.lo+1] == '/' {
				return core.line_end_len(doc.src, last, true), true
			}
		}
		return last, true
	}
	n := doc.nodes[e.node].lo
	return n + 1, true
}

// Checks that a conflict's byte belongs to an edit: a member's first or last byte, a node's span, or an insert's byte.
@(private)
conflict_agrees :: proc(t: ^testing.T, round: int, doc: ^core.Document, edits: []core.Edit, at: u64) -> bool {
	if at > u64(len(doc.src)) {
		return testing.expectf(t, false, "round %d: conflict at %d is past the text", round, at)
	}
	for e in edits {
		if e.op == .Insert {
			if p, ok := insert_pos(doc, e); ok && p == at {
				return true
			}
			continue
		}
		lo, hi := member_extent(doc, e.node)
		ks := span_lo(doc, e.node)
		ke := ks + u64(len(core.span(doc, e.node)))
		if at == lo || at == hi || at == ks || at == ke || at > lo && at < hi {
			return true
		}
	}
	fmt.printfln("  src %q at %d", doc.src, at)
	for e in edits {
		if e.op == .Insert {
			p, _ := insert_pos(doc, e)
			fmt.printfln("  insert node %d at %d -> %d text %q", e.node, e.at, p, e.text)
		} else {
			lo, hi := member_extent(doc, e.node)
			fmt.printfln("  %v node %d extent %d..%d span %d..%d", e.op, e.node, lo, hi, span_lo(doc, e.node), span_lo(doc, e.node)+u64(len(core.span(doc, e.node))))
		}
	}
	return testing.expectf(t, false, "round %d: conflict at %d names no edited member", round, at)
}

@(private)
Piece :: struct {
	lo: u64,
	b:  []u8,
}

// Checks that every node and fact no edit replaces appears in `out` in source order. A set replaces the node's own
// bytes and no comment, and a removal removes the member's subtree and its facts.
@(private)
kept_bytes :: proc(t: ^testing.T, round: int, doc: ^core.Document, out: []u8, edits: []core.Edit) -> bool {
	gone := make([]bool, len(doc.nodes), context.temp_allocator)
	for e in edits {
		if e.op == .Insert {
			continue
		}
		n := doc.nodes[e.node]
		end := int(e.node) + 1
		if n.kind == .Array || n.kind == .Map {
			end = int(e.node) + int(n.n)
		}
		for i := int(e.node); i < min(end, len(doc.nodes)); i += 1 {
			gone[i] = true
		}
		if e.op == .Remove && e.node > 0 && doc.nodes[e.node-1].role == .Key {
			gone[e.node-1] = true
		}
	}
	pieces := make([dynamic]Piece, context.temp_allocator)
	for node, i in doc.nodes {
		if gone[i] || node.kind == .End || node.kind == .Array || node.kind == .Map {
			continue
		}
		s := core.span(doc, u32(i))
		append(&pieces, Piece{lo = span_lo(doc, u32(i)), b = s})
	}
	for f in doc.facts {
		if f.node < u32(len(gone)) && gone[f.node] {
			continue
		}
		// A foot on a member an insert no longer makes last, and a head comment a removal would join to a value, are
		// dropped and counted, so their bytes may be missing from `out`.
		if f.node != core.ROOT && (f.role == .Comment_Foot || f.role == .Comment) {
			continue
		}
		// A fact edit replaces or removes every fact of its node and role, so their bytes may be missing.
		taken := false
		for e in edits {
			if e.op >= .Set_Fact && e.node == f.node && e.role == f.role {
				taken = true
				break
			}
		}
		if taken {
			continue
		}
		append(&pieces, Piece{lo = f.lo, b = doc.src[f.lo:f.lo + u64(f.n)]})
	}
	slice.sort_by(pieces[:], proc(a, b: Piece) -> bool { return a.lo < b.lo })
	cursor := 0
	for p in pieces {
		k := bytes_index_from(out, cursor, p.b)
		if k < 0 {
			return testing.expectf(t, false, "round %d: kept bytes %q are missing from %q", round, p.b, out)
		}
		cursor = k + len(p.b)
	}
	return true
}

@(private)
bytes_index_from :: proc(hay: []u8, from: int, need: []u8) -> int {
	if len(need) == 0 {
		return from
	}
	for i := from; i + len(need) <= len(hay); i += 1 {
		if string(hay[i:i+len(need)]) == string(need) {
			return i
		}
	}
	return -1
}

// `VALUES` holds the values an edit may write, per spec. A JSON value holds no form another spec reads.
@(private)
VALUES := [3][]string {
	{"0", "1", "-2.5", "true", "false", "null", `"s"`, `"a\nb"`, "[]", "{}", "[1,2]", `{"k":1}`, "1e3", "9007199254740993", `[{"a":[true]}]`},
	{"0", "1", "-2.5", "true", "false", "null", `"s"`, `"a\nb"`, "[]", "{}", "[1,2]", `{"k":1}`, "1e3", "/*c*/2", "[1, /*c*/ 2]", "//c\n3"},
	{"0", "1", "-2.5", "true", "false", "null", `"s"`, `"a\nb"`, "[]", "{}", "[1,2]", `{"k":1}`, "0x10", "Infinity", "NaN", `'q'`, "{a:1}", "[1,]", "1e3"},
}

@(private)
KEY_TEXT := [3][]string {
	{`"a"`, `"b"`, `"k1"`, `""`, `"é"`, `"a b"`, `"x\u0041"`},
	{`"a"`, `"b"`, `"k1"`, `""`, `"é"`, `"a b"`},
	{`"a"`, "b", "k1", `""`, `é`, `"a b"`, `$x`, `\u0061`},
}

// `Second` is an edit of a round that the current tree's path API can express: the op, its node, and what a path
// needs.
Second :: struct {
	ok:       bool, // the round may be checked against the current tree
	set:      bool, // an expressible edit was taken
	kind:     u8,   // 0 set, 1 element insert, 2 member insert, 3 remove
	node:     u32,
	at:       int,
	key:      string, // a member insert's name, decoded
	key_text: string, // a member insert's name as the edit records it
	text:     string,
	path:     string,
}

@(test)
edits_agree_with_tree :: proc(t: ^testing.T) {
	state := rand.create(SEED + 11)
	context.random_generator = rand.default_random_generator(&state)
	text: [dynamic]u8
	defer delete(text)
	rounds, refused, conflicted, checked, parted, frounds, fnonempty: int
	for round in 0 ..< ROUNDS {
		clear(&text)
		spec := json.Spec(round % len(json.Spec))
		values := VALUES[spec]
		keys := KEY_TEXT[spec]
		if round % 4 == 3 {
			gen.pretty(&text, 1 + round % 4, spec)
		} else {
			gen.text(&text, 1 + round % 4, spec)
		}
		doc, err := build_spec(text[:], spec)
		if err.kind != .None {
			free_all(context.temp_allocator)
			continue
		}
		root := model_of(&doc, core.ROOT, ".")
		touched: Touched
		list := core.edit_list_init(&doc)
		second: Second
		want := root
		second.ok = unique_keys(&want)

		edits := 1 + rand.int_max(4)
		bad := false
		for _ in 0 ..< edits {
			g: Gather
			gather_init(&g)
			gather(&want, -1, &g, &touched)
			if !one_edit(t, &want, &g, &list, values, keys, spec, &second, &touched) {
				bad = true
				break
			}
		}
		if bad {
			testing.expectf(t, false, "round %d: a recorded edit is not in the model", round)
			core.edit_list_destroy(&list)
			core.destroy(&doc)
			free_all(context.temp_allocator)
			return
		}
		fbefore, fok := fact_edits(t, round, &doc, &list)
		if !fok {
			core.edit_list_destroy(&list)
			core.destroy(&doc)
			free_all(context.temp_allocator)
			return
		}
		out, dropped, cerr := core.commit(&list)
		if cerr.kind == .Conflicting_Edits {
			conflicted += 1
			if !conflict_agrees(t, round, &doc, list.edits[:], cerr.at) {
				fmt.printfln("  text %q", text[:])
				for e in list.edits {
					fmt.printfln("  edit %v node %d role %v at %d key %q text %q", e.op, e.node, e.role, e.at, e.key, e.text)
				}
				return
			}
			core.edit_list_destroy(&list)
			core.destroy(&doc)
			free_all(context.temp_allocator)
			continue
		}
		if !testing.expectf(t, cerr.kind == .None, "round %d %q: commit %v", round, text[:], cerr) {
			for e in list.edits {
				fmt.printfln("  edit %v node %d role %v at %d key %q text %q", e.op, e.node, e.role, e.at, e.key, e.text)
			}
			return
		}
		rounds += 1
		read, rerr := build_spec(out, spec)
		if !testing.expectf(t, rerr.kind == .None, "round %d: committed text does not read: %v in %q", round, rerr, out) {
			return
		}
		if !model_agrees(t, want, &read, core.ROOT, "root") {
			testing.expectf(t, false, "round %d: %q -> %q", round, text[:], out)
			for e in list.edits {
				fmt.printfln("  edit %v node %d role %v at %d key %q text %q", e.op, e.node, e.role, e.at, e.key, e.text)
			}
			return
		}
		if !kept_bytes(t, round, &doc, out, list.edits[:]) {
			fmt.printfln("  text %q", text[:])
			for e in list.edits {
				fmt.printfln("  edit %v node %d role %v at %d key %q text %q", e.op, e.node, e.role, e.at, e.key, e.text)
			}
			return
		}
		if second.ok && second_check(t, &doc, &second, spec, &refused, &checked, &parted) {
			// `second_check` records its failures itself, so its result is unused here.
		}
		frounds += 1
		fokc, fkept := fact_check(t, round, fbefore[:], &list, &doc, &want, &read, dropped)
		if !fokc {
			fmt.printfln("  text %q", text[:])
			for e in list.edits {
				fmt.printfln("  edit %v node %d role %v at %d key %q text %q", e.op, e.node, e.role, e.at, e.key, e.text)
			}
			return
		}
		if fkept > 0 && dropped == 0 {
			fnonempty += 1
		}
		core.destroy(&read)
		delete(out)
		core.edit_list_destroy(&list)
		core.destroy(&doc)
		free_all(context.temp_allocator)
	}
	fmt.printfln("seed %d: %d rounds, %d refused, %d conflicted, %d second checks (%d parted, %d refused), %d fact rounds (%d with a non-empty model)", SEED, rounds, refused, conflicted, checked, parted, refused, frounds, fnonempty)
	testing.expectf(t, fnonempty > 0, "no round compared a non-empty fact model")
}

// Records a random edit on the list and applies it to the tree, or neither. A refusal at record leaves both unchanged.
@(private)
one_edit :: proc(t: ^testing.T, want: ^Edit_Model, g: ^Gather, list: ^core.Edit_List, values, keys: []string, spec: json.Spec, second: ^Second, x: ^Touched) -> bool {
	switch rand.int_max(4) {
	case 0, 1:
		// A set of a value, or sometimes of a key.
		if len(g.keys) > 0 && rand.int_max(4) == 0 {
			ref := g.keys[rand.int_max(len(g.keys))]
			text := keys[rand.int_max(len(keys))]
			if e := core.set(list, ref.node, transmute([]u8)text); e.kind == .None {
				if m := model_key_at(want, ref.node); m != nil {
					if v, ok := key_value(transmute([]u8)text, spec); ok {
						m.key = v
					}
				}
				touch_node(x, ref.node)
			}
			return true
		}
		if len(g.values) == 0 {
			return true
		}
		ref := g.values[rand.int_max(len(g.values))]
		text := values[rand.int_max(len(values))]
		if e := core.set(list, ref.node, transmute([]u8)text); e.kind != .None {
			return true
		}
		m := model_at(want, ref.node)
		if m == nil {
			return false
		}
		v, ok := model_text(transmute([]u8)text, spec)
		if !ok {
			return false
		}
		v.node = m.node
		v.key = m.key
		v.key_node = m.key_node
		v.ord = m.ord
		m^ = v
		touch_node(x, ref.node)
		take_second(second, 0, ref.node, 0, "", "", text, ref.path)
	case 2:
		if len(g.containers) == 0 {
			return true
		}
		ref := g.containers[rand.int_max(len(g.containers))]
		m := model_at(want, ref.node)
		if m == nil {
			return false
		}
		text := values[rand.int_max(len(values))]
		v, ok := model_text(transmute([]u8)text, spec)
		if !ok {
			return false
		}
		at := rand.int_max(len(m.kids) + 1)
		if ref.kind == .Array {
			if e := core.insert(list, ref.node, at, transmute([]u8)text); e.kind != .None {
				return true
			}
			model_insert(m, at, v, "", false)
			touch_container(x, ref.node)
			take_second(second, 1, ref.node, at, "", "", text, ref.path)
		} else {
			key := keys[rand.int_max(len(keys))]
			if e := core.insert(list, ref.node, at, transmute([]u8)key, transmute([]u8)text); e.kind != .None {
				return true
			}
			name, ok2 := key_value(transmute([]u8)key, spec)
			if !ok2 {
				return false
			}
			model_insert(m, at, v, name, true)
			touch_container(x, ref.node)
			// The current tree appends a member, so only the last place can be checked against it.
			if at == len(m.kids) - 1 {
				take_second(second, 2, ref.node, at, name, key, text, ref.path)
			}
		}
	case 3:
		if len(g.members) == 0 {
			return true
		}
		ref := g.members[rand.int_max(len(g.members))]
		if e := core.remove(list, ref.node); e.kind != .None {
			return true
		}
		parent, index := model_parent(want, ref.node)
		if parent == nil {
			return false
		}
		path := parent.kids[index].path
		model_remove(parent, index)
		take_second(second, 3, ref.node, 0, "", "", "", path)
	}
	return true
}

// Keeps the round's first expressible edit, which the current tree is asked for as well.
@(private)
take_second :: proc(s: ^Second, kind: u8, node: u32, at: int, key, key_text, text, path: string) {
	if !s.ok || s.set {
		return
	}
	s.set = true
	s.kind = kind
	s.node = node
	s.at = at
	s.key = key
	s.key_text = key_text
	s.text = text
	s.path = path
}

// Applies one edit of the round through the current tree's `set`, `insert` or `remove`, and checks that both results
// read as the same tree.
@(private)
second_check :: proc(t: ^testing.T, doc: ^core.Document, s: ^Second, spec: json.Spec, refused, checked, parted: ^int) -> bool {
	one := core.edit_list_init(doc)
	defer core.edit_list_destroy(&one)
	switch s.kind {
	case 0:
		if e := core.set(&one, s.node, transmute([]u8)s.text); e.kind != .None {
			return true
		}
	case 1:
		if e := core.insert(&one, s.node, s.at, transmute([]u8)s.text); e.kind != .None {
			return true
		}
	case 2:
		if e := core.insert(&one, s.node, s.at, transmute([]u8)s.key_text, transmute([]u8)s.text); e.kind != .None {
			return true
		}
	case 3:
		if e := core.remove(&one, s.node); e.kind != .None {
			return true
		}
	}
	our, _, oerr := core.commit(&one)
	if oerr.kind != .None {
		return true
	}
	defer delete(our)
	opts := cur.Read_Opts{dialect = cur.Dialect(spec)}
	found: []byte
	ferr: Maybe(cur.Path_Error)
	switch s.kind {
	case 0:
		found, ferr = cur.set(doc.src, s.path, cur.Raw(s.text), opts)
	case 1:
		found, ferr = cur.insert(doc.src, s.path, s.at, cur.Raw(s.text), opts)
	case 2:
		found, ferr = cur.insert(doc.src, s.path, s.key, cur.Raw(s.text), opts)
	case 3:
		found, ferr = cur.remove(doc.src, s.path, opts)
	}
	if ferr != nil {
		refused^ += 1
		return true
	}
	defer delete(found)
	checked^ += 1
	theirs, terr := build_spec(found, spec)
	if terr.kind != .None {
		parted^ += 1
		return true
	}
	defer core.destroy(&theirs)
	ours, berr := build_spec(our, spec)
	if berr.kind != .None {
		return testing.expectf(t, false, "our commit does not read: %v", berr)
	}
	defer core.destroy(&ours)
	m := model_of(&ours, core.ROOT, ".")
	return model_agrees(t, m, &theirs, core.ROOT, "current tree")
}

// Fills `node_at` with the node each model value reads as after the edits, so a fact's node is carried across an
// insert or a removal.
@(private)
map_nodes :: proc(m: ^Edit_Model, doc: ^core.Document, r: u32, node_at: []u32) {
	if int(m.node) < len(node_at) {
		node_at[m.node] = r
	}
	if m.kind == .Array || m.kind == .Map {
		it := core.children(doc, r)
		for i in 0 ..< len(m.kids) {
			v, ok := core.child_next(&it)
			if !ok {
				return
			}
			map_nodes(&m.kids[i], doc, v, node_at)
		}
	}
}

// Returns true if an unused entry of `got` is the fact of `node`, `role` and `body`, and marks it used.
@(private)
fact_find :: proc(got: []walktest.Fact_Model, used: []bool, node: u32, role: core.Role, body: string) -> bool {
	for g, i in got {
		if !used[i] && g.node == node && g.role == role && g.body == body {
			used[i] = true
			return true
		}
	}
	return false
}

// Records up to 3 fact edits on the round's list, a set or a removal on a node that is no key and no `End`, and
// returns the facts the document had before.
@(private)
fact_edits :: proc(t: ^testing.T, round: int, doc: ^core.Document, list: ^core.Edit_List) -> (before: [dynamic]walktest.Fact_Model, ok: bool) {
	before = make([dynamic]walktest.Fact_Model, 0, 8, context.temp_allocator)
	walktest.fact_model(doc, &before)
	for _ in 0 ..< 1 + rand.int_max(3) {
		node := u32(rand.int_max(len(doc.nodes)))
		n := doc.nodes[node]
		if n.role == .Key || n.kind == .End || walktest.tree_touched(doc, list, node) {
			continue
		}
		role := walktest.FACT_ROLES[rand.int_max(len(walktest.FACT_ROLES))]
		if rand.int_max(2) == 0 {
			e := core.remove_fact(list, node, role)
			if e.kind == .Conflicting_Edits {
				continue
			}
			if !testing.expectf(t, e.kind == .None, "round %d: remove fact: %v", round, e) {
				return before, false
			}
			continue
		}
		body := walktest.FACT_BODIES[rand.int_max(len(walktest.FACT_BODIES))]
		e := core.set_fact(list, node, role, transmute([]u8)body)
		if e.kind == .Bad_Fact || e.kind == .Conflicting_Edits {
			continue
		}
		if !testing.expectf(t, e.kind == .None, "round %d: set fact: %v", round, e) {
			return before, false
		}
	}
	return before, true
}

// Checks that every fact of a node no edit names reads back on the same value, in the same role, with the same body, or
// is covered by the commit's dropped count. `kept` is the number of such facts.
@(private)
fact_check :: proc(t: ^testing.T, round: int, before: []walktest.Fact_Model, list: ^core.Edit_List, doc: ^core.Document, want: ^Edit_Model, read: ^core.Document, dropped: int) -> (ok: bool, kept: int) {
	node_at := make([]u32, len(doc.nodes), context.temp_allocator)
	for i in 0 ..< len(node_at) {
		node_at[i] = core.NO_NODE
	}
	map_nodes(want, read, core.ROOT, node_at)
	got: [dynamic]walktest.Fact_Model
	walktest.fact_model(read, &got)
	defer delete(got)
	used := make([]bool, len(got), context.temp_allocator)
	missing: int
	for f in before {
		if walktest.fact_touched(doc, list, f.node, f.lo) {
			continue
		}
		kept += 1
		if rn := node_at[f.node]; rn == core.NO_NODE || !fact_find(got[:], used, rn, f.role, f.body) {
			missing += 1
			if dropped == 0 {
				testing.expectf(t, false, "round %d: kept fact node %d -> %d role %v body %q is missing", round, f.node, node_at[f.node], f.role, f.body)
				for b in before {
					fmt.printfln("    before node %d role %v body %q", b.node, b.role, b.body)
				}
				for g in got {
					fmt.printfln("    got node %d role %v body %q", g.node, g.role, g.body)
				}
			}
		}
	}
	if dropped == 0 {
		return testing.expectf(t, missing == 0, "round %d: %d kept facts missing of %d, no drop", round, missing, kept), kept
	}
	return testing.expectf(t, missing <= dropped, "round %d: %d kept facts missing of %d, dropped %d", round, missing, kept, dropped), kept
}

// Returns true if every object in the tree has unique keys, so a path names one value.
@(private)
unique_keys :: proc(m: ^Edit_Model) -> bool {
	if m.kind == .Map {
		for i in 0 ..< len(m.kids) {
			for j in i + 1 ..< len(m.kids) {
				if m.kids[i].key == m.kids[j].key {
					return false
				}
			}
		}
	}
	for i in 0 ..< len(m.kids) {
		if !unique_keys(&m.kids[i]) {
			return false
		}
	}
	return true
}
