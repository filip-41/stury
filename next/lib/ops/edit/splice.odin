package edit

import "base:runtime"
import "core:bytes"
import "core:container/xar"
import "core:math"
import "core:slice"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// Byte-level splice engine and shared composer utilities.
// Applies sorted non-overlapping replacements and move-blocks iteratively (zero recursion),
// computes exact output byte ranges for `Commit_Result.rewritten` and `Splice_Record`s.

// One replacement of `src[lo:hi]` by `text` (or by `moves` when `len(moves) > 0`).
Splice :: struct {
	lo, hi:       u64,
	text:         []u8,
	seq:          int,
	moves:        []Move,
	base_node:    tape.Node_Index,
	subtree_only: bool,
	full_rewalk:  bool,
	rewritten:    bool,
}

// A piece of a reordered range: either literal `text` (`written == true`) or source slice `src[lo:hi]`
// with any inner splices inside `[lo, hi)` applied to it.
Move :: struct {
	lo, hi:  u64,
	text:    []u8,
	written: bool,
}

// Common commit entry guard shared by all 5 composers:
// validates `ov`/`base`, resolves `target`, and handles the `!ov.dirty` fast path (including cross-spec validation!).
commit_guard :: proc(
	ov: ^Overlay,
	spec_target: ^tape.Format,
	opts: Options,
	extra_clean: bool,
	validate: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error,
	validate_data: rawptr,
	allocator: runtime.Allocator,
) -> (
	done: bool,
	target: ^tape.Format,
	res: Commit_Result,
	err: Error,
) {
	if ov == nil || ov.base == nil {
		return false, nil, {}, refuse(.No_Document, "overlay has no document")
	}
	if ov.base.partial != nil {
		return false, nil, {}, refuse(.Partial_Document, "cannot commit a partial document")
	}
	doc := ov.base
	target = opts.target if opts.target != nil else spec_target
	if target == nil {
		target = doc.format
	}
	if !ov.dirty && extra_clean {
		if target != doc.format && validate != nil {
			if verr := validate(validate_data, doc.src, allocator); verr != nil {
				return false, target, {}, convert_tape_error(verr)
			}
		}
		cloned, cerr := slice.clone(doc.src, allocator)
		if cerr != nil {
			return false, target, {}, cerr
		}
		return true, target, Commit_Result{bytes = cloned, allocator = allocator}, nil
	}
	return false, target, {}, nil
}

// Applies `splices` to `src` into a fresh byte buffer from `allocator`, recording output `Splice_Record`s
// and `rewritten` ranges. Sorts `splices` in place.
apply_splices :: proc(
	src: []u8,
	splices: []Splice,
	allocator: runtime.Allocator,
) -> (
	out: []u8,
	records: []Splice_Record,
	rewritten: []Byte_Range,
	err: Error,
) {
	has_moves := false
	strictly_sorted := true
	prev_lo := u64(0)
	for s, i in splices {
		if len(s.moves) > 0 {
			has_moves = true
		}
		if i > 0 && s.lo <= prev_lo {
			strictly_sorted = false
		}
		prev_lo = s.lo
	}
	if !strictly_sorted || has_moves {
		slice.sort_by(splices, proc(a, b: Splice) -> bool {
			if a.lo != b.lo {
				return a.lo < b.lo
			}
			am, bm := len(a.moves) > 0, len(b.moves) > 0
			if am != bm {
				return am
			}
			if a.hi != b.hi {
				return a.hi < b.hi if !am else a.hi > b.hi
			}
			return a.seq < b.seq
		})
	}
	if !has_moves {
		return apply_flat_splices(src, splices, allocator)
	}
	return apply_move_splices(src, splices, allocator)
}

