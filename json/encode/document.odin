package encode

// A strictly validated document's node rows written back as JSON text. Every key and scalar is its source
// span, copied. Only punctuation and whitespace are re-made. The rows are trusted as a `.Strict` scan left
// them: spans inside `src`, preorder, `subtree_size` exact, depth at most MAX_DEPTH (`rows_too_deep` finds a
// deeper one, read under a raised `max_depth`, for `marshal` to refuse). A row with
// `subtree_size == 1` is a leaf: a scalar or an empty container.
//
// On that trust the walks index their MAX_DEPTH stacks and copy spans unchecked. Span copies and indents
// store whole 16-byte blocks and `minify_dense` whole 64-byte ones, so every output carries slack. Compact
// output has the root span plus MINIFY_SLACK. Pretty output has `pretty_bound` with STORE_SLACK, regrown by
// `widen_rows` when the walk opens a container deeper than it covers. Streamed (`$STREAM`) output has a room
// check per row. Loads stay in `src`: `copy_span` takes 16 bytes only inside it, and `minify_dense` copies a
// last, shorter block into spaces. `$TABS` picks the tab indent. Invariants: compact output is the source
// without whitespace, and output under any options reads back as the same value.

import "base:intrinsics"
import "core:io"
import "core:mem"
import "../scan/walk"
import "../../core/spell"

// Bytes a span copy or an indent may store past its end: short spans and indents move as 16-byte blocks.
@(private = "file")
COPY_SLACK :: 16
#assert(COPY_SLACK >= INDENT_SLACK)
// Source bytes per row at or above which compact output walks the rows: the spans are long, so copying them
// whole beats classifying every byte.
@(private = "file")
ROWS_WALK_BYTES :: 128

// `.Bad_State` when `nodes` is not one whole document: empty, or a root whose subtree is not every row.
encode_rows :: proc(
	src: []byte,
	nodes: []walk.Row,
	opts: Marshal_Opts,
	allocator := context.allocator,
) -> (
	out: []byte,
	err: Marshal_Error,
) {
	if len(nodes) == 0 || nodes[0].subtree_size != u32(len(nodes)) {
		return nil, .Bad_State
	}
	// Compact output is the root's span with whitespace removed, so it never outgrows it: one allocation,
	// written once. Pretty output is bounded by the span and the depth (`pretty_bound`). A walk that meets a
	// deeper container than the bound allows widens it. Either leaves room for the trailing newline.
	root := nodes[0]
	span := int(root.hi - root.lo)
	n: int
	buf: []byte
	if opts.pretty {
		ind := indent_of(opts)
		aerr: mem.Allocator_Error
		buf, aerr = mem.alloc_bytes_non_zeroed(pretty_bound(span, len(nodes), PRETTY_DEPTH_START, ind.unit), allocator = allocator)
		if aerr != nil {
			return nil, .Out_Of_Memory
		}
		n, buf, _ = pretty_rows(buf, src, nodes, span, &ind, opts.indent == 0, nil, allocator, false)
		if buf == nil {
			return nil, .Out_Of_Memory
		}
	} else {
		aerr: mem.Allocator_Error
		buf, aerr = mem.alloc_bytes_non_zeroed(span + MINIFY_SLACK, allocator = allocator)
		if aerr != nil {
			return nil, .Out_Of_Memory
		}
		if span >= ROWS_WALK_BYTES * len(nodes) {
			n, _ = rows_compact(raw_data(buf), src, nodes, nil, false)
		} else {
			state: Minify_State
			n = minify_span(raw_data(buf), src[root.lo:root.hi], &state, false)
		}
	}
	if opts.trailing_newline {
		buf[n] = '\n'
		n += 1
	}
	if flags := reescape_of(opts); flags != {} {
		return reescape_bytes(buf, n, flags, allocator)
	}
	return buf[:n], .None
}

