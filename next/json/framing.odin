// JSON's record services (`core/records`). `.Lines` (NDJSON) and `.Seq` (RFC 7464) frame a record by a scan for the
// byte that ends it, and a record is read in place in the whole text, not as a slice cut from it. `.Concatenated` and
// `.Entries` frame a record by a walk of its value, which judges it.
package json

import "base:intrinsics"
import "base:runtime"
import core "../core"
import kernel "../core/kernel"
import typed "../core/typed"
import records "../core/records"

@(private, rodata)
RECORDS := records.Services {
	ends  = {.Lines = '\n', .Seq = 0x1e, .Concatenated = 0, .Entries = 0},
	next  = {.Lines = frame_line, .Seq = frame_line, .Concatenated = next_walked, .Entries = next_walked},
	judge = judge_record,
	guess = guess_start,
	exact = exact_cut,
	piece = piece_of,
	scan  = scan_record,
	whole = whole_text,
	read  = read_record,
	build = build_record,
}

// `As.opts[1]` is `PIECE` in a piece's reader, and `EXACT` in an `each` piece's under `.Entries`, which ends at the
// comma at `to`.
@(private)
PIECE, EXACT :: 1, 2

// Under `.Lines` and `.Seq` the end byte, and in strict JSON the LF between texts and the comma between entries, outside
// strings at the level of the first record. Comments and single quotes would hide brackets from the count.
@(private)
exact_cut :: proc(it: ^records.Reader) -> (kernel.Quotes, bool) {
	switch it.framing {
	case .Lines:        return {sep = '\n'}, true
	case .Seq:          return {sep = 0x1e}, true
	case .Concatenated: return {quote = '"', escape = '\\', sep = '\n', nest = true}, Spec(it.as.spec) == .Json
	case .Entries:      return {quote = '"', escape = '\\', sep = ',', nest = true, want = 1}, Spec(it.as.spec) == .Json
	}
	return {}, false
}

// A `.Seq` record starts at its 0x1E, and an entry past the first at the comma before it, one byte before the cut.
@(private)
piece_of :: proc(it: ^records.Reader, lo, hi: u64) -> bool {
	back := u64(it.framing == .Seq || it.framing == .Entries)
	end := hi - back if hi < u64(len(it.src)) else max(u64)
	if lo > 0 {
		it.pos = lo - back
	}
	if it.framing == .Entries {
		it.to, it.as.opts[1] = end, EXACT
	} else {
		it.src = it.src[:min(end, u64(len(it.src)))]
	}
	return true
}

// Moves a piece's reader to the first place at or past `it.pos` and before `to` where a record may start: under
// `.Lines` and `.Seq` past the next end byte unless one is before `it.pos`, under `.Concatenated` past the next LF,
// and under `.Entries` at the next comma, read as following an entry. A piece starts past the first record.
@(private)
guess_start :: proc(it: ^records.Reader, to: u64) -> bool {
	b: u8 = ',' if it.framing == .Entries else 0x1e if it.framing == .Seq else '\n'
	if it.framing >= .Concatenated || it.src[it.pos - 1] != b {
		it.pos = find_byte(it.src[:to], it.pos, b) + u64(it.framing != .Entries)
	}
	it.state[1] = 1
	it.as.opts[1] = PIECE
	return it.pos < to
}

// The whole text is the entries of its spine, or of its root.
@(private)
whole_text :: proc(src: []u8, as: core.As) -> (core.As, core.Framing, u64) {
	entries, at, ok := spine(src, as)
	return entries if ok else as, .Entries, at if ok && entries.opts[0] > 0 else 0
}

// The most objects deep `spine` looks for an array, and the most members and bytes of each it passes before one in an
// object.
SPINE_LEVELS :: 4
@(private)
SIDE_MEMBERS, SIDE_BYTES :: 16, 4096