@(private = "file")
apply_flat_splices :: proc(
	src: []u8,
	splices: []Splice,
	allocator: runtime.Allocator,
) -> (
	out: []u8,
	records: []Splice_Record,
	rewritten: []Byte_Range,
	err: Error,
) {
	reach := u64(0)
	total := i64(len(src))
	n_rewritten := 0
	for s in splices {
		if s.lo < reach || s.lo > s.hi || s.hi > u64(len(src)) {
			return nil, nil, nil, refuse(.Layout_Reflow_Needed, "overlapping or out-of-range splices", s.base_node, s.lo)
		}
		reach = s.hi
		total += i64(len(s.text)) - i64(s.hi - s.lo)
		if s.rewritten {
			n_rewritten += 1
		}
	}
	raw: []u8
	if total > 0 {
		raw_mem, aerr := runtime.mem_alloc_non_zeroed(int(total), 1, allocator)
		if aerr != nil {
			return nil, nil, nil, aerr
		}
		raw = raw_mem[:int(total)]
	}
	defer if err != nil && raw != nil {
		delete(raw, allocator)
	}
	recs: []Splice_Record
	if len(splices) > 0 {
		rmem, rerr := runtime.mem_alloc_non_zeroed(len(splices) * size_of(Splice_Record), align_of(Splice_Record), allocator)
		if rerr != nil {
			return nil, nil, nil, rerr
		}
		recs = ([^]Splice_Record)(raw_data(rmem))[:len(splices)]
	}
	defer if err != nil && recs != nil {
		delete(recs, allocator)
	}
	rew: []Byte_Range
	if n_rewritten > 0 {
		werr: runtime.Allocator_Error
		rew, werr = make([]Byte_Range, n_rewritten, allocator)
		if werr != nil {
			return nil, nil, nil, werr
		}
	}
	w := 0
	at := u64(0)
	ri := 0
	for s, i in splices {
		if s.lo > at {
			w += copy(raw[w:], src[at:s.lo])
		}
		dst_lo := u64(w)
		if len(s.text) > 0 {
			w += copy(raw[w:], s.text)
		}
		dst_hi := u64(w)
		recs[i] = {
			base_node    = s.base_node,
			src_lo       = s.lo,
			src_hi       = s.hi,
			dst_lo       = dst_lo,
			dst_hi       = dst_hi,
			subtree_only = s.subtree_only,
			full_rewalk  = s.full_rewalk,
		}
		if s.rewritten {
			rew[ri] = {dst_lo, dst_hi}
			ri += 1
		}
		at = s.hi
	}
	if at < u64(len(src)) {
		copy(raw[w:], src[at:])
	}
	return raw, recs, rew, nil
}

