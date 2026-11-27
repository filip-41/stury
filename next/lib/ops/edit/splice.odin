package edit

import "base:runtime"
import "core:bytes"
import "core:container/xar"
import "core:math"
import "core:slice"
import "core:strconv"
import "stury:lib/base/spell"
import "stury:lib/core/tape"

// Byte-level splice engine and shared composer utilities.
// Applies sorted non-overlapping replacements and move-blocks iteratively (zero recursion),
// computes exact output byte ranges for `Commit_Result.rewritten` and `Splice_Record`s.

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

Move :: struct {
	lo, hi:  u64,
	text:    []u8,
	written: bool,
}

// Common commit entry guard shared by all 5 composers.
commit_guard :: proc(
	ov: ^Overlay,
	spec_target: ^tape.Format,
	opts: Options,
	extra_clean: bool,
	validate: proc(data: rawptr, src: []u8, allocator: runtime.Allocator) -> tape.Error,
	validate_data: rawptr,
	allocator: runtime.Allocator,
) -> (done: bool, target: ^tape.Format, res: Commit_Result, err: Error) {
	if ov == nil || ov.base == nil { return false, nil, {}, refuse(.No_Document, "overlay has no document") }
	if ov.base.partial != nil { return false, nil, {}, refuse(.Partial_Document, "cannot commit a partial document") }
	doc := ov.base
	target = opts.target if opts.target != nil else (spec_target if spec_target != nil else doc.format)
	if !ov.dirty && extra_clean {
		if target != doc.format && validate != nil {
			if verr := validate(validate_data, doc.src, allocator); verr != nil { return false, target, {}, convert_tape_error(verr) }
		}
		cloned := slice.clone(doc.src, allocator) or_return
		return true, target, Commit_Result{bytes = cloned, allocator = allocator}, nil
	}
	return false, target, {}, nil
}

@(private)
convert_tape_error :: proc "contextless" (err: tape.Error) -> Error {
	switch e in err {
	case tape.Fault: return e
	case tape.Exceeded: return e
	case tape.Bad_Option: return e
	case runtime.Allocator_Error: return e
	case tape.Piece_Gap: return refuse(.Invalid_Result, "unexpected piece gap")
	}
	return nil
}

// Applies `splices` to `src` into a fresh byte buffer from `allocator`, recording output `Splice_Record`s
// and `rewritten` ranges. Sorts `splices` in place.
apply_splices :: proc(src: []u8, splices: []Splice, allocator: runtime.Allocator) -> (out: []u8, records: []Splice_Record, rewritten: []Byte_Range, err: Error) {
	has_moves, strictly_sorted, prev_lo := false, true, u64(0)
	for s, i in splices {
		if len(s.moves) > 0 { has_moves = true }
		if i > 0 && s.lo <= prev_lo { strictly_sorted = false }
		prev_lo = s.lo
	}
	if !strictly_sorted || has_moves {
		slice.sort_by(splices, proc(a, b: Splice) -> bool {
			if a.lo != b.lo { return a.lo < b.lo }
			am, bm := len(a.moves) > 0, len(b.moves) > 0
			if am != bm { return am }
			if a.hi != b.hi { return a.hi < b.hi if !am else a.hi > b.hi }
			return a.seq < b.seq
		})
	}
	if has_moves {
		return apply_move_splices(src, splices, allocator)
	}
	return apply_flat_splices(src, splices, allocator)
}