// Finds the array that holds the bulk of `src`, read as `as`: its root array, or the array a root object holds up to
// `SPINE_LEVELS` objects deep, past at most `SIDE_MEMBERS` members in each object whose values end within `SIDE_BYTES`.
// A key on the way must be quoted with `"`. `at` is the array's `[`, and `records.open(src, entries, .Entries, at)`
// gives its elements, each judged at its depth in the text, then judges the text around the array once, at its close,
// so that every fault is the one `validate` gives for the whole text. False when there is none. Allocates nothing.
spine :: proc(src: []u8, as: core.As) -> (entries: core.As, at: u64, ok: bool) {
	levels: u8
	switch Spec(as.spec) {
	case .Json:  at, levels, ok = spine_of(src, options_of(as), .Json)
	case .Jsonc: at, levels, ok = spine_of(src, options_of(as), .Jsonc)
	case .Json5: at, levels, ok = spine_of(src, options_of(as), .Json5)
	}
	entries = as
	// The number of objects around the array.
	entries.opts[0] = levels
	return
}

@(private)
spine_of :: proc(src: []u8, opts: Options, $S: Spec) -> (at: u64, levels: u8, ok: bool) {
	p := raw_data(src)
	end := p[len(src):]
	none: core.No_Hooks
	zero: core.Hook_Regs
	q := gap_end(p[core.text_start(src, 0):], end, S)
	// The array's elements lie one level below it.
	for q < end && u32(levels) < (opts.max_depth if opts.max_depth != 0 else core.MAX_DEPTH) {
		if q[0] == '[' {
			return u64(intrinsics.ptr_sub(q, p)), levels, true
		}
		if q[0] != '{' || levels == SPINE_LEVELS {
			return
		}
		levels += 1
		for n := 0;; n += 1 {
			q = gap_end(q[1:], end, S)
			if n == SIDE_MEMBERS || q == end || q[0] != '"' {
				return
			}
			hi, fault, _ := walk_from(src, q, S, opts, &none, &zero, core.no_hook)
			q = gap_end(p[hi:], end, S)
			if fault != nil || q == end || q[0] != ':' {
				return
			}
			q = gap_end(q[1:], end, S)
			// A value that does not end within `SIDE_BYTES` is the one the spine runs through.
			at := intrinsics.ptr_sub(q, p)
			if hi, fault, _ = walk_from(src[:min(len(src), at + SIDE_BYTES)], q, S, opts, &none, &zero, core.no_hook); fault != nil {
				break
			}
			q = gap_end(p[hi:], end, S)
			if q == end || q[0] != ',' {
				return
			}
		}
	}
	return
}

@(private)
next_walked :: proc(it: ^records.Reader) -> (records.Record, bool) {
	switch Spec(it.as.spec) {
	case .Json:  return next_framed(it, .Json)
	case .Jsonc: return next_framed(it, .Jsonc)
	case .Json5: return next_framed(it, .Json5)
	}
	return {}, false
}

@(private)
next_framed :: proc(it: ^records.Reader, $S: Spec) -> (records.Record, bool) {
	h: core.No_Hooks
	regs: core.Hook_Regs
	rec, ok, _ := frame_value(it, S, options_of(it.as), &h, &regs, core.no_hook)
	return rec, ok
}

