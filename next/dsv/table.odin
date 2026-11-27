package dsv

import "base:runtime"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Table build of a delimited text. The walk gives each cell its column's key, which the builder's table hook drops.
// The header is stored once in the document's `Tabular_Ext`, widened by a key for each column a ragged record names by
// its position, with the table, its key slots and the build's policy for repeated keys.

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

// The `Doc_Ext` of a table in one block: its table, the `wide` keys of its header, which are `keys` widened by a key
// named by its place for each column past them, and room for the key slots, which `finish_table` fills. A refused
// allocation is the error.
@(private, cold)
table_ext :: proc(allocator: runtime.Allocator, keys: []tape.Token, wide: int) -> (ext: ^tape.Doc_Ext, err: runtime.Allocator_Error) {
	slots_len := slots_for(wide) if wide >= SLOTTED_KEYS else 0
	table_at := size_of(tape.Doc_Ext) + wide * size_of(tape.Node)
	slots_at := table_at + size_of(tape.Table)
	size := slots_at + slots_len * size_of(u32)
	raw, aerr := runtime.mem_alloc(size, align_of(tape.Doc_Ext), allocator)
	if err = build.took(aerr, raw_data(raw), size); err != nil {
		return
	}
	ext = (^tape.Doc_Ext)(raw_data(raw))
	list := ([^]tape.Node)(raw_data(raw[size_of(tape.Doc_Ext):]))[:wide]
	for c in 0 ..< wide {
		list[c] = column_key(keys, c)
	}
	table := (^tape.Table)(raw_data(raw[table_at:]))
	table^ = {keys_n = u32(wide), slots_len = u32(slots_len)}
	ext.format = tape.Tabular_Ext{tables = ([^]tape.Table)(table)[:1], keys = list, slots = ([^]u32)(raw_data(raw[slots_at:]))[:slots_len]}
	return
}

// Gives the build `h` the table of the header of `head`, which `finish_built` completes.
@(private, cold)
store_header :: proc(h: ^build.Builder, allocator: runtime.Allocator, head: Head) -> tape.Error {
	ext := table_ext(allocator, head.keys, max(head.widest, len(head.keys))) or_return
	h.doc.ext = ext
	return nil
}

// Attaches header `keys` (widened to `wide`) when non-empty, then finishes `doc`'s table.
@(private, cold)
attach_and_finish_table :: proc(doc: ^tape.Document, keys: []tape.Token, wide: int, opts: Options, cut := false) -> tape.Error {
	if len(keys) > 0 {
		ext, err := table_ext(doc.allocator, keys, max(wide, len(keys)))
		if err != nil {
			tape.destroy(doc)
			return err
		}
		doc.ext = ext
	}
	return finish_table(doc, opts, cut)
}

// Completes the document's table, which a build gave its header with `store_header`: its first row, width and key
// slots, the options it was read with, and the policy `dups` by which its rows read repeated keys. `.Refuse` refuses
// at the first key the header repeats, and a key named by its place repeats none. A text read with `.Ragged` has no
// common width, and a text with no record has no row. With `cut` the last row may be one read only in part, and a
// last row of another width than the header's, or the first row's with no header, leaves the table no common width.
@(private)
finish_table :: proc(doc: ^tape.Document, opts: Options, cut := false) -> tape.Error {
	dups := opts.dups
	if doc.ext == nil {
		ext, err := table_ext(doc.allocator, nil, 0)
		if err != nil {
			tape.destroy(doc)
			return err
		}
		doc.ext = ext
	}
	ext := &doc.ext.format.(tape.Tabular_Ext)
	table := &ext.tables[0]
	keys := ext.keys
	rows := int(doc.nodes[0].n) - 1
	table.first_row = 1
	if .Ragged not_in opts.tolerate && rows > 0 {
		table.width = u32(len(keys)) if len(keys) > 0 else doc.nodes[1].n - 1
		if cut && doc.nodes[last_row(doc)].n - 1 != table.width {
			table.width = 0
		}
	}
	repeat := fill_slots(doc, keys, ext.slots)
	table.unique_keys = b32(len(keys) > 0 && repeat < 0)
	d, _ := opts.format.(tape.Dsv_Options)
	d.delimiter = spec_delimiter(spec_of(doc.format), d.delimiter)
	ext.dups, ext.options = dups, d
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
	return tape.Fault{at = at, rules = &RULES, kind = .Duplicate_Key} if found && at < fault.at else err
}

// The duplicate-key fault (or OOM) among header `keys` of `src`, or nil.
@(private, cold)
repeat_fault :: proc(src: []u8, $S: Spec, keys: []tape.Token, allocator: runtime.Allocator) -> tape.Error {
	at, found, oom := header_repeat(src, S, keys, allocator)
	if oom != nil {
		return oom
	}
	return tape.Fault{at = at, rules = &RULES, kind = .Duplicate_Key} if found else nil
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
	return nil if opts.dups != .Refuse || opts.pieces != nil || p.no_header else header_fault(src, S, p, allocator)
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
	return repeat_fault(src, S, keys, allocator)
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

// The `finish` of a build of a table: its first row, width and slots.
@(private)
finish_built :: proc(doc: ^tape.Document, opts: Options, rules: ^tape.Rules) -> tape.Error {
	return finish_table(doc, opts)
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