@(private = "file")
apply_flat_splices :: proc(src: []u8, splices: []Splice, allocator: runtime.Allocator) -> (out: []u8, records: []Splice_Record, rewritten: []Byte_Range, err: Error) {
	reach, total, n_rewritten := u64(0), i64(len(src)), 0
	for s in splices {
		if s.lo < reach || s.lo > s.hi || s.hi > u64(len(src)) {
			return nil, nil, nil, refuse(.Layout_Reflow_Needed, "overlapping or out-of-range splices", s.base_node, s.lo)
		}
		reach = s.hi
		total += i64(len(s.text)) - i64(s.hi - s.lo)
		if s.rewritten { n_rewritten += 1 }
	}
	raw: []u8
	if total > 0 { raw = (runtime.mem_alloc_non_zeroed(int(total), 1, allocator) or_return)[:int(total)] }
	defer if err != nil && raw != nil { delete(raw, allocator) }
	recs: []Splice_Record
	if len(splices) > 0 {
		rmem := runtime.mem_alloc_non_zeroed(len(splices) * size_of(Splice_Record), align_of(Splice_Record), allocator) or_return
		recs = ([^]Splice_Record)(raw_data(rmem))[:len(splices)]
	}
	defer if err != nil && recs != nil { delete(recs, allocator) }
	rew: []Byte_Range
	if n_rewritten > 0 { rew = make([]Byte_Range, n_rewritten, allocator) or_return }
	w, at, ri := 0, u64(0), 0
	for s, i in splices {
		if s.lo > at { w += copy(raw[w:], src[at:s.lo]) }
		dst_lo := u64(w)
		if len(s.text) > 0 { w += copy(raw[w:], s.text) }
		dst_hi := u64(w)
		recs[i] = {s.base_node, s.lo, s.hi, dst_lo, dst_hi, s.subtree_only, s.full_rewalk}
		if s.rewritten {
			rew[ri] = {dst_lo, dst_hi}
			ri += 1
		}
		at = s.hi
	}
	if at < u64(len(src)) { copy(raw[w:], src[at:]) }
	return raw, recs, rew, nil
}