// Iterative move-splice applicator (explicit heap stack, zero native recursion).
@(private = "file")
apply_move_splices :: proc(
	src: []u8,
	splices: []Splice,
	allocator: runtime.Allocator,
) -> (
	out: []u8,
	records: []Splice_Record,
	rewritten: []Byte_Range,
	err: Error,
) {
	Frame :: struct {
		splices:        []Splice,
		lo, hi:         u64,
		at:             u64,
		i:              int,
		in_move:        bool,
		moves:          []Move,
		inner:          []Splice,
		m_idx:          int,
		parent_rec_idx: int,
	}
	buf := make([dynamic]u8, 0, len(src), allocator)
	defer if err != nil {
		delete(buf)
	}
	recs := make([dynamic]Splice_Record, 0, len(splices), allocator)
	defer if err != nil {
		delete(recs)
	}
	rew := make([dynamic]Byte_Range, 0, 4, allocator)
	defer if err != nil {
		delete(rew)
	}
	stack := make([dynamic]Frame, 0, 16, allocator)
	defer delete(stack)

	if _, aerr := append(&stack, Frame{splices = splices, lo = 0, hi = u64(len(src)), at = 0, parent_rec_idx = -1}); aerr != nil {
		return nil, nil, nil, aerr
	}

	for len(stack) > 0 {
		f := &stack[len(stack) - 1]
		if f.in_move {
			if f.m_idx >= len(f.moves) {
				if f.parent_rec_idx >= 0 {
					recs[f.parent_rec_idx].dst_hi = u64(len(buf))
				}
				f.in_move = false
				continue
			}
			m := f.moves[f.m_idx]
			f.m_idx += 1
			if m.written {
				if _, aerr := append(&buf, ..m.text); aerr != nil {
					return nil, nil, nil, aerr
				}
				continue
			}
			// Check whether another non-written move in `f.moves` starts right at `m.hi` so zero-length inserts at
			// a split boundary aren't duplicated across two adjacent moves.
			next_owns_hi := false
			for nm in f.moves[f.m_idx:] {
				if !nm.written && nm.lo == m.hi {
					next_owns_hi = true
					break
				}
			}
			// Find sub-splices inside `[m.lo, m.hi]` within `f.inner` (including zero-length inserts at `m.hi`
			// when no subsequent move begins at `m.hi`).
			sub_lo := 0
			for sub_lo < len(f.inner) && f.inner[sub_lo].lo < m.lo {
				sub_lo += 1
			}
			sub_hi := sub_lo
			for sub_hi < len(f.inner) {
				in_s := f.inner[sub_hi]
				if in_s.hi > m.hi {
					break
				}
				if in_s.lo == m.hi {
					if in_s.hi == m.hi && !next_owns_hi {
						sub_hi += 1
						continue
					}
					break
				}
				sub_hi += 1
			}
			if _, aerr := append(&stack, Frame{splices = f.inner[sub_lo:sub_hi], lo = m.lo, hi = m.hi, at = m.lo, parent_rec_idx = -1}); aerr != nil {
				return nil, nil, nil, aerr
			}
			continue
		}

		if f.i >= len(f.splices) {
			if f.at < f.hi {
				if _, aerr := append(&buf, ..src[f.at:f.hi]); aerr != nil {
					return nil, nil, nil, aerr
				}
			}
			pop(&stack)
			continue
		}

		s := f.splices[f.i]
		if s.lo < f.at || s.lo > s.hi || s.hi > f.hi {
			return nil, nil, nil, refuse(.Layout_Reflow_Needed, "overlapping splices in reordered block", s.base_node, s.lo)
		}
		if s.lo > f.at {
			if _, aerr := append(&buf, ..src[f.at:s.lo]); aerr != nil {
				return nil, nil, nil, aerr
			}
		}
		f.i += 1
		f.at = s.hi

		if len(s.moves) == 0 {
			dst_lo := u64(len(buf))
			if len(s.text) > 0 {
				if _, aerr := append(&buf, ..s.text); aerr != nil {
					return nil, nil, nil, aerr
				}
			}
			dst_hi := u64(len(buf))
			if len(stack) == 1 {
				if _, aerr := append(&recs, Splice_Record {
					base_node    = s.base_node,
					src_lo       = s.lo,
					src_hi       = s.hi,
					dst_lo       = dst_lo,
					dst_hi       = dst_hi,
					subtree_only = s.subtree_only,
					full_rewalk  = s.full_rewalk,
				}); aerr != nil {
					return nil, nil, nil, aerr
				}
			}
			if s.rewritten {
				if _, aerr := append(&rew, Byte_Range{dst_lo, dst_hi}); aerr != nil {
					return nil, nil, nil, aerr
				}
			}
			continue
		}

		// Collect inner splices inside `[s.lo, s.hi]`, including zero-length inserts right at `s.hi` (e.g.
		// inline comments or appended attributes on the last moved item).
		j := f.i
		for j < len(f.splices) && (f.splices[j].lo < s.hi || (f.splices[j].lo == s.hi && f.splices[j].hi == s.hi)) {
			j += 1
		}
		inner := f.splices[f.i:j]
		f.i = j
		rec_idx := -1
		if len(stack) == 1 {
			dst_lo := u64(len(buf))
			if _, aerr := append(&recs, Splice_Record {
				base_node    = s.base_node,
				src_lo       = s.lo,
				src_hi       = s.hi,
				dst_lo       = dst_lo,
				dst_hi       = dst_lo,
				subtree_only = false,
				full_rewalk  = s.full_rewalk,
			}); aerr != nil {
				return nil, nil, nil, aerr
			}
			rec_idx = len(recs) - 1
		}
		f.in_move = true
		f.moves = s.moves
		f.inner = inner
		f.m_idx = 0
		f.parent_rec_idx = rec_idx
	}
	return buf[:], recs[:], rew[:], nil
}

// Common line/whitespace/text utilities shared by all format-family composers.

line_start :: proc "contextless" (src: []u8, p: u64) -> u64 {
	i := min(p, u64(len(src)))
	for i > 0 && src[i - 1] != '\n' {
		i -= 1
	}
	return i
}

next_line :: proc "contextless" (src: []u8, p: u64) -> u64 {
	i := min(p, u64(len(src)))
	for i < u64(len(src)) && src[i] != '\n' {
		i += 1
	}
	return min(i + 1, u64(len(src)))
}

first_on_line :: proc "contextless" (src: []u8, p: u64) -> bool {
	ls := line_start(src, p)
	for i := ls; i < p; i += 1 {
		if src[i] != ' ' && src[i] != '\t' {
			return false
		}
	}
	return true
}

line_indent :: proc "contextless" (src: []u8, pos: u64) -> string {
	ls := line_start(src, pos)
	p := ls
	for p < u64(len(src)) && (src[p] == ' ' || src[p] == '\t') {
		p += 1
	}
	return string(src[ls:p])
}

