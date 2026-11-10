// JSON's record services (`core/records`). `.Lines` (NDJSON) and `.Seq` (RFC 7464) frame a record by a scan for the
// byte that ends it, and a record is read in place in the whole text, not as a slice cut from it. `.Concatenated` and
// `.Entries` frame a record by a walk of its value, which judges it.
package json

import "base:intrinsics"
import "base:runtime"
import core "../core"
import kernel "../core/kernel"
import build "../core/build"
import typed "../core/typed"
import records "../core/records"

// The byte of `Reader.state` past the framing's own two: the objects around an `.Entries` reader's array.
@(private)
LEVELS :: 2

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
		// The piece ends at the comma at `to`.
		it.to = end
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
	return it.pos < to
}

// The whole text is the entries of its spine, or of its root.
@(private)
whole_spec :: proc(src: []u8, as: core.As, $S: Spec) -> (core.As, core.Framing, u64) {
	at, levels, ok := spine_of(src, options_of(as), S)
	return as, .Entries, at if ok && levels > 0 else 0
}

// The most objects deep `spine` looks for an array, and the most members and bytes of each it passes before one in an
// object.
@(private)
SPINE_LEVELS, SIDE_MEMBERS, SIDE_BYTES :: 4, 16, 4096

// Finds the array that holds the bulk of `src`, read as `as`: its root array, or the array a root object holds up to
// `SPINE_LEVELS` objects deep, past at most `SIDE_MEMBERS` members in each object whose values end within `SIDE_BYTES`.
// A key on the way must be quoted with `"`. `at` is the array's `[` and `levels` the objects around it, and
// `records.open(src, as, .Entries, at)` gives its elements, each judged at its depth in the text, then judges the text
// around the array once, at its close, so that every fault is the one `validate` gives for the whole text. False when
// there is none. Allocates nothing.
spine :: proc(src: []u8, as: core.As) -> (at: u64, levels: int, ok: bool) {
	switch Spec(as.spec) {
	case .Json:  return spine_of(src, options_of(as), .Json)
	case .Jsonc: return spine_of(src, options_of(as), .Jsonc)
	case .Json5: return spine_of(src, options_of(as), .Json5)
	}
	return
}

@(private)
spine_of :: proc(src: []u8, opts: Options, $S: Spec) -> (at: u64, levels: int, ok: bool) {
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
next_walked_spec :: #force_inline proc(it: ^records.Reader, $S: Spec) -> (rec: records.Record, ok: bool) {
	h: core.No_Hooks
	regs: core.Hook_Regs
	rec, ok, _ = frame_walked(it, S, options_of(it.as), &h, &regs, core.no_hook)
	return
}

// Frames the next record under `.Concatenated` or `.Entries` by a walk of its value through the hook. `stopped` says
// the hook stopped the walk, so the record's end is not known and `it.pos` is no boundary.
@(private)
frame_walked :: proc(it: ^records.Reader, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (records.Record, bool, bool) {
	if it.framing == .Entries {
		return frame_entry(it, S, opts, h, regs, on)
	}
	return frame_document(it, S, opts, h, regs, on)
}

// `frame_walked` under `.Concatenated`: each document of the text, as a loop of `walk` reads them, from its value's
// first byte. A fault ends the records, and a 0x1E between documents is one, as jq reads its input.
@(private)
frame_document :: proc(it: ^records.Reader, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (rec: records.Record, ok: bool, stopped: bool) {
	src := it.src
	q, sep := document_start(src, it.pos, S)
	if sep != nil {
		it.fault = core.Fault{at = u64(intrinsics.ptr_sub(sep, raw_data(src))), rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Control_Char)}
		return
	}
	q = gap_end(q, raw_data(src)[len(src):], S)
	hi, fault, stop := walk_from(src, q, S, opts, h, regs, on)
	it.pos = hi
	if fault == nil && !stop && runs_on(src, q, hi, S, true) {
		fault = core.Fault{at = hi, rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Trailing)}
	}
	at := u64(intrinsics.ptr_sub(q, raw_data(src)))
	if fault != nil || at == u64(len(src)) {
		it.fault = fault
		return
	}
	return {text = src[at:hi], at = at}, true, stop
}