// Iterative move-splice applicator (explicit heap stack, zero native recursion).
@(private = "file")
apply_move_splices :: proc(src: []u8, splices: []Splice, allocator: runtime.Allocator) -> (out: []u8, records: []Splice_Record, rewritten: []Byte_Range, err: Error) {
	Frame :: struct {
		splices:        []Splice,
		lo, hi, at:     u64,
		i, m_idx:       int,
		in_move:        bool,
		moves:          []Move,
		inner:          []Splice,
		parent_rec_idx: int,
	}
	buf := make([dynamic]u8, 0, len(src), allocator)
	defer if err != nil { delete(buf) }
	recs := make([dynamic]Splice_Record, 0, len(splices), allocator)
	defer if err != nil { delete(recs) }
	rew := make([dynamic]Byte_Range, 0, 4, allocator)
	defer if err != nil { delete(rew) }
	stack := make([dynamic]Frame, 0, 16, allocator)
	defer delete(stack)

	append(&stack, Frame{splices = splices, hi = u64(len(src)), parent_rec_idx = -1}) or_return

	for len(stack) > 0 {
		f := &stack[len(stack) - 1]
		if f.in_move {
			if f.m_idx >= len(f.moves) {
				if f.parent_rec_idx >= 0 { recs[f.parent_rec_idx].dst_hi = u64(len(buf)) }
				f.in_move = false
				continue
			}
			m := f.moves[f.m_idx]
			f.m_idx += 1
			if m.written {
				append(&buf, ..m.text) or_return
				continue
			}
			next_owns_hi := false
			for nm in f.moves[f.m_idx:] {
				if !nm.written && nm.lo == m.hi {
					next_owns_hi = true
					break
				}
			}
			sub_lo := 0
			for sub_lo < len(f.inner) && f.inner[sub_lo].lo < m.lo { sub_lo += 1 }
			sub_hi := sub_lo
			for sub_hi < len(f.inner) {
				in_s := f.inner[sub_hi]
				if in_s.hi > m.hi || (in_s.lo == m.hi && (in_s.hi != m.hi || next_owns_hi)) { break }
				sub_hi += 1
			}
			append(&stack, Frame{splices = f.inner[sub_lo:sub_hi], lo = m.lo, hi = m.hi, at = m.lo, parent_rec_idx = -1}) or_return
			continue
		}

		if f.i >= len(f.splices) {
			if f.at < f.hi { append(&buf, ..src[f.at:f.hi]) or_return }
			pop(&stack)
			continue
		}

		s := f.splices[f.i]
		if s.lo < f.at || s.lo > s.hi || s.hi > f.hi {
			return nil, nil, nil, refuse(.Layout_Reflow_Needed, "overlapping splices in reordered block", s.base_node, s.lo)
		}
		if s.lo > f.at { append(&buf, ..src[f.at:s.lo]) or_return }
		f.i += 1
		f.at = s.hi

		if len(s.moves) == 0 {
			dst_lo := u64(len(buf))
			if len(s.text) > 0 { append(&buf, ..s.text) or_return }
			dst_hi := u64(len(buf))
			if len(stack) == 1 { append(&recs, Splice_Record{s.base_node, s.lo, s.hi, dst_lo, dst_hi, s.subtree_only, s.full_rewalk}) or_return }
			if s.rewritten { append(&rew, Byte_Range{dst_lo, dst_hi}) or_return }
			continue
		}

		j := f.i
		for j < len(f.splices) && (f.splices[j].lo < s.hi || (f.splices[j].lo == s.hi && f.splices[j].hi == s.hi)) { j += 1 }
		inner := f.splices[f.i:j]
		f.i = j
		rec_idx := -1
		if len(stack) == 1 {
			dst_lo := u64(len(buf))
			append(&recs, Splice_Record{s.base_node, s.lo, s.hi, dst_lo, dst_lo, false, s.full_rewalk}) or_return
			rec_idx = len(recs) - 1
		}
		f.in_move, f.moves, f.inner, f.m_idx, f.parent_rec_idx = true, s.moves, inner, 0, rec_idx
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

@(private)
skip_hws :: proc "contextless" (src: []u8, p, hi: u64) -> u64 {
	q := p
	for q < hi && (src[q] == ' ' || src[q] == '\t') {
		q += 1
	}
	return q
}

@(private)
trim_left_hws :: proc "contextless" (src: []u8, p: u64) -> u64 {
	q := p
	for q > 0 && (src[q - 1] == ' ' || src[q - 1] == '\t') {
		q -= 1
	}
	return q
}

first_on_line :: proc "contextless" (src: []u8, p: u64) -> bool {
	return skip_hws(src, line_start(src, p), p) == p
}

line_indent :: proc "contextless" (src: []u8, pos: u64) -> string {
	ls := line_start(src, pos)
	return string(src[ls:skip_hws(src, ls, u64(len(src)))])
}

detect_eol :: proc "contextless" (src: []u8) -> string {
	if i := bytes.index_byte(src[:min(len(src), 65536)], '\n'); i > 0 && src[i - 1] == '\r' {
		return "\r\n"
	}
	return "\n"
}

@(private)
default_indent_unit :: proc "contextless" (opts: Options) -> string {
	if opts.tab {
		return "\t"
	}
	switch opts.indent {
	case 1: return " "
	case 3: return "   "
	case 4: return "    "
	}
	return "  "
}

// Temporary decoded text of a base tape node or token (borrowed directly from `doc.src` when no escapes exist).
Tmp_Text :: struct {
	text:  string,
	owned: bool,
}

@(private)
decode_token_text_tmp :: proc(doc: ^tape.Document, t: tape.Token, allocator: runtime.Allocator) -> Tmp_Text {
	room := tape.text_room(doc, t)
	if room == 0 {
		return {text = string(tape.span_bytes(doc, t.lo, t.n))}
	}
	buf, err := make([]u8, room, allocator)
	if err != nil {
		return {}
	}
	if ds, ok := tape.node_text(doc, t, buf); ok {
		if raw_data(ds) == raw_data(buf) {
			return {text = ds, owned = true}
		}
		delete(buf, allocator)
		return {text = ds}
	}
	delete(buf, allocator)
	return {}
}

decode_node_text_tmp :: proc(doc: ^tape.Document, at: tape.Node_Index, allocator: runtime.Allocator) -> Tmp_Text {
	if doc == nil || at == tape.NO_NODE || int(at) >= len(doc.nodes) {
		return {}
	}
	return decode_token_text_tmp(doc, doc.nodes[at], allocator)
}

free_tmp_text :: proc(k: Tmp_Text, allocator: runtime.Allocator) {
	if k.owned && len(k.text) > 0 {
		delete(k.text, allocator)
	}
}

// Returns the authored byte range `[lo, hi)` of a base node in `doc.src`.
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
		return t.lo, end, cok
	}
	head, tail: u8
	if doc.format != nil && doc.format.bounds != nil {
		head, tail = doc.format.bounds(doc.src, t)
	}
	return t.lo - u64(head), t.lo + u64(t.n) + u64(tail), true
}