// Frames the next record under `.Concatenated` or `.Entries` by a walk of its value through the hook. `stopped` says
// the hook stopped the walk, so the record's end is not known and `it.pos` is no boundary.
//
// `.Concatenated`: each document of the text, as a loop of `walk` reads them, from its value's first byte. A fault ends
// the records.
//
// `.Entries`: each element of the root array, or the value of each member of the root object, whose key is in
// `rec.key`. Each value is walked one level below the root. A scalar root has no entries and is judged whole. Any
// fault ends the records with the fault of a walk of the text from `it.from`, which `validate` gives, as a fault in the root's
// own bytes depends on what came before. `state[0]` is the root's open bracket once it is read and 1 after its close,
// and `state[1]` is 1 after an entry. The entries of a `Spine` sit `levels` objects deeper, and at its close the text
// with them cut out is walked whole. A piece's reader ends on a fault whose place is not looked for.
@(private)
frame_value :: proc(it: ^records.Reader, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (rec: records.Record, ok: bool, stopped: bool) {
	src := it.src
	p := raw_data(src)
	end := p[len(src):]
	if it.framing == .Concatenated {
		q, _ := document_start(src, it.pos, S)
		q = gap_end(q, end, S)
		hi, fault, stop := walk_from(src, q, S, opts, h, regs, on)
		it.pos = hi
		if fault == nil && !stop && runs_on(src, q, hi, S, true) {
			fault = core.fault_of(core.fault_at(hi, .Bad_Char, u8(Detail.Trailing)), &RULES)
		}
		if fault != nil || q == end {
			it.fault = fault
			return
		}
		at := u64(intrinsics.ptr_sub(q, p))
		return {text = src[at:hi], at = at}, true, stop
	}
	if it.state[0] == 1 {
		return
	}
	q := gap_end(p[it.pos:], end, S)
	value := opts
	levels := u32(it.as.opts[0])
	value.max_depth = (opts.max_depth if opts.max_depth != 0 else core.MAX_DEPTH) - 1 - levels
	piece := it.as.opts[1] == PIECE
	key: []u8
	none: core.No_Hooks
	zero: core.Hook_Regs
	whole: {
		if it.state[0] == 0 {
			if q == end || q[0] != '[' && q[0] != '{' {
				break whole
			}
			it.state[0] = q[0]
			q = gap_end(q[1:], end, S)
		}
		// `]` and `}` are 2 past their open brackets.
		close := it.state[0] + 2
		closes := q < end && q[0] == close
		if it.state[1] == 1 && !closes {
			if it.as.opts[1] == EXACT && u64(intrinsics.ptr_sub(q, p)) >= it.to {
				return
			}
			if q == end || q[0] != ',' {
				break whole
			}
			q = gap_end(q[1:], end, S)
			closes = .Trailing_Commas in FEATURES[S] && q < end && q[0] == close
		}
		if closes {
			it.state[0] = 1
			if levels == 0 {
				it.fault = tail_fault(src, u64(intrinsics.ptr_sub(q, p)) + 1, S)
			} else if piece || !shell_valid(it, u64(intrinsics.ptr_sub(q, p)), S, opts) {
				break whole
			}
			return
		}
		if close == '}' {
			k := q
			if q < end && (q[0] == '"' || S == .Json5 && q[0] == '\'') {
				hi, fault, _ := walk_from(src, q, S, opts, &none, &zero, core.no_hook)
				if fault != nil {
					break whole
				}
				q = p[hi:]
			} else {
				when .Es5 in FEATURES[S] {
					if r, _, kind := ident5(q, end); kind == .None {
						q = r
					}
				}
				if q == k {
					break whole
				}
			}
			key = src[intrinsics.ptr_sub(k, p):intrinsics.ptr_sub(q, p)]
			q = gap_end(q, end, S)
			if q == end || q[0] != ':' {
				break whole
			}
			q = gap_end(q[1:], end, S)
		}
		// Under a root at the deepest level a value may be no container.
		if q == end || value.max_depth == 0 && (q[0] == '[' || q[0] == '{') {
			break whole
		}
		hi, fault, stop := walk_from(src, q, S, value, h, regs, on)
		if fault != nil || !stop && runs_on(src, q, hi, S, false) {
			break whole
		}
		at := u64(intrinsics.ptr_sub(q, p))
		it.pos = hi
		it.state[1] = 1
		return {text = src[at:hi], at = at, key = key}, true, stop
	}
	it.state[0] = 1
	if piece {
		it.fault = core.fault_of(core.fault_at(u64(intrinsics.ptr_sub(q, p)), .Bad_Char), &RULES)
	} else {
		it.fault = walk_text(src, 0 if levels > 0 else it.from, S, opts, &none, &zero, core.no_hook)
	}
	return
}

// Whether the text around a spine's array, closed at `close`, is valid with the array's elements cut out, so that with
// valid elements the whole text is. The copy is allocated with the reader's allocator, and a failed allocation is a no.
@(private)
shell_valid :: proc(it: ^records.Reader, close: u64, $S: Spec, opts: Options) -> bool {
	src := it.src
	open := u64(intrinsics.ptr_sub(gap_end(raw_data(src)[it.from:], raw_data(src)[len(src):], S), raw_data(src))) + 1
	shell, err := make([]u8, u64(len(src)) - (close - open), it.allocator)
	if err != nil {
		return false
	}
	defer delete(shell, it.allocator)
	copy(shell, src[:open])
	copy(shell[open:], src[close:])
	none: core.No_Hooks
	zero: core.Hook_Regs
	return walk_text(shell, 0, S, opts, &none, &zero, core.no_hook) == nil
}

// Whether the number or literal at `q`, which a walk ended at `hi`, runs on into a byte that may not follow a value, so
// that, as jq reads `1x`, it is one bad token and no record. Between `concatenated` texts, as jq reads them, a ',', ':',
// ']' or '}' runs on too, and so does a '/' where no comment may start.
@(private)
runs_on :: #force_inline proc "contextless" (src: []u8, q: [^]u8, hi: u64, $S: Spec, $concatenated: bool) -> bool {
	if hi >= u64(len(src)) {
		return false
	}
	switch q[0] {
	case '[', '{', '"', '\'':
		return false
	}
	switch src[hi] {
	case ',', ':', ']', '}':
		return concatenated
	case '/':
		return concatenated && .Comments not_in FEATURES[S]
	case ' ', '\t', '\r', '\n', 0x1e, '[', '{', '"', '\'':
		return false
	}
	when .Es5 in FEATURES[S] {
		return !gap(raw_data(src)[hi:], raw_data(src)[len(src):], S)
	}
	return true
}

