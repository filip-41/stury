package dsv

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// A build of a delimited text, as a table: the walk gives each cell its column's key, which the builder's table hook
// drops, and the header is stored once past the root value's nodes, widened by a key for each column a ragged record
// names by its position. The table, its key slots and the build's policy for repeated keys are the document's
// `Tabular_Ext`.

// The node capacity a build starts with: one node per this many bytes of the text.
@(private)
BUILD_BYTES_PER_NODE :: 4

// The fewest header keys for which a table keeps key slots, past which a row's readers find a key by hash rather than
// by comparing each.
@(private)
SLOTTED_KEYS :: 8

@(private)
build_as :: #force_no_inline proc(src: []u8, $S: Spec, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	if _, refused := pass_options(S, opts); refused != nil {
		return {}, refused
	}
	if opts.runner != nil && opts.runner.threads > 0 && opts.pieces == nil && len(src) >= build.PARALLEL_FROM {
		return build_parallel(src, S, opts, caller)
	}
	if build.read_lax(opts) {
		return build_walk(src, S, true, opts, caller)
	}
	return build_walk(src, S, false, opts, caller)
}

@(private)
build_walk :: #force_inline proc(src: []u8, $S: Spec, $LAX: bool, opts: Options, caller: runtime.Allocator) -> (tape.Document, tape.Error) {
	when LAX {
		if opts.pieces != nil {
			return build_pieces(src, S, opts, caller)
		}
	}
	walk :: proc "contextless" (src: []u8, opts: Options, h: ^build.Builder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> (u64, tape.Error, bool) {
		context = ctx^
		p, _ := pass_options(S, opts)
		room: [FRAME_KEYS]tape.Token = ---
		head: Head
		if !p.no_header {
			err: tape.Error
			if head.keys, err = keys_room(src, S, p, room[:], a); err != nil {
				return 0, err, false
			}
		}
		defer if len(head.keys) > len(room) {
			delete(head.keys, a)
		}
		root_close, err, tolerated := walk_text(src, S, LAX, p, h, regs, a, ctx, build.builder_hook_rows, &head, opts.budget.steps)
		if err == nil && len(head.keys) > 0 && !append_header(h, regs, head, a) {
			err = build.builder_error(h)
		}
		return root_close, err, tolerated
	}
	finish :: proc(doc: ^tape.Document, opts: Options, rules: ^tape.Rules) -> tape.Error {
		return finish_table(doc, len(doc.nodes) > int(doc.nodes[0].n), opts)
	}
	return build.read_build(src, &FORMATS[S], &RULES, opts, caller, node_bound, walk, finish, BUILD_BYTES_PER_NODE)
}

// The buffer for the header's keys: `room` when they fit it, else a block of `allocator`.
@(private)
keys_room :: proc(src: []u8, $S: Spec, p: Pass_Options, room: []tape.Token, allocator: runtime.Allocator) -> ([]tape.Token, tape.Error) {
	count := header_cells(src, int(text_start(src, 0)), S, p.delim, p.comment)
	if count <= len(room) {
		return room[:count], nil
	}
	keys, err := make([]tape.Token, count, allocator)
	if e := build.took(err, raw_data(keys), count); e != nil {
		return nil, e
	}
	return keys, nil
}

// Stores the header past the root value's nodes: an `Array` of role `Key` of its keys, and one key more for each
// column a record past the header's width names by its position. False when the room cannot grow.
@(private, cold)
append_header :: proc(b: ^build.Builder, regs: ^hook.Regs, head: Head, allocator: runtime.Allocator) -> bool {
	t := tape.Token{lo = head.keys[0].lo, kind = .Array, role = .Key}
	if head.widest <= len(head.keys) {
		return build.builder_append(b, regs, t, head.keys)
	}
	wide, err := make([]tape.Token, head.widest, allocator)
	if build.took(err, raw_data(wide), head.widest) != nil {
		b.err = .Out_Of_Memory
		return false
	}
	defer delete(wide, allocator)
	copy(wide, head.keys)
	for c in len(head.keys) ..< head.widest {
		wide[c] = column_key(head.keys, c)
	}
	return build.builder_append(b, regs, t, wide)
}

// Stores the header past the root value's nodes of the settled document `doc`, as `append_header` stores it in a build:
// an `Array` of role `Key` of `keys`, widened to `wide` keys by one for each column past them, named by its place. The
// header is written in place when the block of `doc.nodes` holds `room` nodes more past them and they hold it, else
// the nodes move to a block of their own. On a refused allocation `doc` is destroyed.
@(private, cold)
append_keys :: proc(doc: ^tape.Document, keys: []tape.Token, wide, room: int) -> tape.Error {
	at := len(doc.nodes)
	nodes := ([^]tape.Node)(raw_data(doc.nodes))[:at + 1 + wide]
	if 1 + wide > room {
		err: runtime.Allocator_Error
		nodes, err = make([]tape.Node, at + 1 + wide, doc.allocator)
		if e := build.took(err, raw_data(nodes), len(nodes)); e != nil {
			tape.destroy(doc)
			return e
		}
		copy(nodes, doc.nodes)
		delete(doc.nodes, doc.allocator)
	}
	doc.nodes = nodes
	nodes[at] = {lo = keys[0].lo, n = u32(wide + 1), kind = .Array, role = .Key, spelling = u16(min(wide, int(tape.MAX_CHILDREN)))}
	for c in 0 ..< wide {
		nodes[at + 1 + c] = column_key(keys, c)
	}
	if wide >= int(tape.MAX_CHILDREN) {
		counts, cerr := make([]tape.Child_Count, len(doc.counts) + 1, doc.allocator)
		if e := build.took(cerr, raw_data(counts), len(counts)); e != nil {
			tape.destroy(doc)
			return e
		}
		copy(counts, doc.counts)
		counts[len(doc.counts)] = {tape.Node_Index(at), u32(wide)}
		delete(doc.counts, doc.allocator)
		doc.counts = counts
	}
	return nil
}