// `buf[:n]` re-escaped, in `buf` grown to fit, and on a refusal `buf` is released.
@(private)
reescape_bytes :: proc(buf: []byte, n: int, flags: Reescape, allocator: mem.Allocator) -> ([]byte, Marshal_Error) {
	text := transmute([dynamic]u8)mem.Raw_Dynamic_Array{raw_data(buf), n, len(buf), allocator}
	if err := reescape_tail(&text, 0, flags); err != .None {
		delete(text)
		return nil, err
	}
	return text[:], .None
}

// `rows_pretty`, compiled once for the tab indent (`tabs`) and once for any other.
@(private = "file")
pretty_rows :: #force_inline proc(
	out: []byte,
	src: []byte,
	nodes: []walk.Row,
	span: int,
	ind: ^Indent,
	tabs: bool,
	k: ^Doc_Sink,
	allocator: mem.Allocator,
	$STREAM: bool,
) -> (n: int, grown: []byte, err: Marshal_Error) {
	if tabs {
		return rows_pretty(out, src, nodes, span, ind, k, allocator, true, STREAM)
	}
	return rows_pretty(out, src, nodes, span, ind, k, allocator, false, STREAM)
}

// `encode_rows` written to `w` as it is made, from a buffer of about SINK_FLUSH_AT bytes in `allocator`.
encode_rows_to_writer :: proc(w: io.Writer, src: []byte, nodes: []walk.Row, opts: Marshal_Opts, allocator := context.allocator) -> Marshal_Error {
	if len(nodes) == 0 || nodes[0].subtree_size != u32(len(nodes)) {
		return .Bad_State
	}
	buf, aerr := mem.alloc_bytes_non_zeroed(spell.SINK_FLUSH_AT + MINIFY_SLACK + STORE_SLACK, allocator = allocator)
	if aerr != nil {
		return .Out_Of_Memory
	}
	k := Doc_Sink{sink = {w, reescape_of(opts)}, buf = buf, allocator = allocator}
	defer mem.free(raw_data(k.buf), allocator)
	root := nodes[0]
	n: int
	err: Marshal_Error
	switch {
	case opts.pretty:
		ind := indent_of(opts)
		n, _, err = pretty_rows(k.buf, src, nodes, 0, &ind, opts.indent == 0, &k, allocator, true)
	case int(root.hi - root.lo) >= ROWS_WALK_BYTES * len(nodes):
		n, err = rows_compact(raw_data(k.buf), src, nodes, &k, true)
	case:
		n, err = minify_to(&k, src[root.lo:root.hi])
	}
	if err != .None {
		return err
	}
	if opts.trailing_newline {
		k.buf[n] = '\n'
		n += 1
	}
	n = sink_flush(&k, n) or_return
	return .None if n == 0 else .Write_Failed
}

// The span minified in SINK_FLUSH_AT pieces, each handed to the writer. Returns the offset left in the buffer.
@(private)
minify_to :: proc(k: ^Doc_Sink, span: []byte) -> (left: int, err: Marshal_Error) {
	state: Minify_State
	w := 0
	for at := 0; at < len(span); at += spell.SINK_FLUSH_AT {
		w += minify_span(&raw_data(k.buf)[w], span[at:min(at + spell.SINK_FLUSH_AT, len(span))], &state, at + spell.SINK_FLUSH_AT < len(span))
		w = sink_flush(k, w) or_return
	}
	return w, .None
}

// Copy `src[lo:hi]` to `out`. Returns its length. A span of at most 16 bytes moves as one 16-byte block when 16
// bytes from `lo` lie inside `src`, so up to `COPY_SLACK` bytes past the span's end in `out` are written.
// One of 17 to 32 bytes moves as two 16-byte blocks that overlap.
@(private)
copy_span :: #force_inline proc "contextless" (out: [^]u8, src: []byte, lo, hi: u32) -> int #no_bounds_check {
	V :: #simd[16]u8
	n := int(hi - lo)
	if n <= 16 && int(lo) + 16 <= len(src) {
		intrinsics.unaligned_store((^V)(&out[0]), intrinsics.unaligned_load((^V)(&src[lo])))
	} else if n <= 32 && n > 16 {
		head := intrinsics.unaligned_load((^V)(&src[lo]))
		tail := intrinsics.unaligned_load((^V)(&src[hi - 16]))
		intrinsics.unaligned_store((^V)(&out[0]), head)
		intrinsics.unaligned_store((^V)(&out[n - 16]), tail)
	} else {
		intrinsics.mem_copy_non_overlapping(&out[0], &src[lo], n)
	}
	return n
}