// Returns the first byte at or past `q` that is no whitespace and, in a spec with comments, starts no comment, or the
// first byte of a comment that does not end.
@(private)
gap_end :: #force_inline proc "contextless" (q, end: [^]u8, $S: Spec) -> [^]u8 {
	when .Comments in FEATURES[S] {
		r, _, kind := comment_run(q, end, false, S)
		return r if kind == .None else q
	} else {
		return skip_ws(q, end)
	}
}

// Frames the next record under `.Lines` or `.Seq`: from its first byte that is no whitespace up to the next LF or
// 0x1E, less a CR before the LF. Whitespace alone is no record. Under `.Seq` a byte before the first 0x1E that is no
// whitespace is `Bad_Char`. A 0x1E in a line and an LF in a `.Seq` record are the record's.
@(private)
frame_line :: proc(it: ^records.Reader) -> (rec: records.Record, ok: bool) #no_bounds_check {
	src := it.src
	p := raw_data(src)
	end := p[len(src):]
	stop: u8 = '\n' if it.framing == .Lines else 0x1e
	for {
		w := skip_ws(p[it.pos:], end)
		if Spec(it.as.spec) == .Json5 {
			for n := ws5_len(w, end); n > 0; n = ws5_len(w, end) {
				w = skip_ws(w[n:], end)
			}
		}
		q := u64(intrinsics.ptr_sub(w, p))
		if q == u64(len(src)) {
			it.pos = q
			return
		}
		if p[q] == stop {
			it.pos = q + 1
			continue
		}
		if stop == 0x1e && it.pos == core.text_start(src, 0) {
			it.fault = core.fault_of(core.fault_at(q, .Bad_Char), &RULES)
			return
		}
		hi := find_byte(src, q, stop)
		it.pos = min(hi + 1, u64(len(src)))
		if stop == '\n' && p[hi - 1] == '\r' {
			hi -= 1
		}
		return {text = src[q:hi], at = q}, true
	}
}

