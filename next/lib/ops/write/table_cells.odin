package write

import "core:bytes"
import "core:simd"
import "stury:lib/base/kernel"
import "stury:lib/core/tape"

// Delimited cell classification tables, verbatim/translate runs, cell quoting/escaping, and 16-byte SIMD special-byte
// scanning.

// How a delimited spec spells a cell's text.
Cells :: enum u8 {
	// CSV: a cell is quoted where it must be, and a quote in it doubled.
	Quoted,
	// TSV: a tab, a line end, a backslash and NUL are escaped by a backslash, and no other delimiter can be held.
	Escaped,
	// Plain: no quote and no escape, so a cell cannot hold the delimiter or a line end.
	Bare,
}

// The most bytes a cell's spec must quote, escape or refuse: TSV's delimiter, line ends, tab, backslash and NUL.
@(private)
SPECIAL_MAX :: 6

// Populates the special-byte, leading-byte and SIMD probe tables for `cells` and `d`.
@(private)
init_cell_tables :: proc "contextless" (special, lead: ^[256]bool, probe: ^[SPECIAL_MAX]Lanes16, cells: Cells, d: tape.Dsv_Options) {
	special[d.delimiter], special['\n'], special['\r'] = true, true, true
	switch cells {
	case .Quoted:
		special['"'] = true
	case .Escaped:
		special['\t'], special['\\'], special[0] = true, true, true
	case .Bare:
	}
	n := 0
	for c in 0 ..< 256 {
		if special[c] {
			probe[n] = Lanes16(u8(c))
			n += 1
		}
	}
	for k in n ..< SPECIAL_MAX {
		probe[k] = probe[0]
	}
	if d.comment != 0 {
		lead[d.comment] = true
	}
	lead[0xEF] = true
	if d.infer {
		for c in "tf-0123456789" {
			lead[c] = true
		}
	}
}

// Writes the cell at `at`, the `j`th of its record.
@(private)
put_record_cell :: proc(t: ^Table_Write, at: tape.Node_Index, j: int) -> bool {
	if (t.verbatim || t.translate) && put_verbatim_run(t, at, 1) == 1 {
		return true
	}
	return put_cell_of(t, at, j)
}

// Writes the `cells` cells from node `first` as one record's text, as runs where `put_verbatim_run` takes them.
@(private)
put_verbatim_cells :: proc(t: ^Table_Write, first: tape.Node_Index, cells: int) -> bool {
	// A run that holds a byte the target must spell leaves the rest of the record to `put_cell_of`.
	spelled := false
	for j := 0; j < cells; {
		if j > 0 {
			put_byte(t.out, t.d.delimiter)
		}
		at := first + tape.Node_Index(j)
		k := 0
		if !spelled {
			k = put_verbatim_run(t, at, cells - j)
			spelled = k < 0
		}
		if k > 0 {
			j += k
			continue
		}
		if !put_cell_of(t, at, j) {
			return false
		}
		j += 1
	}
	return true
}

// Whether the cell `c` of a verbatim write reads back as itself from its source bytes: a scalar that is not null,
// quoted, escaped or laxly spelled, and a string that does not start with a byte that may make it read as another
// value. Reads `kind` and `spelling` as one little-endian 32-bit word.
@(private = "file")
verbatim_cell :: #force_inline proc "contextless" (t: ^Table_Write, c: ^tape.Node, src: [^]u8) -> bool {
	when ODIN_ENDIAN != .Little {
		#panic("verbatim_cell assumes little-endian layout")
	}
	#assert(offset_of(tape.Node, kind) % 4 == 0)
	#assert(offset_of(tape.Node, spelling) == offset_of(tape.Node, kind) + 2)
	SPELLED :: u32(tape.SPELLING_DECODE | tape.SPELLING_QUOTED | tape.SPELLING_LAX)
	word := (^u32)(&c.kind)^
	kind := word & 0xFF
	if kind - u32(tape.Kind.False) > u32(tape.Kind.Plain) - u32(tape.Kind.False) || word >> 16 & SPELLED != 0 {
		return false
	}
	return kind < u32(tape.Kind.String) && !t.translate || c.n > 0 && !t.lead[src[c.lo]]
}