// The compact output is the source minus insignificant whitespace, so it is made of source runs. A token
// that sits in the source exactly where the output puts it (source offset minus output offset equals the
// run's `shift`) only extends the run. Any other token ends the run with one copy, then is written alone.
// Strict JSON makes the run sound: a gap of exactly the punctuation's length between two tokens can only
// hold that punctuation.
@(private)
Compact_Run :: struct {
	out:   [^]u8,
	src:   []byte,
	w:     int, // output length, the pending run included
	start: int, // where the pending run begins in the output
	shift: int, // source offset minus output offset inside the run
}

// One token `src[lo:hi]`, preceded in the output by `punct` (0 for none).
@(private)
compact_token :: #force_inline proc "contextless" (r: ^Compact_Run, punct: u8, lo, hi: u32) #no_bounds_check {
	np := 0 if punct == 0 else 1
	if int(lo) - (r.w + np) == r.shift {
		r.w += np + int(hi - lo)
		return
	}
	compact_flush(r)
	if np != 0 {
		r.out[r.w] = punct
		r.w += 1
	}
	r.w += copy_span(r.out[r.w:], r.src, lo, hi)
	r.start = r.w
	r.shift = int(hi) - r.w
}

@(private)
compact_flush :: #force_inline proc "contextless" (r: ^Compact_Run) {
	if n := r.w - r.start; n > 0 {
		intrinsics.mem_copy_non_overlapping(&r.out[r.start], &r.src[r.start + r.shift], n)
	}
}

// An open container: the row its subtree ends before, and one past its close bracket.
@(private)
Open_Container :: struct {
	end, hi: u32,
}

// Compact output from the rows, for documents of long spans. `out` has room for the root span plus
// `COPY_SLACK`. Returns the count written. With STREAM `out` is `k.buf`, handed to the writer as it fills, and the
// count is what is left in it.
@(private)
rows_compact :: proc(out: [^]u8, src: []byte, nodes: []walk.Row, k: ^Doc_Sink, $STREAM: bool) -> (n: int, err: Marshal_Error) #no_bounds_check {
	r := Compact_Run{out = out, src = src, shift = int(nodes[0].lo)}
	stack: [MAX_DEPTH]Open_Container = ---
	depth := 0
	np := 0 // 1 when a comma precedes the row
	for i := 0; i < len(nodes); {
		nd := &nodes[i]
		i += 1
		leaf := nd.subtree_size == 1
		// A scalar's span is its text, and so is an empty container's when nothing sits between its brackets.
		whole := leaf && (nd.kind < .Array || nd.hi - nd.lo == 2)
		first := nd.lo if nd.key_lo == walk.NO_KEY else nd.key_lo
		when STREAM {
			// The row's own bytes, a comma, and a close for every container the row may end.
			need := int((nd.hi if leaf else nd.lo + 1) - first) + 1 + depth + COPY_SLACK
			if r.w + need > len(k.buf) {
				compact_flush(&r)
				w := sink_room(k, r.w, need) or_return
				r.shift += r.w - w
				r.w, r.start, r.out = w, w, raw_data(k.buf)
			}
		}
		// The common row: comma, key, colon and value already sit in the source as the output needs them.
		if int(first) == r.w + np + r.shift && (nd.key_lo == walk.NO_KEY || nd.lo == nd.key_hi + 1) {
			r.w += np + int((nd.hi if whole else nd.lo + 1) - first)
			if !whole && leaf {
				compact_token(&r, 0, nd.hi - 1, nd.hi)
			}
		} else {
			punct: u8 = ',' if np != 0 else 0
			if nd.key_lo != walk.NO_KEY {
				compact_token(&r, punct, nd.key_lo, nd.key_hi)
				punct = ':'
			}
			if whole {
				compact_token(&r, punct, nd.lo, nd.hi)
			} else {
				compact_token(&r, punct, nd.lo, nd.lo + 1)
				if leaf {
					compact_token(&r, 0, nd.hi - 1, nd.hi)
				}
			}
		}
		if !leaf {
			stack[depth] = {u32(i - 1) + nd.subtree_size, nd.hi}
			depth += 1
			np = 0
			continue
		}
		np = 1
		for depth > 0 && stack[depth - 1].end == u32(i) {
			depth -= 1
			compact_token(&r, 0, stack[depth].hi - 1, stack[depth].hi)
		}
	}
	compact_flush(&r)
	return r.w, .None
}