// Validates a reorder permutation `order` over `len(deleted)` original items plus `insert_count` inserts.
validate_order :: proc(order: []u32, deleted: []bool, insert_count: int, allocator: runtime.Allocator) -> Error {
	n := len(deleted)
	total := n + insert_count
	seen := make([]bool, total, allocator) or_return
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
push_splice :: proc(
	splices: ^[dynamic]Splice,
	lo, hi: u64,
	text: []u8 = nil,
	base_node := tape.NO_NODE,
	subtree_only := false,
	full_rewalk := false,
	rewritten := false,
	moves: []Move = nil,
) -> runtime.Allocator_Error {
	_, err := append(splices, Splice{lo, hi, text, len(splices), moves, base_node, subtree_only, full_rewalk, rewritten})
	return err
}

@(private)
push_move_str :: proc(moves: ^[dynamic]Move, s: string, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	b := slice.clone(transmute([]u8)s, allocator) or_return
	_, err := append(moves, Move{text = b, written = true})
	return err
}

@(private)
alloc_exact_slice :: proc(items: []$T, allocator: runtime.Allocator) -> (out: []T, err: runtime.Allocator_Error) {
	if len(items) == 0 {
		return nil, nil
	}
	raw := runtime.mem_alloc_non_zeroed(len(items) * size_of(T), align_of(T), allocator) or_return
	out = ([^]T)(raw_data(raw))[:len(items)]
	copy(out, items)
	return out, nil
}

@(private)
find_edited_child :: proc "contextless" (ov: ^Overlay, base_node: tape.Node_Index) -> (Handle, ^Edit_Node, bool) {
	if ch, has := ov.by_base[base_node]; has {
		if cn, ok := get_node(ov, ch); ok && cn.has_edits {
			return ch, cn, true
		}
	}
	return NO_HANDLE, nil, false
}

@(private)
base_item_comment_bounds :: proc "contextless" (doc: ^tape.Document, vn: tape.Node_Index, lo, hi: u64) -> (head_lo, inline_hi: u64) {
	head_lo, inline_hi = lo, hi
	for f in tape.facts_of(doc, vn) {
		if f.kind == .Comment && f.lo < head_lo {
			head_lo = f.lo
		} else if f.kind == .Comment_Inline && f.lo + u64(f.n) > inline_hi {
			inline_hi = f.lo + u64(f.n)
		}
	}
	return head_lo, inline_hi
}

@(private)
base_delta_status :: proc "contextless" (d: ^Container_Delta, key: string, idx: u32, is_obj: bool) -> (deleted: bool, renamed_to: string) {
	if d == nil {
		return false, ""
	}
	if !is_obj {
		return slice.contains(d.deleted_indices[:], idx), ""
	}
	if slice.contains(d.deleted_keys[:], key) {
		return true, ""
	}
	for r in d.renamed_members {
		if r.old_key == key {
			return false, r.new_key
		}
	}
	return false, ""
}

@(private)
comment_delete_span :: proc "contextless" (src: []u8, lo, hi: u64, inline: bool) -> (u64, u64) {
	if inline {
		return trim_left_hws(src, lo), hi
	}
	if first_on_line(src, lo) {
		q := hi
		for q < u64(len(src)) && (src[q] == ' ' || src[q] == '\t' || src[q] == '\r') {
			q += 1
		}
		if q < u64(len(src)) && src[q] == '\n' {
			return line_start(src, lo), q + 1
		}
	}
	return lo, hi
}

@(private)
format_float_str :: proc(f: f64, buf: []u8) -> string {
	if math.is_nan(f) {
		return "NaN"
	}
	if math.is_inf(f) {
		return "-Infinity" if f < 0 else "Infinity"
	}
	return strconv.write_float(buf, f, 'g', -1, 64, {})
}

@(private)
has_utf8_bom :: #force_inline proc "contextless" (b: []u8) -> bool {
	return len(b) >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF
}

