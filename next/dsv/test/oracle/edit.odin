// Compares the edit list against a table of cells: a random text is read into a plain tree of records and cells, the
// same edits are applied to the tree and to a list over the document, and the committed text must build as the tree.
// `make test-oracle` builds it from a copy of next/.
package dsv_oracle

import "base:intrinsics"
import "core:fmt"
import "core:math/rand"
import "core:strings"
import "core:testing"
import core "../../../core"
import dsv "../.."
import gen "../gen"
import walktest "../../../walktest"

// A `Cell_Model` holds a record or a cell as a plain tree: a record's cells in order, or a cell's decoded text. `node`
// labels an edit's target. `rank` orders a member against the source's members: an original member `i` has rank `2*i`,
// and a member inserted at index `at` has rank `2*at - 1`, so an insert comes before original member `at` and after
// every member with a lower `at`.
Cell_Model :: struct {
	kind: core.Kind,
	text: string,
	node: u32,
	rank: int,
	kids: []Cell_Model,
}

@(private)
model_of :: proc(doc: ^core.Document, i: u32) -> Cell_Model {
	m := Cell_Model{kind = core.kind(doc, i), node = i}
	#partial switch m.kind {
	case .Plain:
		buf: [4096]u8
		if s, ok := core.text(doc, i, buf[:], context.temp_allocator); ok {
			m.text = strings.clone(s, context.temp_allocator)
		}
	case .Array:
		kids := make([dynamic]Cell_Model, 0, 4, context.temp_allocator)
		it := core.children(doc, i)
		index := 0
		for {
			v, ok := core.child_next(&it)
			if !ok {
				break
			}
			kid := model_of(doc, v)
			kid.rank = 2 * index
			append(&kids, kid)
			index += 1
		}
		m.kids = kids[:]
	}
	return m
}

// Clears every node of a tree read from `text`, so an edit cannot target it and its labels do not collide with the
// document's.
@(private)
detach :: proc(m: ^Cell_Model) {
	m.node = core.NO_NODE
	m.rank = 0
	for i in 0 ..< len(m.kids) {
		detach(&m.kids[i])
	}
}

// Builds a document under the spec and dialect a round drew at run time.
@(private)
build_spec :: proc(text: []u8, spec: dsv.Spec, opts: dsv.Options) -> (core.Document, core.Document_Error) {
	switch spec {
	case .Csv:
		return dsv.build(text, .Csv, opts)
	case .Tsv:
		return dsv.build(text, .Tsv, opts)
	case .Plain:
		return dsv.build(text, .Plain, opts)
	}
	return {}, {kind = .Bad_Value}
}

@(private)
build_one :: proc(text: []u8, spec: dsv.Spec, opts: dsv.Options) -> (core.Document, core.Document_Error) {
	one := opts
	one.no_header = true
	return build_spec(text, spec, one)
}

// Returns a cell text as a tree: a record of one cell, or the empty cell.
@(private)
model_cell :: proc(text: []u8, spec: dsv.Spec, opts: dsv.Options) -> (Cell_Model, bool) {
	if len(text) == 0 {
		return Cell_Model{kind = .Plain, node = core.NO_NODE, rank = 0}, true
	}
	doc, err := build_one(text, spec, opts)
	defer core.destroy(&doc)
	if err.kind != .None || len(doc.nodes) < 3 {
		return {}, false
	}
	record, ok := core.first_child(&doc, core.ROOT)
	if !ok {
		return {}, false
	}
	cell, cell_ok := core.first_child(&doc, record)
	if !cell_ok {
		return {}, false
	}
	m := model_of(&doc, cell)
	detach(&m)
	return m, true
}

// Returns a record text as a tree of cells.
@(private)
model_record :: proc(text: []u8, spec: dsv.Spec, opts: dsv.Options) -> (Cell_Model, bool) {
	doc, err := build_one(text, spec, opts)
	defer core.destroy(&doc)
	if err.kind != .None {
		return {}, false
	}
	record, ok := core.first_child(&doc, core.ROOT)
	if !ok {
		return {}, false
	}
	m := model_of(&doc, record)
	detach(&m)
	return m, true
}