detect_eol :: proc "contextless" (src: []u8) -> string {
	limit := min(len(src), 65536)
	if i := bytes.index_byte(src[:limit], '\n'); i >= 0 {
		if i > 0 && src[i - 1] == '\r' {
			return "\r\n"
		}
		return "\n"
	}
	return "\n"
}

// Temporary decoded text of a base tape node (borrowed directly from `doc.src` when no escapes exist).
Tmp_Text :: struct {
	text:  string,
	owned: bool,
}

decode_node_text_tmp :: proc(doc: ^tape.Document, at: tape.Node_Index, allocator: runtime.Allocator) -> Tmp_Text {
	if doc == nil || at == tape.NO_NODE || int(at) >= len(doc.nodes) {
		return {}
	}
	room := tape.text_room(doc, at)
	if room == 0 {
		return {text = string(tape.span_bytes(doc, doc.nodes[at].lo, doc.nodes[at].n))}
	}
	buf, err := make([]u8, room, allocator)
	if err != nil {
		return {}
	}
	if ds, ok := tape.node_text(doc, at, buf); ok {
		if raw_data(ds) == raw_data(buf) {
			return {text = ds, owned = true}
		}
		delete(buf, allocator)
		return {text = ds}
	}
	delete(buf, allocator)
	return {}
}

free_tmp_text :: proc(k: Tmp_Text, allocator: runtime.Allocator) {
	if k.owned && len(k.text) > 0 {
		delete(k.text, allocator)
	}
}

// Returns the authored byte range `[lo, hi)` of a base node in `doc.src` (including quotes for strings and
// closing bracket/brace/tag for containers).
node_byte_span :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (lo, hi: u64, ok: bool) {
	if doc == nil || at == tape.NO_NODE || int(at) >= len(doc.nodes) {
		return 0, 0, false
	}
	t := doc.nodes[at]
	if t.kind >= .Array {
		if doc.format == nil || doc.format.close_end == nil {
			return 0, 0, false
		}
		end, cok := doc.format.close_end(doc, at)
		if !cok {
			return 0, 0, false
		}
		return t.lo, end, true
	}
	head, tail: u8
	if doc.format != nil && doc.format.bounds != nil {
		head, tail = doc.format.bounds(doc.src, t)
	}
	lo = t.lo - u64(head)
	hi = t.lo + u64(t.n) + u64(tail)
	return lo, hi, true
}

// Validates a reorder permutation `order` over `base_count` original items (minus `deleted`) plus `insert_count` inserts.
validate_order :: proc(order: []u32, deleted: []bool, insert_count: int, allocator: runtime.Allocator) -> Error {
	n := len(deleted)
	total := n + insert_count
	seen, err := make([]bool, total, allocator)
	if err != nil {
		return err
	}
	defer delete(seen, allocator)
	for raw in order {
		k := int(raw)
		if k >= total || seen[k] || (k < n && deleted[k]) {
			return refuse(.Bad_Order, "reorder index invalid, duplicated, or names a removed member")
		}
		seen[k] = true
	}
	expected := insert_count
	for d in deleted {
		if !d {
			expected += 1
		}
	}
	if len(order) != expected {
		return refuse(.Bad_Order, "reorder does not name every surviving member and insert exactly once")
	}
	return nil
}

@(private)
fail_commit_validation :: proc(
	out: []u8,
	recs: []Splice_Record,
	rew: []Byte_Range,
	verr: tape.Error,
	allocator: runtime.Allocator,
) -> (Commit_Result, Error) {
	delete(out, allocator)
	delete(recs, allocator)
	delete(rew, allocator)
	return {}, convert_tape_error(verr)
}

@(private)
has_utf8_bom :: #force_inline proc "contextless" (b: []u8) -> bool {
	return len(b) >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF
}

// Sound O(len) fast-path check for a single self-contained JSON/JSONC/JSON5 scalar literal
// (RFC 8259 number, `true`/`false`/`null`, or unescaped printable ASCII double-quoted string).
// Any other value (containers, escapes, non-ASCII, comments, malformed input) returns false and falls back to `spec.validate`.
@(private)
is_simple_json_scalar :: proc "contextless" (frag: []u8) -> bool {
	if len(frag) == 0 {
		return false
	}
	switch frag[0] {
	case '0' ..= '9', '-':
		_, ok := spell.number_strict(frag, 0, u64(len(frag)))
		return ok
	case 't':
		return string(frag) == "true"
	case 'f':
		return string(frag) == "false"
	case 'n':
		return string(frag) == "null"
	case '"':
		if len(frag) < 2 || frag[len(frag) - 1] != '"' {
			return false
		}
		for b in frag[1 : len(frag) - 1] {
			if b < 0x20 || b >= 0x80 || b == '"' || b == '\\' {
				return false
			}
		}
		return true
	}
	return false
}