@(private = "file")
is_simple_ascii_quoted :: proc "contextless" (frag: []u8, hi_excl: u8) -> bool {
	if len(frag) < 2 || frag[len(frag) - 1] != '"' {
		return false
	}
	for b in frag[1 : len(frag) - 1] {
		if b < 0x20 || b >= hi_excl || b == '"' || b == '\\' {
			return false
		}
	}
	return true
}

@(private)
is_simple_json_scalar :: proc "contextless" (frag: []u8) -> bool {
	if len(frag) == 0 {
		return false
	}
	switch frag[0] {
	case '0' ..= '9', '-':
		_, ok := spell.number_strict(frag, 0, u64(len(frag)))
		return ok
	case 't': return string(frag) == "true"
	case 'f': return string(frag) == "false"
	case 'n': return string(frag) == "null"
	case '"': return is_simple_ascii_quoted(frag, 0x80)
	}
	return false
}

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
		if sn.kind == .Float && !math.is_inf(transmute(f64)sn.bits) {
			for b in frag {
				if b == '.' || b == 'e' || b == 'E' {
					return true
				}
			}
		}
		return false
	case 't': return string(frag) == "true"
	case 'f': return string(frag) == "false"
	case '"': return is_simple_ascii_quoted(frag, 0x7F)
	}
	return false
}

@(private)
is_simple_xml_text :: proc "contextless" (frag: []u8) -> bool {
	for b in frag {
		if b >= 0x80 || b == '<' || b == '&' || b == ']' || b == '>' || (b < 0x20 && b != '\t' && b != '\n' && b != '\r') {
			return false
		}
	}
	return true
}

@(private)
is_simple_dsv_cell :: proc "contextless" (frag: []u8, delim, comment: u8, at_start: bool) -> bool {
	if (at_start && has_utf8_bom(frag)) || (comment != 0 && len(frag) > 0 && frag[0] == comment) {
		return false
	}
	for b in frag {
		if b >= 0x80 || b == delim || b == '\n' || b == '\r' || b == '"' || b == '\\' {
			return false
		}
	}
	return true
}

// Common commit runner shared by all 4 text-family composers (bracket, markup, section, tabular).
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
run_text_commit :: proc(ov: ^Overlay, tc: ^Text_Composer, opts: Options, allocator: runtime.Allocator) -> (res: Commit_Result, err: Error) {
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
		if tc.struct_emit != nil {
			tc.struct_emit(tc.user, ov, doc, detect_eol(doc.src), &splices, &dropped, scratch) or_return
		}
	}

	out, recs, rew := apply_splices(doc.src, splices[:], allocator) or_return
	defer if err != nil {
		delete(out, allocator)
		delete(recs, allocator)
		delete(rew, allocator)
	}
	if tc.validate != nil {
		need_full := target != doc.format || len(recs) == 0
		if !need_full && tc.frag_check != nil {
			need_full = tc.frag_check(tc.user, out, recs, scratch) or_return
		}
		if need_full {
			if verr := tc.validate(tc.validate_data, out, allocator); verr != nil {
				return {}, convert_tape_error(verr)
			}
		}
	}
	return Commit_Result{out, dropped, rew, recs, allocator}, nil
}

@(private)
drop_splices_in_range :: proc(splices: ^[dynamic]Splice, lo, hi: u64, allocator: runtime.Allocator, keep_at_hi_node := tape.NO_NODE) {
	w := 0
	for s in splices^ {
		inside := s.lo >= lo && s.hi <= hi && !(keep_at_hi_node != tape.NO_NODE && s.base_node == keep_at_hi_node && s.lo == hi)
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