// Writes the cells from node `first`, at most `left` of them, that `verbatim_cell` takes and that follow one another in
// the source a delimiter byte apart, with one copy of their source bytes, under `translate` each delimiter replaced.
// Returns how many it wrote, 0 for none, which leaves the first to `put_cell_of`, and -1 under `translate` for a run
// that holds a byte the target must spell or that ends `translate`.
// Invariant: `left >= 1` and `first + tape.Node_Index(left) <= tape.Node_Index(len(doc.nodes))`.
@(private = "file")
put_verbatim_run :: proc(t: ^Table_Write, first: tape.Node_Index, left: int) -> int #no_bounds_check {
	doc := t.w.doc
	nodes, src := raw_data(doc.nodes[first:]), raw_data(doc.src)
	lo := nodes[0].lo
	// The byte before the cell the run expects next (wraps to `max(u64)` when `lo == 0`, so `gap + 1 == 0 == lo`).
	gap := lo - 1
	k := 0
	for ; k < left; k += 1 {
		c := &nodes[k]
		if c.lo != gap + 1 || !verbatim_cell(t, c, src) || t.translate && c.lo + u64(c.n) - lo > ROOM_MAX {
			break
		}
		gap = c.lo + u64(c.n)
	}
	if k == 0 || gap > u64(len(doc.src)) {
		return 0
	}
	run := doc.src[lo:gap]
	if t.verbatim {
		put(t.out, run)
		return k
	}
	// Every cell of the document is one byte apart, so a separator that is the target's delimiter, which the search
	// would take for a byte of a cell, is one for the rest of the write, which goes cell by cell.
	if k > 1 && src[nodes[1].lo - 1] == t.d.delimiter {
		t.translate = false
		return -1
	}
	if has_special(t, run) {
		return -1
	}
	p := room(t.out, len(run))
	copy(p[:len(run)], run)
	for c in 1 ..< k {
		p[nodes[c].lo - 1 - lo] = t.d.delimiter
	}
	t.out.cursor += len(run)
	return k
}

// Writes the cell at `at`, the `j`th of its record, as its kind spells it.
// Invariant: `at` is a valid index in `t.w.doc.nodes`.
@(private = "file")
put_cell_of :: proc(t: ^Table_Write, at: tape.Node_Index, j: int) -> bool #no_bounds_check {
	w := t.w
	node := w.doc.nodes[at]
	s: string
	typed: bool
	buf: [NUMBER_ROOM]u8 = ---
	switch node.kind {
	case .Null:
		return true
	case .String, .Plain:
		if t.whole && node.spelling & tape.SPELLING_DECODE == 0 {
			s = string(w.doc.src[node.lo:][:node.n])
		} else {
			ok: bool
			s, ok = text_of(w, at)
			if !ok {
				return false
			}
		}
	case .True:
		s, typed = "true", true
	case .False:
		s, typed = "false", true
	case .Number:
		typed = true
		if t.native {
			s = string(tape.span_bytes(w.doc, node.lo, node.n))
		} else {
			ok: bool
			s, ok = number_text(w, at, &buf)
			if !ok {
				if w.err == nil {
					w.err = Refused{at, .No_Spelling}
				}
				return false
			}
		}
	case .Bytes:
		encoded := bytes_base64(w, at) or_return
		defer delete(encoded, w.allocator)
		return put_cell(t, at, encoded, j, false)
	case .Array, .Object, .End:
		w.err = Refused{at, .Not_A_Table}
		return false
	}
	return put_cell(t, at, s, j, typed)
}

// Ends a line, with CR LF under `crlf`.
@(private)
put_line_end :: #force_inline proc(t: ^Table_Write) {
	if t.d.crlf {
		put_byte(t.out, '\r')
	}
	put_byte(t.out, '\n')
}

// Writes `s` as cell `j` of its record, the text of node `at`, which reads back as a string, or with `typed` as the
// number or boolean it spells. A cell must not read as another value: empty as null, an untyped `true` or number as
// typed under `infer`, a first cell as a comment line, the text's first bytes as a byte order mark. False with `w.err`
// set when the spec cannot hold it. Invariant: `len(b) > 0` dominates `b[0]`, and `t.lead` is `[256]bool`.
@(private)
put_cell :: #force_inline proc(t: ^Table_Write, at: tape.Node_Index, s: string, j: int, typed: bool) -> bool #no_bounds_check {
	b := transmute([]u8)s
	if len(b) > 0 && !t.lead[b[0]] && !has_special(t, b) {
		put(t.out, b)
		return true
	}
	return put_cell_spelled(t, at, s, j, typed)
}