// Returns the first offset at or past `lo` of byte `c` in `src`, or `len(src)`.
@(private)
find_byte :: #force_inline proc "contextless" (src: []u8, lo: u64, c: u8) -> u64 #no_bounds_check {
	if lo >= u64(len(src)) {
		return lo
	}
	if i := kernel.index_byte(src[lo:], c); i >= 0 {
		return lo + u64(i)
	}
	return u64(len(src))
}

@(private)
judge_record :: proc(it: ^records.Reader, rec: records.Record) -> Maybe(core.Fault) {
	if it.framing >= .Concatenated {
		return nil
	}
	switch Spec(it.as.spec) {
	case .Json:  return judge_spec(it, rec, .Json)
	case .Jsonc: return judge_spec(it, rec, .Jsonc)
	case .Json5: return judge_spec(it, rec, .Json5)
	}
	return nil
}

@(private)
judge_spec :: proc(it: ^records.Reader, rec: records.Record, $S: Spec) -> Maybe(core.Fault) {
	h: core.No_Hooks
	regs: core.Hook_Regs
	opts := options_of(it.as)
	fault, cold := walk_line(it.src, rec.at, rec.at + u64(len(rec.text)), S, opts, &h, &regs, core.no_hook)
	if cold {
		return walk_text(it.src[:rec.at + u64(len(rec.text))], rec.at, S, opts, &h, &regs, core.no_hook)
	}
	return fault
}

@(private)
read_record :: proc(it: ^records.Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Error) -> bool {
	if it.framing >= .Concatenated {
		switch Spec(it.as.spec) {
		case .Json:  return read_framed(it, target, T, plan, read, allocator, err, .Json)
		case .Jsonc: return read_framed(it, target, T, plan, read, allocator, err, .Jsonc)
		case .Json5: return read_framed(it, target, T, plan, read, allocator, err, .Json5)
		}
	}
	switch Spec(it.as.spec) {
	case .Json:  return read_spec(it, target, T, plan, read, allocator, err, .Json)
	case .Jsonc: return read_spec(it, target, T, plan, read, allocator, err, .Jsonc)
	case .Json5: return read_spec(it, target, T, plan, read, allocator, err, .Json5)
	}
	return false
}

// Reads the next record into `target` in place in the input. When only a read of the record alone tells the answer,
// that read goes into a scratch value, so `target` keeps what the read in place wrote and allocated, and the errors
// `read.collect` holds are the ones of the record alone.
@(private)
read_spec :: proc(it: ^records.Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Error, $S: Spec) -> bool {
	rec, ok := frame_line(it)
	if !ok {
		return false
	}
	lo := rec.at
	cut := lo + u64(len(rec.text))
	opts := options_of(it.as)
	c := read.collect
	kept: typed.Collected
	if c != nil {
		kept = c^
	}
	if !read_value(it.src, lo, cut, S, target, T, plan, read, opts, it.frames, allocator, runtime.arena_allocator(&it.scratch), err, true) {
		return true
	}
	uncollect(c, kept)
	// The scratch value and what its read allocates are dropped with the arena.
	arena := runtime.Arena{backing_allocator = it.allocator, minimum_block_size = 4096}
	defer runtime.arena_destroy(&arena)
	scratch_allocator := runtime.arena_allocator(&arena)
	scratch, failed := runtime.mem_alloc(type_info_of(T).size, type_info_of(T).align, scratch_allocator)
	if failed != nil {
		err^ = {kind = .Out_Of_Memory}
		return true
	}
	err^ = {}
	read_value(it.src, lo, cut, S, raw_data(scratch), T, plan, read, opts, it.frames, scratch_allocator, runtime.arena_allocator(&it.scratch), err, false)
	return true
}

