package dsv

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Table build of a delimited text. The walk gives each cell its column's key, which the builder's table hook drops.
// The header is stored once past the root value's nodes, widened by a key for each column a ragged record names by its
// position. The table, its key slots and the build's policy for repeated keys are the document's `Tabular_Ext`.

// The node capacity a build starts with, in bytes of text per node. A cell of one byte and its delimiter take a node per
// two bytes, so a table of short cells seldom grows the room it starts with, and `builder_end` gives back the room a
// table of longer cells leaves unused.
@(private)
BUILD_BYTES_PER_NODE :: 2

// The fewest header keys for which a table keeps key slots. With slots, a row's readers find a key by hash rather than
// by comparing each. A slot holds its key's column plus one in a `u32`, 0 for none, and the slots number a power of two
// at least twice the keys, so the table is at most half full.
@(private)
SLOTTED_KEYS :: 8

// Stores the header past the root value's nodes: an `Array` of role `Key` of its keys, and one key more for each
// column a record past the header's width names by its position. False when the room cannot grow.
@(private, cold)
append_header :: proc(b: ^build.Builder, regs: ^hook.Regs, head: Head) -> bool {
	t := tape.Token{lo = head.keys[0].lo, kind = .Array, role = .Key}
	return build.builder_append(b, regs, t, head.keys, max(head.widest, len(head.keys)), column_key)
}

// Stores the header past the root value's nodes of the settled document `doc`, as `append_header` stores it in a build:
// an `Array` of role `Key` of `keys`, widened to `wide` keys by one for each column past them, named by its place. The
// header is written in place when the block of `doc.nodes` has `room` nodes more past them and the header fits in
// them, else the nodes move to a new block. On a refused allocation `doc` is destroyed.
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

// Writes the document's table: its header, first row, width and key slots, the options it was read with, and the
// policy `dups` by which its rows read repeated keys. `.Refuse` refuses at the first key the header repeats, and a key named by its place repeats none. A text
// read with `.Ragged` has no common width, and a text with no record has no row. With `cut` the last row may be one
// read only in part, and a last row of another width than the header's, or the first row's with no header, leaves the
// table no common width.
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
	slots_len := slots_for(len(keys)) if len(keys) >= SLOTTED_KEYS else 0
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
	if dups == .Refuse && repeat >= 0 && keys[repeat].spelling & tape.SPELLING_PLACED == 0 {
		at := key_start(doc.src, keys[repeat])
		tape.destroy(doc)
		return tape.Fault{at = at, rules = &RULES, kind = .Duplicate_Key}
	}
	return nil
}

// Returns `err` of a build of `src` under `p`. Under `.Refuse` it returns instead the fault of a repeated header key
// of `keys` when that comes before the fault `err`. A fault past the header's line means the walk filled every key.
// The header's line ends at `head_end` when it is given, as in a text in pieces, whose `src` is the header alone.
@(private, cold)
repeat_first :: proc(err: tape.Error, src: []u8, $S: Spec, p: Pass_Options, keys: []tape.Token, opts: Options, allocator: runtime.Allocator, head_end := -1) -> tape.Error {
	fault, faulted := err.(tape.Fault)
	if !faulted || opts.dups != .Refuse || len(keys) < 2 {
		return err
	}
	end := head_end
	if end < 0 {
		end = scan_record(src, record_start(src, int(text_start(src, 0)), p.comment), 0, S, p.delim).line_end
	}
	if fault.at <= u64(end) {
		return err
	}
	at, found, oom := header_repeat(src, S, keys, allocator)
	if oom != nil {
		return oom
	}
	if found && at < fault.at {
		return tape.Fault{at = at, rules = &RULES, kind = .Duplicate_Key}
	}
	return err
}

// Returns the offset of the first header key of `keys`, cells of `src`, that repeats an earlier one, and whether there
// is one. A key named by its place repeats none.
@(private, cold)
header_repeat :: proc(src: []u8, $S: Spec, keys: []tape.Token, allocator: runtime.Allocator) -> (at: u64, found: bool, err: runtime.Allocator_Error) {
	n := slots_for(len(keys))
	slots, e := make([]u32, n, allocator)
	if err = build.took(e, raw_data(slots), n); err != nil {
		return
	}
	defer delete(slots, allocator)
	doc := tape.Document{src = src, format = &FORMATS[S]}
	if r := fill_slots(&doc, keys, slots); r >= 0 && keys[r].spelling & tape.SPELLING_PLACED == 0 {
		return key_start(src, keys[r]), true, nil
	}
	return
}

// Under `.Refuse`, the fault of a header that repeats a name, which a read of a whole text that builds no table judges
// before it walks, as a build does, or nil. A text in pieces judges its header when a window first holds it.
@(private, cold)
refuse_repeat :: proc(src: []u8, $S: Spec, opts: Options, allocator: runtime.Allocator) -> tape.Error {
	p := options_resolved(S, opts)
	if opts.dups != .Refuse || opts.pieces != nil || p.no_header {
		return nil
	}
	return header_fault(src, S, p, allocator)
}

// The fault of a repeated name among the header's keys of `src`, a text that holds the header's line, or nil. A header
// that itself faults gives none, the read reporting that fault.
@(private, cold)
header_fault :: proc(src: []u8, $S: Spec, p: Pass_Options, allocator: runtime.Allocator) -> tape.Error {
	room: [FRAME_KEYS]tape.Token = ---
	ctx := context
	keys := header_keys(header_cells(src, S, p.delim, p.comment), room[:], allocator, &ctx) or_return
	defer if len(keys) > len(room) {
		delete(keys, allocator)
	}
	if len(keys) < 2 {
		return nil
	}
	if _, _, err := read_header(src, S, p, keys); err != nil {
		return nil
	}
	at, found, oom := header_repeat(src, S, keys, allocator)
	if oom != nil {
		return oom
	}
	return tape.Fault{at = at, rules = &RULES, kind = .Duplicate_Key} if found else nil
}

// The slots of a table of `keys` keys: a power of two at least twice them.
@(private)
slots_for :: proc "contextless" (keys: int) -> int {
	n := 2
	for n < 2 * keys {
		n *= 2
	}
	return n
}

// The first byte of header key `k` of `src`, its opening quote when it has one.
@(private)
key_start :: proc "contextless" (src: []u8, k: tape.Token) -> u64 {
	head, _ := quotes(src, k)
	return k.lo - u64(head)
}

// Whether a built document holds a header, which a build stores past the root value's nodes.
@(private)
headed :: #force_inline proc "contextless" (doc: ^tape.Document) -> bool {
	return len(doc.nodes) > int(doc.nodes[0].n)
}

// The `finish` of a build of a table: its header, when it has one, and its slots.
@(private)
finish_built :: proc(doc: ^tape.Document, opts: Options, rules: ^tape.Rules) -> tape.Error {
	return finish_table(doc, headed(doc), opts)
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

// Fills `slots`, a power of two of them or none, by hash with each key's column plus one, for the first column of each
// key only. Returns the column of the first key that repeats an earlier one, or -1.
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