@(private)
model_insert :: proc(m: ^Cell_Model, at: int, kid: Cell_Model) {
	n := len(m.kids)
	pos := n
	rank := 2 * at - 1
	for j in 0 ..< n {
		if m.kids[j].rank > rank {
			pos = j
			break
		}
	}
	out := make([]Cell_Model, n + 1, context.temp_allocator)
	copy(out[:pos], m.kids[:pos])
	out[pos] = kid
	out[pos].rank = rank
	copy(out[pos + 1:], m.kids[pos:])
	m.kids = out
}

@(private)
model_remove :: proc(m: ^Cell_Model, index: int) {
	n := len(m.kids)
	out := make([]Cell_Model, n - 1, context.temp_allocator)
	copy(out[:index], m.kids[:index])
	copy(out[index:], m.kids[index + 1:])
	m.kids = out
}

@(private)
model_at :: proc(m: ^Cell_Model, node: u32) -> ^Cell_Model {
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

@(private)
model_parent :: proc(m: ^Cell_Model, node: u32) -> (^Cell_Model, int) {
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

@(private)
model_agrees :: proc(t: ^testing.T, m: Cell_Model, doc: ^core.Document, i: u32, what: string) -> bool {
	k := core.kind(doc, i)
	if !testing.expectf(t, k == m.kind, "%s: kind %v, model %v", what, k, m.kind) {
		return false
	}
	if k == .Plain {
		buf: [4096]u8
		s, ok := core.text(doc, i, buf[:], context.temp_allocator)
		return testing.expectf(t, ok && s == m.text, "%s: cell %q, model %q", what, s, m.text)
	}
	if !testing.expectf(t, core.length(doc, i) == len(m.kids), "%s: %d cells, model %d", what, core.length(doc, i), len(m.kids)) {
		return false
	}
	it := core.children(doc, i)
	for kid, idx in m.kids {
		v, ok := core.child_next(&it)
		if !testing.expectf(t, ok, "%s: cell %d is missing", what, idx) {
			return false
		}
		if !model_agrees(t, kid, doc, v, fmt.tprintf("%s/%d", what, idx)) {
			return false
		}
	}
	return true
}

// `CELLS_CSV`, `CELLS_TSV` and `CELLS_PLAIN` hold cells spelled as each spec writes them. A CSV quoted cell may hold
// any delimiter, a TSV cell escapes its control bytes, and a Plain cell holds none of the delimiter bytes and reads a
// quote as text. No cell starts with a byte that could open a comment line, so a text is judged as a cell and not as a
// comment.
@(private)
CELLS_CSV := []string{"", "a", "12.5", "x y", "é", `"p,q"`, `"say ""hi"""`, "\"multi\nline\""}
@(private)
CELLS_TSV := []string{"", "a", "12.5", "x y", "é", `\t`, `\n`, `\\`, `x\ty`, `"q"`}
@(private)
CELLS_PLAIN := []string{"", "a", "12.5", "x y", "é", "日本", "😀", `"q"`, `x\y`}

@(private)
cells_of :: proc(spec: dsv.Spec) -> []string {
	switch spec {
	case .Csv:
		return CELLS_CSV
	case .Tsv:
		return CELLS_TSV
	case .Plain:
		return CELLS_PLAIN
	}
	return nil
}

@(private)
Touched :: struct {
	nodes:        [16]u32,
	n_nodes:      int,
	containers:   [16]u32,
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
Ref :: struct {
	node:  u32,
	kind:  core.Kind,
	index: int,
}

// `Gather` holds the edit targets a round may name: a cell, a data record, the table's root, and a container a cell may
// be inserted into. `tables` holds the root, `records` the root's data records.
@(private)
Gather :: struct {
	cells:      [dynamic]Ref,
	records:    [dynamic]Ref,
	tables:     [dynamic]Ref,
	containers: [dynamic]Ref,
}

@(private)
gather_init :: proc(g: ^Gather) {
	g.cells = make([dynamic]Ref, 0, 8, context.temp_allocator)
	g.records = make([dynamic]Ref, 0, 8, context.temp_allocator)
	g.tables = make([dynamic]Ref, 0, 8, context.temp_allocator)
	g.containers = make([dynamic]Ref, 0, 8, context.temp_allocator)
}

// Appends each untouchable node to the pool its depth gives: depth 0 is the table's root, depth 1 a data record, deeper
// a cell.
@(private)
gather :: proc(m: ^Cell_Model, index: int, g: ^Gather, x: ^Touched, depth: int) {
	if m.node != core.NO_NODE && !node_touched(x, m.node) {
		ref := Ref{node = m.node, kind = m.kind, index = index}
		if m.kind == .Plain {
			append(&g.cells, ref)
		} else if depth == 0 {
			append(&g.tables, ref)
		} else {
			append(&g.records, ref)
			if !container_touched(x, m.node) {
				append(&g.containers, ref)
			}
		}
	}
	for i in 0 ..< len(m.kids) {
		gather(&m.kids[i], i, g, x, depth + 1)
	}
}

@(private)
span_lo :: proc(doc: ^core.Document, i: u32) -> u64 {
	return u64(intrinsics.ptr_sub(raw_data(core.span(doc, i)), raw_data(doc.src)))
}

// Returns the byte where an insert into `e.node` at `e.at` is written: the member's first byte, the last member's
// end, or the end of an empty container.
@(private)
insert_pos :: proc(doc: ^core.Document, e: core.Edit) -> (u64, bool) {
	it := core.children(doc, e.node)
	i := 0
	last: u64
	have := false
	for {
		v, ok := core.child_next(&it)
		if !ok {
			break
		}
		if i == int(e.at) {
			lo := span_lo(doc, v)
			hdr_end := u64(0)
			if e.node == core.ROOT && doc.header != 0 {
				hdr_end = doc.spelling.close_end(doc, doc.header)
			}
			// A record's leading comment lines are before it, and the insert is written before them.
			for f in doc.facts {
				if f.node == v && f.role == .Comment && f.lo >= hdr_end && f.lo < lo {
					lo = f.lo
				}
			}
			return lo, true
		}
		last = span_lo(doc, v) + u64(len(core.span(doc, v)))
		have = true
		i += 1
	}
	if have {
		return last, true
	}
	return doc.spelling.close_end(doc, e.node), true
}

// A conflict names a byte an edit writes: a member's first or last byte, the byte an insert is written at, or the byte
// beside a member's extent, where a cut stops at the separator or the line end the member's comments lead.
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
		lo := span_lo(doc, e.node)
		hi := lo + u64(len(core.span(doc, e.node)))
		if at == lo || at == hi || at > lo && at < hi || at + 1 == lo || at == hi + 1 {
			return true
		}
	}
	// A fact edit writes at its node's own bytes: a head before it, an inline after it, a foot before its close.
	for e in edits {
		if e.op < .Set_Fact {
			continue
		}
		lo := span_lo(doc, e.node)
		hi := lo + u64(len(core.span(doc, e.node)))
		if at >= lo && at <= hi + 1 {
			return true
		}
	}
	return testing.expectf(t, false, "round %d: conflict at %d names no edited member", round, at)
}

// Checks that every cell no edit touches appears in `out`, in source order.
@(private)
kept_bytes :: proc(t: ^testing.T, round: int, doc: ^core.Document, out: []u8, edits: []core.Edit) -> bool {
	gone := make([]bool, len(doc.nodes), context.temp_allocator)
	for e in edits {
		if e.op == .Insert {
			continue
		}
		n := doc.nodes[e.node]
		end := int(e.node) + 1
		if n.kind == .Array {
			end = int(e.node) + int(n.n)
		}
		for i := int(e.node); i < min(end, len(doc.nodes)); i += 1 {
			gone[i] = true
		}
	}
	cursor := 0
	for node, i in doc.nodes {
		if gone[i] || node.kind != .Plain {
			continue
		}
		b := core.span(doc, u32(i))
		if len(b) == 0 {
			continue
		}
		found := -1
		for j := cursor; j + len(b) <= len(out); j += 1 {
			if string(out[j:j+len(b)]) == string(b) {
				found = j
				break
			}
		}
		if found < 0 {
			return testing.expectf(t, false, "round %d: kept cell %q is missing from %q", round, b, out)
		}
		cursor = found + len(b)
	}
	return true
}

// `Edit_Kind` names each edit a round's list can hold, for counting rounds. The `_unheaded` kinds count the rounds of
// their kind whose text has no header.
@(private)
Edit_Kind :: enum u8 {
	set_cell,
	insert_record,
	insert_cell,
	remove_record,
	remove_record_unheaded,
	remove_cell,
	set_fact,
	remove_fact,
	remove_all,
	remove_all_unheaded,
}

@(test)
edits_agree_with_table :: proc(t: ^testing.T) {
	state := rand.create(SEED + 13)
	context.random_generator = rand.default_random_generator(&state)
	text: [dynamic]u8
	defer delete(text)
	rounds, refused, conflicted, no_header_rounds, frounds, fnonempty: int
	round_counts: [Edit_Kind]int
	for round in 0 ..< ROUNDS {
		c := pick_case()
		no_header := rand.int_max(4) == 3
		// The generator writes a valid table of the case's spec, delimiter and comment byte. The round's spec,
		// delimiter and comment then judge every recorded cell and record as the read did.
		gen_dialect_text(&text, c)
		opts := dsv.Options{no_header = no_header, delimiter = c.delim, comment = c.comment}
		doc, err := build_spec(text[:], c.spec, opts)
		if err.kind != .None {
			free_all(context.temp_allocator)
			continue
		}
		if no_header {
			no_header_rounds += 1
		}
		root := model_of(&doc, core.ROOT)
		orig_records := len(root.kids)
		disjoint := rand.int_max(4) == 0
		touched: Touched
		list := core.edit_list_init(&doc)
		want := root
		bad := false
		for _ in 0 ..< 1 + rand.int_max(3) {
			g: Gather
			gather_init(&g)
			gather(&want, -1, &g, &touched, 0)
			if !one_edit(t, &want, &g, &list, &doc, c, opts, &touched, no_header, len(doc.nodes) == 1, disjoint) {
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
		fbefore, fok := fact_edits(t, round, &doc, &list, &touched, disjoint)
		if !fok {
			core.edit_list_destroy(&list)
			core.destroy(&doc)
			free_all(context.temp_allocator)
			return
		}
		out, dropped, cerr := core.commit(&list)
		if disjoint && cerr.kind != .None {
			testing.expectf(t, false, "round %d: a disjoint list was refused: %v", round, cerr)
			fmt.printfln("  text %q", text[:])
			for e in list.edits {
				fmt.printfln("  edit %v node %d at %d key %q text %q", e.op, e.node, e.at, e.key, e.text)
			}
			core.edit_list_destroy(&list)
			core.destroy(&doc)
			free_all(context.temp_allocator)
			return
		}
		if cerr.kind != .None {
			conflicted += 1
			if cerr.kind == .Conflicting_Edits && !conflict_agrees(t, round, &doc, list.edits[:], cerr.at) {
				return
			}
			core.edit_list_destroy(&list)
			core.destroy(&doc)
			free_all(context.temp_allocator)
			continue
		}
		rounds += 1
		kinds: bit_set[Edit_Kind]
		for e in list.edits {
			switch e.op {
			case .Set:
				kinds += {.set_cell}
			case .Insert:
				if e.node == core.ROOT {
					kinds += {.insert_record}
				} else {
					kinds += {.insert_cell}
				}
			case .Remove:
				if doc.nodes[e.node].kind == .Plain {
					kinds += {.remove_cell}
				} else {
					kinds += {.remove_record}
				}
			case .Set_Fact:
				kinds += {.set_fact}
			case .Remove_Fact:
				kinds += {.remove_fact}
			}
		}
		if orig_records > 0 && len(want.kids) == 0 {
			kinds += {.remove_all}
		}
		for k in kinds {
			round_counts[k] += 1
		}
		if .remove_record in kinds && no_header {
			round_counts[.remove_record_unheaded] += 1
		}
		if .remove_all in kinds && no_header {
			round_counts[.remove_all_unheaded] += 1
		}
		read, rerr := build_spec(out, c.spec, opts)
		if !testing.expectf(t, rerr.kind == .None, "round %d spec %v no_header %v delim %q comment %q: committed text does not read: %v in %q from %q", round, c.spec, no_header, c.delim, c.comment, rerr, out, text[:]) {
			for e in list.edits {
				fmt.printfln("  edit %v node %d at %d key %q text %q", e.op, e.node, e.at, e.key, e.text)
			}
			return
		}
		if !model_agrees(t, want, &read, core.ROOT, "root") {
			testing.expectf(t, false, "round %d spec %v no_header %v delim %q comment %q: %q -> %q", round, c.spec, no_header, c.delim, c.comment, text[:], out)
			for e in list.edits {
				fmt.printfln("  edit %v node %d at %d key %q text %q", e.op, e.node, e.at, e.key, e.text)
			}
			return
		}
		if !kept_bytes(t, round, &doc, out, list.edits[:]) {
			return
		}
		fokc, fkept := fact_check(t, round, fbefore[:], &list, &doc, &want, &read, dropped, u8(c.spec))
		if !fokc {
			fmt.printfln("  text %q", text[:])
			for e in list.edits {
				fmt.printfln("  edit %v node %d at %d key %q text %q", e.op, e.node, e.at, e.key, e.text)
			}
			return
		}
		if fkept > 0 {
			frounds += 1
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
	fmt.printfln("seed %d: %d rounds (%d without a header), %d refused, %d conflicted, %d fact rounds (%d with a non-empty model)", SEED, rounds, no_header_rounds, refused, conflicted, frounds, fnonempty)
	fmt.printfln("seed %d: rounds set cell %d, insert record %d, insert cell %d, remove record %d (%d without a header), remove cell %d, set fact %d, remove fact %d, remove all records %d (%d without a header)", SEED, round_counts[.set_cell], round_counts[.insert_record], round_counts[.insert_cell], round_counts[.remove_record], round_counts[.remove_record_unheaded], round_counts[.remove_cell], round_counts[.set_fact], round_counts[.remove_fact], round_counts[.remove_all], round_counts[.remove_all_unheaded])
	for k in Edit_Kind {
		testing.expectf(t, round_counts[k] > 0, "no round applied kind %v", k)
	}
	testing.expectf(t, fnonempty > 0, "no round compared a non-empty fact model")
}

@(private)
one_edit :: proc(t: ^testing.T, want: ^Cell_Model, g: ^Gather, list: ^core.Edit_List, doc: ^core.Document, c: Dialect_Case, opts: dsv.Options, x: ^Touched, no_header, empty_table, disjoint: bool) -> bool {
	cells := cells_of(c.spec)
	switch rand.int_max(6) {
	case 0, 1:
		// Sets a cell's text.
		if len(g.cells) == 0 {
			return true
		}
		ref := g.cells[rand.int_max(len(g.cells))]
		if disjoint && !walktest.nodes_disjoint(doc, x.nodes[:x.n_nodes], ref.node) {
			return true
		}
		text := cells[rand.int_max(len(cells))]
		// An empty only cell reads as no record, which dsv refuses with `.Bad_Width`.
		if disjoint && len(text) == 0 {
			if p, _ := model_parent(want, ref.node); p != nil && len(p.kids) == 1 {
				return true
			}
		}
		if e := core.set(list, ref.node, transmute([]u8)text); e.kind != .None {
			if disjoint {
				testing.expectf(t, e.kind == .None, "set cell %d refused: %v", ref.node, e)
				return false
			}
			return true
		}
		m := model_at(want, ref.node)
		if m == nil {
			return false
		}
		v, ok := model_cell(transmute([]u8)text, c.spec, opts)
		if !ok {
			return false
		}
		v.node = m.node
		v.rank = m.rank
		m^ = v
		touch_node(x, ref.node)
	case 2:
		// Inserts a record into the table.
		if len(g.tables) == 0 {
			return true
		}
		ref := g.tables[rand.int_max(len(g.tables))]
		if disjoint && !walktest.nodes_disjoint(doc, x.nodes[:x.n_nodes], ref.node) {
			return true
		}
		m := model_at(want, ref.node)
		if m == nil {
			return false
		}
		// A headed table's first record is its header, so the first record added to an empty table is no data record to
		// the readers.
		if !no_header && empty_table {
			return true
		}
		width := 1 + rand.int_max(3)
		if len(m.kids) > 0 {
			width = len(m.kids[0].kids)
		} else if doc.header != 0 {
			width = core.length(doc, doc.header)
		}
		if width == 0 {
			return true
		}
		line := make([dynamic]u8, 0, 16, context.temp_allocator)
		for col in 0 ..< width {
			if col > 0 {
				append(&line, c.delim)
			}
			text := cells[rand.int_max(len(cells))]
			// A one-cell record of an empty cell is an empty line, which reads as no record.
			if width == 1 && len(text) == 0 {
				text = "a"
			}
			append(&line, ..transmute([]u8)text)
		}
		// An edit's position counts the document's members, which no earlier edit changes.
		at := rand.int_max(core.length(doc, ref.node) + 1)
		if e := core.insert(list, core.ROOT, at, line[:]); e.kind != .None {
			if disjoint {
				testing.expectf(t, e.kind == .None, "insert record at %d refused: %v", at, e)
				return false
			}
			return true
		}
		kid, ok := model_record(line[:], c.spec, opts)
		if !ok {
			return false
		}
		model_insert(m, at, kid)
		touch_container(x, core.ROOT)
		if disjoint {
			touch_node(x, core.ROOT)
		}
	case 3:
		// Inserts a cell into a record.
		if disjoint || len(g.containers) == 0 {
			return true
		}
		ref := g.containers[rand.int_max(len(g.containers))]
		m := model_at(want, ref.node)
		if m == nil {
			return false
		}
		text := cells[rand.int_max(len(cells))]
		at := rand.int_max(core.length(doc, ref.node) + 1)
		if e := core.insert(list, ref.node, at, transmute([]u8)text); e.kind != .None {
			// A cell that makes the record wider than the table is refused when recorded, with `.Bad_Width`.
			if !testing.expectf(t, e.kind == .Bad_Width, "cell insert refused with %v", e) {
				return false
			}
			return true
		}
		kid, ok := model_cell(transmute([]u8)text, c.spec, opts)
		if !ok {
			return false
		}
		model_insert(m, at, kid)
		touch_container(x, ref.node)
	case 4:
		// Removes a record or a cell.
		pool := g.records
		if len(g.cells) > 0 && len(g.records) > 0 && rand.int_max(2) == 0 {
			pool = g.cells
		}
		if len(pool) == 0 {
			return true
		}
		ref := pool[rand.int_max(len(pool))]
		// A cell removal leaves the record narrower than the table, which dsv refuses with `.Bad_Width`.
		if disjoint && (ref.kind == .Plain || !walktest.nodes_disjoint(doc, x.nodes[:x.n_nodes], ref.node)) {
			return true
		}
		if e := core.remove(list, ref.node); e.kind != .None {
			if disjoint {
				testing.expectf(t, e.kind == .None, "remove %d refused: %v", ref.node, e)
				return false
			}
			return true
		}
		parent, index := model_parent(want, ref.node)
		if parent == nil {
			return false
		}
		model_remove(parent, index)
		touch_node(x, ref.node)
		touch_container(x, parent.node)
	case 5:
		// Removes every data record of the table in one list.
		if len(g.records) == 0 {
			return true
		}
		for ref in g.records {
			if disjoint && !walktest.nodes_disjoint(doc, x.nodes[:x.n_nodes], ref.node) {
				return true
			}
		}
		removed := 0
		for ref in g.records {
			if e := core.remove(list, ref.node); !testing.expectf(t, e.kind == .None, "round: remove record %d: %v", ref.node, e) {
				return false
			}
			parent, index := model_parent(want, ref.node)
			if parent == nil {
				return false
			}
			model_remove(parent, index)
			touch_node(x, ref.node)
			touch_container(x, parent.node)
			removed += 1
		}

	}
	return true
}

// Maps each model record or cell to the document node it reads as after the round's edits. A fact's node is carried
// across a record insert or removal this way.
@(private)
map_nodes :: proc(m: ^Cell_Model, doc: ^core.Document, r: u32, node_at: []u32) {
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

// Returns the nodes a fact may name: every record, the last one included, and the root for a foot. A headed text's
// records are `Map`s and an unheaded text's are `Array`s, so both are taken.
@(private)
fact_nodes :: proc(doc: ^core.Document) -> [dynamic]u32 {
	out := make([dynamic]u32, 0, 16, context.temp_allocator)
	append(&out, core.ROOT)
	it := core.children(doc, core.ROOT)
	for {
		v, ok := core.child_next(&it)
		if !ok {
			return out
		}
		n := doc.nodes[v]
		if n.role == .Value && (n.kind == .Array || n.kind == .Map) {
			append(&out, v)
		}
	}
}

// Records a round's fact edits on the round's list: a comment on a record, a foot on the root, and now and then an
// inline fact the output drops.
@(private)
fact_edits :: proc(t: ^testing.T, round: int, doc: ^core.Document, list: ^core.Edit_List, x: ^Touched, disjoint: bool) -> (before: [dynamic]walktest.Fact_Model, ok: bool) {
	before = make([dynamic]walktest.Fact_Model, 0, 8, context.temp_allocator)
	walktest.fact_model(doc, &before)
	pool := fact_nodes(doc)
	for _ in 0 ..< 1 + rand.int_max(3) {
		node := pool[rand.int_max(len(pool))]
		if walktest.tree_touched(doc, list, node, !disjoint) {
			continue
		}
		if disjoint && !walktest.nodes_disjoint(doc, x.nodes[:x.n_nodes], node) {
			continue
		}
		role := core.Role.Comment_Foot
		if node != core.ROOT {
			role = .Comment
			if rand.int_max(5) == 0 {
				role = .Comment_Inline
			}
		} else if doc.header != 0 && rand.int_max(2) == 0 {
			role = .Comment
		}
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

// Checks the round's fact model mapped onto the committed text: each fact's node is carried across the round's record
// edits.
@(private)
fact_check :: proc(t: ^testing.T, round: int, before: []walktest.Fact_Model, list: ^core.Edit_List, doc: ^core.Document, want: ^Cell_Model, read: ^core.Document, dropped: int, spec: u8) -> (ok: bool, kept: int) {
	node_at := make([]u32, len(doc.nodes), context.temp_allocator)
	for i in 0 ..< len(node_at) {
		node_at[i] = core.NO_NODE
	}
	map_nodes(want, read, core.ROOT, node_at)
	return walktest.fact_agrees(t, round, before, doc, list, node_at, read, dropped, spec)
}