// Writes the document's table: its header, first row, width and key slots, the options it was read with, and the policy `dups` its rows read
// repeated keys by, which `.Refuse` refuses at the first key the header repeats. A text read with `.Ragged` has no
// common width, and a text with no record has no row. With `cut` the last row may be one read only in part, and a
// table whose last row is shorter than its first has no common width.
@(private)
finish_table :: proc(doc: ^tape.Document, headed: bool, opts: Options, cut := false) -> tape.Error {
	dups := opts.dups
	header := tape.Node_Index(0)
	keys: []tape.Node
	if headed {
		header = tape.node_after(doc, tape.ROOT)
		keys = doc.nodes[header + 1:][:doc.nodes[header].n - 1]
	}
	rows := int(doc.nodes[0].n) - 1
	slots_len := 0
	if len(keys) >= SLOTTED_KEYS {
		slots_len = 2
		for slots_len < 2 * len(keys) {
			slots_len *= 2
		}
	}
	size := size_of(tape.Doc_Ext) + size_of(tape.Table) + slots_len * size_of(u32)
	raw, err := runtime.mem_alloc(size, align_of(tape.Doc_Ext), doc.allocator)
	if e := build.took(err, raw_data(raw), size); e != nil {
		tape.destroy(doc)
		return e
	}
	ext := (^tape.Doc_Ext)(raw_data(raw))
	table := (^tape.Table)(raw_data(raw[size_of(tape.Doc_Ext):]))
	slots := ([^]u32)(raw_data(raw[size_of(tape.Doc_Ext) + size_of(tape.Table):]))[:slots_len]
	table^ = {header = header, first_row = 1 if rows > 0 else tape.Node_Index(len(doc.nodes)), slots_lo = 0, slots_len = u32(slots_len)}
	if .Ragged not_in opts.tolerate && rows > 0 {
		table.width = u32(len(keys)) if headed else doc.nodes[1].n - 1
		if cut && doc.nodes[last_row(doc)].n - 1 != table.width {
			table.width = 0
		}
	}
	repeat := fill_slots(doc, keys, slots)
	table.unique_keys = b32(headed && repeat < 0)
	d, _ := opts.format.(tape.Dsv_Options)
	d.delimiter = spec_delimiter(spec_of(doc.format), d.delimiter)
	ext.format = tape.Tabular_Ext{tables = ([^]tape.Table)(table)[:1], slots = slots, dups = dups, options = d}
	doc.ext = ext
	if dups == .Refuse && repeat >= 0 {
		k := keys[repeat]
		head, _ := quotes(doc.src, k)
		at := k.lo - u64(head)
		tape.destroy(doc)
		return tape.Fault{at = at, rules = &RULES, kind = .Duplicate_Key}
	}
	return nil
}

// The node of the root's last row.
@(private)
last_row :: proc(doc: ^tape.Document) -> tape.Node_Index {
	at, end := tape.Node_Index(1), tape.Node_Index(doc.nodes[0].n)
	for at + tape.Node_Index(doc.nodes[at].n) < end {
		at += tape.Node_Index(doc.nodes[at].n)
	}
	return at
}

// Fills `slots`, a power of two of them or none, with each key's column plus one by its hash, each key's first column
// only, and returns the first key that repeats one before it, or -1.
@(private)
fill_slots :: proc(doc: ^tape.Document, keys: []tape.Node, slots: []u32) -> int {
	f := doc.format
	if len(slots) == 0 {
		for k, i in keys {
			for o in keys[:i] {
				if same_key(f, doc.src, k, o) {
					return i
				}
			}
		}
		return -1
	}
	repeat := -1
	mask := u32(len(slots) - 1)
	next: for k, col in keys {
		i := f.key_hash(doc.src, k) & mask
		for ; slots[i] != 0; i = (i + 1) & mask {
			if same_key(f, doc.src, k, keys[slots[i] - 1]) {
				if repeat < 0 {
					repeat = col
				}
				continue next
			}
		}
		slots[i] = u32(col + 1)
	}
	return repeat
}

// Whether keys `a` and `b` of `src` read as the same text.
@(private)
same_key :: #force_inline proc(f: ^tape.Format, src: []u8, a, b: tape.Node) -> bool {
	if a.spelling & tape.SPELLING_DECODE == 0 && b.spelling & tape.SPELLING_DECODE == 0 {
		return string(src[a.lo:][:a.n]) == string(src[b.lo:][:b.n])
	}
	return f.same_text(src, a, src, b)
}