// `frame_walked` under `.Entries`: each element of the root array, or the value of each member of the root object,
// whose key is in `rec.key`. Each value is walked one level below the root. A scalar root has no entries and is judged
// whole. Any fault ends the records with the fault of a walk of the text from `it.from`, which `validate` gives, as a
// fault in the root's own bytes depends on what came before. `state[0]` is the root's open bracket once it is read and
// 1 after its close, and `state[1]` is 1 after an entry. The entries of the array `spine` finds, when the records start
// at its `[`, sit `levels` objects deeper, and at its close the text with them cut out is walked whole. A piece's
// reader ends on a fault whose place is not looked for.
@(private)
frame_entry :: proc(it: ^records.Reader, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (rec: records.Record, ok: bool, stopped: bool) {
	src := it.src
	p := raw_data(src)
	end := p[len(src):]
	if it.state[0] == 1 {
		return
	}
	if it.state[0] == 0 && it.from > 0 {
		if at, levels, found := spine_of(src, opts, S); found && at == it.from {
			it.state[LEVELS] = u8(levels)
		}
	}
	q := gap_end(p[it.pos:], end, S)
	value := opts
	levels := u32(it.state[LEVELS])
	value.max_depth = (opts.max_depth if opts.max_depth != 0 else core.MAX_DEPTH) - 1 - levels
	piece := it.guessed
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
			if it.to != 0 && u64(intrinsics.ptr_sub(q, p)) >= it.to {
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
			if q < end && (q[0] == '"' || .Es5 in FEATURES[S] && q[0] == '\'') {
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
		it.fault = core.Fault{at = u64(intrinsics.ptr_sub(q, p)), rules = &RULES, kind = .Bad_Char}
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
// 0x1E, less a CR before the LF. Whitespace alone is no record. A 0x1E in a line and an LF in a `.Seq` record are the
// record's. Under `.Seq` it notes in `it.state[1]` whether the record is `UNFRAMED`.
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
		if stop == 0x1e {
			it.state[1] = UNFRAMED if it.pos == core.text_start(src, 0) else 0
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
judge_spec :: #force_inline proc(it: ^records.Reader, rec: records.Record, $S: Spec) -> Maybe(core.Fault) {
	if it.framing >= .Concatenated {
		return nil
	}
	h: core.No_Hooks
	regs: core.Hook_Regs
	opts := options_of(it.as)
	fault, cold := walk_line(it.src, rec.at, rec.at + u64(len(rec.text)), S, opts, &h, &regs, core.no_hook)
	if cold {
		fault = walk_text(it.src[:rec.at + u64(len(rec.text))], rec.at, S, opts, &h, &regs, core.no_hook)
	}
	return seq_fault(it, rec, fault) if it.framing == .Seq else fault
}

// A `.Seq` record of the bytes before the first 0x1E, in `it.state[1]`.
@(private)
UNFRAMED :: 1

// The fault of a `.Seq` record given `fault`, its text's alone, as RFC 7464 frames it. Bytes before the first 0x1E are
// `Unframed` at their first. A record holds one text, so a value with more after it is refused whole with its text's
// `Trailing` fault. A number with no whitespace after it may have been cut short, so it is `Cut_Number`.
@(private)
seq_fault :: proc(it: ^records.Reader, rec: records.Record, fault: Maybe(core.Fault)) -> Maybe(core.Fault) {
	if it.state[1] == UNFRAMED {
		return core.Fault{at = rec.at, rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Unframed)}
	}
	if fault != nil {
		return fault
	}
	for c in rec.text {
		switch c {
		case '0' ..= '9', '-', '+', '.', 'e', 'E':
		case: return nil
		}
	}
	return core.Fault{at = rec.at + u64(len(rec.text)), rules = &RULES, kind = .Bad_Number, detail = u8(Detail.Cut_Number)}
}

// Reads the next record into `target`, under `.Seq` as `seq_fault` frames it. A check, which a model's load plan needs,
// frames the record first under every framing and reads its text in place.
@(private)
read_spec :: #force_inline proc(it: ^records.Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Refusal, $S: Spec, $CHECK: bool) -> bool {
	rec: records.Record
	ok: bool
	when CHECK {
		if it.framing >= .Concatenated {
			rec, ok = it.services.next[it.framing](it)
		} else {
			rec, ok = frame_line(it)
		}
	} else {
		if it.framing >= .Concatenated {
			return read_framed(it, target, T, plan, read, allocator, err, S)
		}
		rec, ok = frame_line(it)
	}
	if !ok {
		return false
	}
	when !CHECK {
		if it.framing == .Lines {
			// Inlined, with the read in place in it, so the reader of each line is one procedure.
			#force_inline read_line(it, rec.at, rec.at + u64(len(rec.text)), target, T, plan, read, allocator, err, S)
			return true
		}
	}
	kept := typed.sink_mark(read.sink)
	if it.state[1] != UNFRAMED || CHECK && it.framing != .Seq {
		when CHECK {
			read_value(it.src, rec.at, rec.at + u64(len(rec.text)), S, target, T, plan, read, options_of(it.as), it.frames, allocator, runtime.arena_allocator(&it.scratch), err, false, true)
			if it.framing != .Seq {
				return true
			}
		} else {
			read_line(it, rec.at, rec.at + u64(len(rec.text)), target, T, plan, read, allocator, err, S)
		}
		// A number the walk passed may have been cut short whatever the target makes of it.
		if _, bad := seq_fault(it, rec, nil).?; !bad || err.kind == .Walk {
			return true
		}
		typed.sink_restore(read.sink, kept)
	}
	// The record is refused with its `seq_fault`, collected with the read's allocator.
	f := seq_fault(it, rec, nil).?
	err^ = {kind = .Walk, at = f.at, inner = f}
	context.allocator = allocator
	typed.sink_error(read.sink, err^)
	return true
}

// Reads `it.src[lo:cut]` into `target` in place in the input. When only a read of the text alone tells the answer,
// that read goes into a scratch value, so `target` keeps what the read in place wrote and allocated, and the errors
// `read.sink` holds are the ones of the text alone.
@(private)
read_line :: proc(it: ^records.Reader, lo, cut: u64, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Refusal, $S: Spec) {
	opts := options_of(it.as)
	kept := typed.sink_mark(read.sink)
	if !#force_inline read_value(it.src, lo, cut, S, target, T, plan, read, opts, it.frames, allocator, runtime.arena_allocator(&it.scratch), err, true, false) {
		return
	}
	typed.sink_restore(read.sink, kept)
	// The scratch value and what its read allocates are dropped with the arena.
	arena := runtime.Arena{backing_allocator = it.allocator, minimum_block_size = 4096}
	defer runtime.arena_destroy(&arena)
	scratch_allocator := runtime.arena_allocator(&arena)
	scratch, failed := runtime.mem_alloc(type_info_of(T).size, type_info_of(T).align, scratch_allocator)
	if failed != nil {
		err^ = {kind = .No_Memory}
		return
	}
	err^ = {}
	read_value(it.src, lo, cut, S, raw_data(scratch), T, plan, read, opts, it.frames, scratch_allocator, runtime.arena_allocator(&it.scratch), err, false, false)
}

// Reads the next record under `.Concatenated` or `.Entries` into `target` by the framing's own walk. A refusal stops
// that walk before the record's end, which a walk with no hook then finds. A record with a fault after a refusal is no
// record, as `next` gives none, and what the read collected is taken back.
@(private)
read_framed :: proc(it: ^records.Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Refusal, $S: Spec) -> bool {
	opts := options_of(it.as)
	if read.dups == .Refuse {
		// The duplicate check builds the record's text, so the framing's walk finds its end first.
		rec, ok := it.services.next[it.framing](it)
		if ok {
			read_value(it.src, rec.at, rec.at + u64(len(rec.text)), S, target, T, plan, read, opts, it.frames, allocator, runtime.arena_allocator(&it.scratch), err, false, false)
		}
		return ok
	}
	h: typed.Reader
	json_reader(&h, &opts, S)
	regs, started := typed.read_start(&h, it.src, plan, it.as, T, target, read, it.frames, allocator, false)
	h.ctx.temp_allocator = runtime.arena_allocator(&it.scratch)
	if started.kind != .None {
		err^ = started
		return false
	}
	defer typed.read_release(&h, it.frames)
	on :: typed.on_token_spelled when .Es5 in FEATURES[S] else typed.on_token
	pos, state := it.pos, it.state
	kept := typed.sink_mark(read.sink)
	_, ok, stopped := frame_walked(it, S, opts, &h, &regs, on)
	// A walk with a hook reads the comments after a value, so a fault there is past the record, which a walk with no
	// hook ends where `next` does.
	if stopped || it.fault != nil {
		it.pos, it.state, it.fault = pos, state, nil
		_, ok = it.services.next[it.framing](it)
	}
	if !ok {
		typed.sink_restore(read.sink, kept)
	} else if h.first.kind != .None {
		err^ = typed.read_end(&h, regs, nil)
	}
	return ok
}

// Checks the records of `it` under `.Concatenated` or `.Entries` as `Record_Docs.check_run` says. The records are walked in
// place, once, by the framing walk with the check as its hook. The check's state is made once and set back to its start
// for each record, except for a plan that holds a value, whose arms leave state in it.
@(private)
check_run_spec :: proc(it: ^records.Reader, plan: ^typed.Plan, read: typed.Read_Options, visit: records.Record_Visit, data: rawptr, $S: Spec) {
	opts := options_of(it.as)
	if it.framing < .Concatenated || read.dups == .Refuse {
		it.fault = core.Fault{kind = .Bad_Option}
		return
	}
	on :: typed.on_token_check_spelled when S == .Json5 else typed.on_token_check
	stack: [core.MAX_DEPTH + 2]typed.Frame = ---
	frames := untracked_frames(stack[:])
	walk_opts := opts
	target: u8
	h: typed.Check
	regs, start: core.Hook_Regs
	renew, held := true, plan.fork != 0
	for {
		if renew {
			// The pool's runs and forks keep no entry's state, so each entry takes them over and temp does not grow per
			// entry.
			pool, fork := h.pool, h.fork
			h = {}
			h.pool, h.fork = pool, fork
			json_reader(&h.reader, untracked(&walk_opts), S)
			started: core.Typed_Refusal
			start, started = typed.check_start(&h, it.src, plan, plan.as, nil, &target, read, frames, context.allocator)
			if started.kind != .None {
				it.fault = core.Fault{kind = .Bad_Option}
				return
			}
			h.ctx.temp_allocator = context.temp_allocator
			renew = held
		} else {
			h.sp, h.fatal, h.wrap_sp, h.wrap, h.expect = 1, .None, 0, nil, nil
			h.tracked, h.floor = 0, len(read.sink.entries) if read.sink != nil else 0
			h.first.kind = .None
			h.frames[0].seen = 0
		}
		regs = start
		pos, state := it.pos, it.state
		kept := typed.sink_mark(read.sink)
		own: typed.Sink
		rec: records.Record
		ok: bool
		first: core.Typed_Refusal
		for judged := false; ; judged = true {
			stopped: bool
			rec, ok, stopped = frame_walked(it, S, opts, &h, &regs, on)
			// A walk with a hook reads the comments after a value, so a fault there is past the record, and a walk the hook
			// stopped did not find its end. The framing's own walk finds where the record ends.
			if stopped || it.fault != nil {
				it.pos, it.state, it.fault = pos, state, nil
				rec, ok = it.services.next[it.framing](it)
			}
			first = {}
			if ok && h.first.kind != .None {
				first = typed.read_end(&h, regs, nil)
			}
			if judged || first.kind != .Duplicate_Key || read.repeats != .Notice || read.dups == .Refuse {
				break
			}
			// A repeat the check noticed: the record is walked again, judging its repeats as `read.dups` says.
			again := typed.rejudge(read, kept, &own, context.allocator)
			pool, fork := h.pool, h.fork
			h = {}
			h.pool, h.fork = pool, fork
			json_reader(&h.reader, untracked(&walk_opts), S)
			start, _ = typed.check_start(&h, it.src, plan, plan.as, nil, &target, again, frames, context.allocator)
			h.ctx.temp_allocator = context.temp_allocator
			regs = start
			it.pos, it.state, it.fault = pos, state, nil
			renew = true
		}
		if own.entries.allocator.procedure != nil {
			first = typed.rejudged(&own, first)
		}
		if held {
			typed.read_release(&h, frames)
		}
		if !ok {
			typed.sink_restore(read.sink, kept)
			break
		}
		if !visit(data, rec, first) {
			break
		}
		if read.sink != nil {
			read.sink.record += 1
		}
	}
	if !held {
		typed.read_release(&h, frames)
	}
}

// Builds the document of `rec`'s text, under `.Seq` as `seq_fault` frames it. Its offsets in a fault count from the
// input's first byte.
@(private)
build_record_spec :: #force_inline proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator, $S: Spec) -> (doc: core.Document, err: core.Document_Error) {
	// An unframed `.Seq` record is refused whole by `seq_fault`.
	if it.framing != .Seq || it.state[1] != UNFRAMED {
		if stray_bom(rec.text, rec.at, S) {
			return {}, {kind = .Walk, at = rec.at, inner = {at = rec.at, rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Expected_Value)}}
		}
		doc, err = build_spec(rec.text, S, it.as, false, allocator)
	}
	if it.framing == .Seq && err.kind == .None {
		// `seq_fault` takes the record's offset in the window, which a stream's `rec.at` is not.
		if f, bad := seq_fault(it, {text = rec.text, at = rec.at - it.base}, nil).?; bad {
			core.destroy(&doc)
			f.at += it.base
			return {}, {kind = .Walk, at = f.at, inner = f}
		}
	}
	core.move_document_error(&err, rec.at)
	return
}