// The exact length `rows_pretty` writes, `unit` indent bytes per level. Every row but the root starts a line
// indented by its depth, and every open container ends one indented by its own.
@(private)
pretty_size :: proc(nodes: []walk.Row, unit: int) -> int #no_bounds_check {
	ends: [MAX_DEPTH]u32 = ---
	depth := 0
	n := -1 // the root starts no line
	for i := 0; i < len(nodes); {
		nd := &nodes[i]
		i += 1
		n += 1 + depth * unit
		if nd.key_lo != walk.NO_KEY {
			n += int(nd.key_hi - nd.key_lo) + 2
		}
		if nd.kind < .Array {
			n += int(nd.hi - nd.lo)
		} else if nd.subtree_size == 1 {
			n += 2
		} else {
			// Brackets, commas between the members, and the close's line.
			n += 2 + int(nd.cnt - 1) + 1 + depth * unit
			ends[depth] = u32(i - 1) + nd.subtree_size
			depth += 1
			continue
		}
		for depth > 0 && ends[depth - 1] == u32(i) {
			depth -= 1
		}
	}
	return n
}

// Whether a container in `nodes` sits more than MAX_DEPTH containers deep, as the scan counts depth: past
// what the walks here hold. Only rows read under a `max_depth` past MAX_DEPTH can.
rows_too_deep :: proc(nodes: []walk.Row) -> bool #no_bounds_check {
	ends: [MAX_DEPTH]u32 = ---
	depth := 0
	for i := 0; i < len(nodes); {
		nd := &nodes[i]
		i += 1
		if nd.kind >= .Array {
			if depth == MAX_DEPTH {
				return true
			}
			if nd.subtree_size != 1 {
				ends[depth] = u32(i - 1) + nd.subtree_size
				depth += 1
				continue
			}
		}
		for depth > 0 && ends[depth - 1] == u32(i) {
			depth -= 1
		}
	}
	return false
}

// Bytes past the end of the output that the walk's block stores may reach.
@(private = "file")
STORE_SLACK :: 64

// The depth `rows_pretty` is first allocated for.
@(private = "file")
PRETTY_DEPTH_START :: 8

// An upper bound on the pretty output of `rows` rows from a source of `span` bytes, none nested deeper than
// `depth` containers, `unit` indent bytes per level. The span holds every key, scalar and bracket the output
// has. What the walk adds is, per row, a comma, a line break with its indent, a key's colon and space, and the
// line a container closes on: at most 2 * depth * unit + 5 bytes.
@(private)
pretty_bound :: proc(span, rows, depth, unit: int) -> int {
	return span + rows * (2 * depth * unit + 5) + STORE_SLACK
}