// `put_cell` for a cell that is empty, holds a byte its spec must quote, escape or refuse, or starts with a byte that
// may make it read as another value. Invariant: every `b[...]` index is dominated by `len(b) > 0` / `len(b) >= 3`.
@(private = "file")
put_cell_spelled :: #force_no_inline proc(t: ^Table_Write, at: tape.Node_Index, s: string, j: int, typed: bool) -> bool #no_bounds_check {
	b := transmute([]u8)s
	d := t.d
	// An empty key is a cell of no bytes, but a line of one is a blank line, which a read skips.
	empty := len(b) == 0 && t.keys < 2
	looks_typed := !typed && t.keys == 0 && d.infer && reads_typed(b)
	comment := j == 0 && len(b) > 0 && d.comment != 0 && b[0] == d.comment
	bom := j == 0 && !t.started && len(b) >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF
	switch t.cells {
	case .Quoted:
		if !(empty || looks_typed || comment || bom || has_special(t, b)) {
			put(t.out, b)
			return true
		}
		if typed {
			break
		}
		put_byte(t.out, '"')
		run := 0
		for from := 0; from < len(b); {
			k := bytes.index_byte(b[from:], '"')
			if k < 0 {
				break
			}
			from += k + 1
			put(t.out, b[run:from])
			run = from - 1
		}
		put(t.out, b[run:])
		put_byte(t.out, '"')
		return true
	case .Escaped:
		// A comment byte that is a tab is escaped, so the line does not start with it.
		if empty || looks_typed || bom || comment && d.comment != '\t' || d.delimiter != '\t' && bytes.index_byte(b, d.delimiter) >= 0 {
			break
		}
		if !has_special(t, b) {
			put(t.out, b)
			return true
		}
		run := 0
		for c, i in b {
			e: u8
			switch c {
			case '\t':
				e = 't'
			case '\n':
				e = 'n'
			case '\r':
				e = 'r'
			case '\\':
				e = '\\'
			case 0:
				e = '0'
			case:
				continue
			}
			put(t.out, b[run:i])
			p := room(t.out, 2)
			p[0], p[1] = '\\', e
			t.out.cursor += 2
			run = i + 1
		}
		put(t.out, b[run:])
		return true
	case .Bare:
		if empty || looks_typed || bom || comment || has_special(t, b) {
			break
		}
		put(t.out, b)
		return true
	}
	t.w.err = Refused{at, .No_Spelling}
	return false
}

// Whether `b` holds a byte of `t.special`. A cell of 16 bytes or more is searched a block at a time out of line, so a
// short cell, the common one, takes no call. Invariant: `t.special` is `[256]bool` indexed by `u8`.
@(private = "file")
has_special :: #force_inline proc "contextless" (t: ^Table_Write, b: []u8) -> bool #no_bounds_check {
	if len(b) >= 16 {
		return has_special_long(t, b)
	}
	for c in b {
		if t.special[c] {
			return true
		}
	}
	return false
}

// Precondition: `len(b) >= 16` so `len(b) - 16 >= 0` and every 16-byte load stays within `b`.
@(private = "file")
has_special_long :: #force_no_inline proc "contextless" (t: ^Table_Write, b: []u8) -> bool #no_bounds_check {
	for i := 0; i < len(b); i += 16 {
		// The last block ends with `b`, overlapping the one before.
		v := kernel.load16(raw_data(b)[min(i, len(b) - 16):])
		hit := simd.lanes_eq(v, t.probe[0]) | simd.lanes_eq(v, t.probe[1]) | simd.lanes_eq(v, t.probe[2]) | simd.lanes_eq(v, t.probe[3]) | simd.lanes_eq(v, t.probe[4]) | simd.lanes_eq(v, t.probe[5])
		if kernel.any_lane16(hit) {
			return true
		}
	}
	return false
}

// Whether `b`, unquoted, reads under `infer` as a boolean or a number.
@(private = "file")
reads_typed :: proc "contextless" (b: []u8) -> bool {
	return string(b) == "true" || string(b) == "false" || is_json_number(b)
}