// Frames the next record under `.Concatenated` or `.Entries` by the walk that writes its nodes to `b`. Strict JSON
// alone, whose walk gives no comment, which the builder's plain hooks take for a node.
@(private)
build_next_spec :: proc(it: ^records.Reader, b: ^build.Builder, regs: ^core.Hook_Regs, $S: Spec) -> (rec: records.Record, ok: bool) {
	when S == .Json {
		if it.framing < .Concatenated {
			it.fault = core.Fault{kind = .Bad_Option}
		} else if b.refuse {
			rec, ok, _ = frame_walked(it, .Json, options_of(it.as), b, regs, build.builder_hook_plain_refuse)
		} else {
			rec, ok, _ = frame_walked(it, .Json, options_of(it.as), b, regs, build.builder_hook_plain)
		}
	} else {
		it.fault = core.Fault{kind = .Bad_Option}
	}
	return
}

// The walk options a handle holds.
@(private)
options_of :: #force_inline proc "contextless" (as: core.As) -> Options {
	return {max_depth = as.max_depth, tolerate = as.tolerate, refuse_non_finite = as.opts[0] != 0}
}

// Walks the record `src[lo:cut]` of a `.Lines` or `.Seq` text in place in `src`. Returns the fault that a walk of the record's
// text alone gives, as `walk_text` on `src` cut at the record's end, or `cold` when only that walk can tell: the walk
// in place ran past the record's end, by a value spread over lines, or faulted within `core.FAULT_REACH` bytes of it.
// A fault further from the end is the same in both walks. The walk reads at most 64 bytes past the record, so a value spread
// over many lines costs no more than one.
@(private)
walk_line :: #force_inline proc(src: []u8, lo, cut: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (fault: Maybe(core.Fault), cold: bool) {
	hi, f, _ := walk_from(src[:min(u64(len(src)), cut + 64)], raw_data(src)[lo:], S, opts, h, regs, on)
	if x, bad := f.?; bad {
		return f, x.at + core.FAULT_REACH >= cut
	}
	if hi > cut {
		return nil, true
	}
	if hi < cut {
		return tail_fault(src[:cut], hi, S), false
	}
	return nil, false
}