// The rows written pretty into `out`, which holds `pretty_bound(span, len(nodes), PRETTY_DEPTH_START,
// ind.unit)`. The walk replaces it when it opens a container deeper than the bound covers. Returns the count
// written and the buffer holding them (a nil buffer is a refusal, with `out` released). TABS is `ind` being
// one tab per level. With STREAM `out` is `k.buf`, handed to the writer as it fills, and the count is what is left in it.
// It stays out of line: inlined, its loop would be placed differently with every edit beside it, so the
// walk's speed would follow unrelated code.
@(private)
rows_pretty :: #force_no_inline proc(
	out: []byte,
	src: []byte,
	nodes: []walk.Row,
	span: int,
	ind: ^Indent,
	k: ^Doc_Sink,
	allocator: mem.Allocator,
	$TABS, $STREAM: bool,
) -> (n: int, grown: []byte, err: Marshal_Error) #no_bounds_check {
	// ends[d] is the row the container at depth d ends before. ends[0] is nil, a row no walk reaches, so the
	// close loop needs no depth test. Rows are walked by address so the loop holds no index and no length.
	ends: [MAX_DEPTH + 1][^]walk.Row = ---
	shut: [MAX_DEPTH]u8 = ---
	ends[0] = nil
	depth, covered := 0, PRETTY_DEPTH_START
	comma := false
	w := 0
	buf := out
	p := raw_data(buf)
	row := raw_data(nodes)
	stop := row[len(nodes):]
	for row != stop {
		nd := &row[0]
		row = row[1:]
		when STREAM {
			// A comma, the line break, the key with its colon and space, and a scalar or a bracket pair.
			need := 2 + depth * ind.unit + 2 + COPY_SLACK + 2
			if nd.key_lo != walk.NO_KEY {
				need += int(nd.key_hi - nd.key_lo)
			}
			if nd.kind < .Array {
				need += int(nd.hi - nd.lo)
			}
			if w + need > len(k.buf) {
				w = sink_room(k, w, need) or_return
				buf = k.buf
				p = raw_data(buf)
			}
		}
		if depth > 0 {
			p[w] = ','
			w += int(comma)
			w += put_indent(p[w:], depth, ind, TABS)
		}
		if nd.key_lo != walk.NO_KEY {
			w += copy_span(p[w:], src, nd.key_lo, nd.key_hi)
			p[w] = ':'
			p[w + 1] = ' '
			w += 2
		}
		if nd.kind < .Array {
			w += copy_span(p[w:], src, nd.lo, nd.hi)
		} else {
			// `[` + 2 is `]` and `{` + 2 is `}`.
			open: u8 = '[' if nd.kind == .Array else '{'
			p[w] = open
			if nd.subtree_size != 1 {
				w += 1
				shut[depth] = open + 2
				depth += 1
				ends[depth] = row[nd.subtree_size - 1:]
				comma = false
				when STREAM {
					// The buffer is checked before every row instead of bounded up front.
					_ = covered
				} else {
					if depth > covered {
						buf, covered = widen_rows(buf, nodes, span, depth, ind.unit, allocator)
						if buf == nil {
							return 0, nil, .Out_Of_Memory
						}
						p = raw_data(buf)
					}
				}
				continue
			}
			p[w + 1] = open + 2
			w += 2
		}
		comma = true
		for ends[depth] == row {
			depth -= 1
			when STREAM {
				if close_need := 2 + depth * ind.unit + INDENT_SLACK; w + close_need > len(k.buf) {
					w = sink_room(k, w, close_need) or_return
					buf = k.buf
					p = raw_data(buf)
				}
			}
			w += put_indent(p[w:], depth, ind, TABS)
			p[w] = shut[depth]
			w += 1
		}
	}
	return w, buf, .None
}

// `buf` made large enough for a walk that has reached `depth`, its written bytes kept, and the depth it
// now covers, or nil (with `buf` released) when the allocator refuses. The bound for twice that depth, unless
// that dwarfs the span: then the exact size, which no depth can outgrow.
@(private)
widen_rows :: #force_no_inline proc(buf: []byte, nodes: []walk.Row, span, depth, unit: int, allocator: mem.Allocator) -> ([]byte, int) {
	covered := min(2 * depth, MAX_DEPTH)
	size := pretty_bound(span, len(nodes), covered, unit)
	if size > 8 * span * unit + (1 << 20) {
		size = pretty_size(nodes, unit) + STORE_SLACK
		covered = MAX_DEPTH
	}
	grown, err := mem.resize_bytes_non_zeroed(buf, size, allocator = allocator)
	if err != nil {
		mem.free(raw_data(buf), allocator)
		return nil, 0
	}
	return grown, covered
}