// Sound O(len) fast-path check for a single self-contained TOML 1.0/1.1 scalar literal
// (i64 integer, finite f64 float, `true`/`false`, or unescaped printable ASCII basic string).
@(private)
is_simple_toml_scalar :: proc "contextless" (frag: []u8) -> bool {
	if len(frag) == 0 {
		return false
	}
	switch frag[0] {
	case '0' ..= '9', '-':
		sn, ok := spell.number_strict(frag, 0, u64(len(frag)))
		if !ok {
			return false
		}
		if sn.kind == .Int {
			return true
		}
		// Only accept `.Float` when the text is genuinely a float literal (contains `.`, `e`, or `E`),
		// never an out-of-range integer (`< min(i64)` or `> max(u64)`) that `number_strict` widened to `f64`!
		if sn.kind == .Float && !math.is_inf(transmute(f64)sn.bits) {
			for b in frag {
				if b == '.' || b == 'e' || b == 'E' {
					return true
				}
			}
		}
		return false
	case 't':
		return string(frag) == "true"
	case 'f':
		return string(frag) == "false"
	case '"':
		if len(frag) < 2 || frag[len(frag) - 1] != '"' {
			return false
		}
		for b in frag[1 : len(frag) - 1] {
			if b < 0x20 || b >= 0x7F || b == '"' || b == '\\' {
				return false
			}
		}
		return true
	}
	return false
}

// Sound O(len) fast-path check for pure ASCII XML 1.0 CharData with no markup-significant bytes (`<`, `&`, `]`, `>`).
@(private)
is_simple_xml_text :: proc "contextless" (frag: []u8) -> bool {
	for b in frag {
		if b >= 0x80 || b == '<' || b == '&' || b == ']' || b == '>' {
			return false
		}
		if b < 0x20 && b != '\t' && b != '\n' && b != '\r' {
			return false
		}
	}
	return true
}

// Common commit runner shared by all 4 text-family composers (bracket, markup, section, tabular).
// Preserves direct loops inside `fast_emit`, `struct_emit`, and `frag_check` so fast-path performance is untouched.
@(private)
Text_Composer :: struct {
	target:        ^tape.Format,
	extra_clean:   bool,
	req_root:      tape.Kind, // `.End` to accept any root kind
	root_msg:      string,
	validate:      proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error,
	validate_data: rawptr,
	fast_emit:     proc(user: rawptr, ov: ^Overlay, doc: ^tape.Document, splices: ^[dynamic]Splice, scratch: runtime.Allocator) -> (ok: bool, err: Error),
	struct_emit:   proc(user: rawptr, ov: ^Overlay, doc: ^tape.Document, eol: string, splices: ^[dynamic]Splice, dropped: ^tape.Facts, scratch: runtime.Allocator) -> Error,
	frag_check:    proc(user: rawptr, out: []u8, recs: []Splice_Record, scratch: runtime.Allocator) -> (need_full: bool, err: Error),
	user:          rawptr,
}