// Reads the next record under `.Concatenated` or `.Entries` into `target` by the framing's own walk. A refusal stops
// that walk before the record's end, which a walk with no hook then finds. A record with a fault after a refusal is no
// record, as `next` gives none, and what the read collected is taken back.
@(private)
read_framed :: proc(it: ^records.Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Error, $S: Spec) -> bool {
	opts := options_of(it.as)
	if read.refuse_duplicates {
		// The duplicate check builds the record's text, so the framing's walk finds its end first.
		rec, ok := next_framed(it, S)
		if ok {
			read_value(it.src, rec.at, rec.at + u64(len(rec.text)), S, target, T, plan, read, opts, it.frames, allocator, runtime.arena_allocator(&it.scratch), err, false)
		}
		return ok
	}
	h: typed.Reader
	json_reader(&h, &opts, S)
	regs, started := typed.read_start(&h, it.src, plan, &SPELLING, T, target, read, it.frames, allocator)
	h.ctx.temp_allocator = runtime.arena_allocator(&it.scratch)
	if started.kind != .None {
		err^ = started
		return false
	}
	on :: typed.on_token_spelled when S == .Json5 else typed.on_token
	pos, state := it.pos, it.state
	kept: typed.Collected
	if read.collect != nil {
		kept = read.collect^
	}
	_, ok, stopped := frame_value(it, S, opts, &h, &regs, on)
	// A walk with a hook reads the comments after a value, so a fault there is past the record, which a walk with no
	// hook ends where `next` does.
	if stopped || it.fault != nil {
		it.pos, it.state, it.fault = pos, state, nil
		_, ok = next_framed(it, S)
	}
	if !ok {
		uncollect(read.collect, kept)
	} else if h.first.kind != .None {
		err^ = typed.read_end(&h, regs, nil)
	}
	return ok
}

// Takes back what the read of a record whose answer is another read's collected in `c`.
@(private)
uncollect :: proc(c: ^typed.Collected, kept: typed.Collected) {
	if c != nil {
		resize(&c.errors, len(kept.errors))
		c.truncated = kept.truncated
	}
}

// Builds the document of `rec`'s text. Its offsets in a fault count from the input's first byte.
@(private)
build_record :: proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator) -> (doc: core.Document, err: core.Document_Error) {
	spec := Spec(it.as.spec)
	// A BOM is the input's, and passed over only at its first byte.
	if rec.at > 0 && spec != .Json5 && len(rec.text) >= 3 && rec.text[0] == 0xef && rec.text[1] == 0xbb && rec.text[2] == 0xbf {
		return {}, {kind = .Walk, at = rec.at, inner = {at = rec.at, rules = &RULES, kind = .Bad_Char}}
	}
	doc, err = build_as(rec.text, it.as, false, allocator)
	if err.kind != .None {
		err.at += rec.at
		err.inner.at += rec.at
	}
	return
}

@(private)
FAULT_REACH :: 16

// The walk options a handle holds.
@(private)
options_of :: #force_inline proc "contextless" (as: core.As) -> Options {
	return {max_depth = as.max_depth, tolerate = transmute(bit_set[Tolerance; u8])as.tolerate}
}

// Walks the record `src[lo:cut]` of a `.Lines` or `.Seq` text in place in `src`. Returns the fault that a walk of the record's
// text alone gives, as `walk_text` on `src` cut at the record's end, or `cold` when only that walk can tell: the walk
// in place ran past the record's end, by a value spread over lines, or faulted near it. A fault depends on no byte
// more than `FAULT_REACH` past the byte it names, as a lone surrogate's escape is judged by the escape after it, so one
// further from the end is the same in both walks. The walk reads at most 64 bytes past the record, so a value spread
// over many lines costs no more than one.
@(private)
walk_line :: #force_inline proc(src: []u8, lo, cut: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (fault: Maybe(core.Fault), cold: bool) {
	hi, f, _ := walk_from(src[:min(u64(len(src)), cut + 64)], raw_data(src)[lo:], S, opts, h, regs, on)
	if x, bad := f.?; bad {
		return f, x.at + FAULT_REACH >= cut
	}
	if hi > cut {
		return nil, true
	}
	if hi < cut {
		return tail_fault(src[:cut], hi, S), false
	}
	return nil, false
}