@(private)
run_text_commit :: proc(
	ov: ^Overlay,
	tc: ^Text_Composer,
	opts: Options,
	allocator: runtime.Allocator,
) -> (
	res: Commit_Result,
	err: Error,
) {
	fast, target, fast_res, gerr := commit_guard(ov, tc.target, opts, tc.extra_clean, tc.validate, tc.validate_data, allocator)
	if gerr != nil {
		return {}, gerr
	}
	if fast {
		return fast_res, nil
	}
	doc := ov.base
	if tc.req_root != .End && ov.root != NO_HANDLE && node_kind(ov, ov.root) != tc.req_root {
		return {}, refuse(.Root_Shape, tc.root_msg, tape.ROOT)
	}

	arena := runtime.Arena{backing_allocator = allocator, minimum_block_size = 4096}
	defer runtime.arena_destroy(&arena)
	scratch := runtime.arena_allocator(&arena)

	splices := make([dynamic]Splice, 0, max(8, xar.len(ov.nodes.items)), scratch)
	dropped: tape.Facts
	used_fast := false
	if tc.fast_emit != nil && !ov.has_structural {
		used_fast = tc.fast_emit(tc.user, ov, doc, &splices, scratch) or_return
	}
	if !used_fast {
		if ov.unlinked_parents {
			ensure_linked(ov) or_return
		}
		eol := detect_eol(doc.src)
		if tc.struct_emit != nil {
			tc.struct_emit(tc.user, ov, doc, eol, &splices, &dropped, scratch) or_return
		}
	}

	out, recs, rew, serr := apply_splices(doc.src, splices[:], allocator)
	if serr != nil {
		return {}, serr
	}
	if tc.validate != nil {
		need_full := target != doc.format || len(recs) == 0
		if !need_full && tc.frag_check != nil {
			nf, ferr := tc.frag_check(tc.user, out, recs, scratch)
			if ferr != nil {
				delete(out, allocator)
				delete(recs, allocator)
				delete(rew, allocator)
				return {}, ferr
			}
			need_full = nf
		}
		if need_full {
			if verr := tc.validate(tc.validate_data, out, allocator); verr != nil {
				return fail_commit_validation(out, recs, rew, verr, allocator)
			}
		}
	}
	return Commit_Result {
		bytes     = out,
		dropped   = dropped,
		rewritten = rew,
		splices   = recs,
		allocator = allocator,
	}, nil
}

// Drops any already-emitted splices inside `[lo, hi)` (optionally keeping `keep_at_hi_node`'s zero-length
// splice at `hi`, e.g. an XML element's `.Comment_Foot`), freeing their temporary buffers.
@(private)
drop_splices_in_range :: proc(
	splices: ^[dynamic]Splice,
	lo, hi: u64,
	allocator: runtime.Allocator,
	keep_at_hi_node := tape.NO_NODE,
) {
	w := 0
	for s in splices^ {
		inside := s.lo >= lo && s.hi <= hi
		if inside && keep_at_hi_node != tape.NO_NODE && s.base_node == keep_at_hi_node && s.lo == hi {
			inside = false
		}
		if inside {
			delete(s.text, allocator)
			for mv in s.moves {
				if mv.written {
					delete(mv.text, allocator)
				}
			}
			delete(s.moves, allocator)
			continue
		}
		splices[w] = s
		w += 1
	}
	resize(splices, w)
}

@(private)
make_deleted_flags :: proc(items: []$T, allocator: runtime.Allocator) -> (flags: []bool, err: runtime.Allocator_Error) {
	flags = make([]bool, len(items), allocator) or_return
	for it, i in items {
		flags[i] = it.deleted
	}
	return flags, nil
}

@(private)
collect_base_facts :: proc(doc: ^tape.Document, node: tape.Node_Index, kind: tape.Fact_Kind, allocator: runtime.Allocator) -> [dynamic]tape.Fact {
	existing := make([dynamic]tape.Fact, 0, 4, allocator)
	for bf in tape.facts_of(doc, node) {
		if bf.kind == kind {
			append(&existing, bf)
		}
	}
	return existing
}

// Appends a quoted escaped string (JSON or TOML basic string) to `out`.
append_quoted_escaped :: proc(out: ^[dynamic]u8, s: string, quote: u8, escape_del := false) {
	hex := "0123456789abcdef"
	append(out, quote)
	for c in transmute([]u8)s {
		switch c {
		case '\\': append(out, `\\`)
		case '\b': append(out, `\b`)
		case '\f': append(out, `\f`)
		case '\n': append(out, `\n`)
		case '\r': append(out, `\r`)
		case '\t': append(out, `\t`)
		case:
			if c == quote {
				append(out, '\\', quote)
			} else if c < 0x20 || (escape_del && c == 0x7F) {
				append(out, `\u00`)
				append(out, hex[c >> 4], hex[c & 0xF])
			} else {
				append(out, c)
			}
		}
	}
	append(out, quote)
}

// Sound O(len) fast-path check for a single plain ASCII DSV cell containing no delimiter, quote, escape, line break,
// leading comment marker, or file-start BOM.
@(private)
is_simple_dsv_cell :: proc "contextless" (frag: []u8, delim, comment: u8, at_start: bool) -> bool {
	if at_start && has_utf8_bom(frag) {
		return false
	}
	if comment != 0 && len(frag) > 0 && frag[0] == comment {
		return false
	}
	for b in frag {
		if b >= 0x80 || b == delim || b == '\n' || b == '\r' || b == '"' || b == '\\' {
			return false
		}
	}
	return true
}
