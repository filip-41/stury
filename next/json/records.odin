package json

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The records of a text read in one walk, whose gap table goes on from each record to the next, so that a record is
// read with the gaps the records before it taught. Each record is judged as a read of its bytes alone judges them, in
// place in the text.

// The records of a text of a JSON spec, which `records_open` makes and each call of `records_validate`,
// `records_find` or `records_scan` reads in batches, as `tape.Records` says.
Records :: struct {
	using records: tape.Records,
	spec:          Spec,
	// What the walk learned, kept from record to record. A walk of any spec and hook is laid out as this one, or as its
	// front when it has no `LAX`.
	walk:          Walk(.Json, hook.No_Hooks, true, hook.NO_HOOKS_CAPS),
}

#assert(size_of(Walk(.Json5, build.Scanner, false, build.SCANNER_CAPS)) <= size_of(Walk(.Json, hook.No_Hooks, true, hook.NO_HOOKS_CAPS)))
#assert(offset_of(Walk(.Json5, build.Scanner, false, build.SCANNER_CAPS), gaps) == offset_of(Walk(.Json, hook.No_Hooks, true, hook.NO_HOOKS_CAPS), gaps))

// A record's walk reads at most this far past its line, so a value that runs on past its line is refused after a
// bounded read, while every block the walk reads within the line has its bytes ahead.
@(private)
RECORD_AHEAD :: 256

// Opens the records of `src`, a text of `spec` framed as `framing`, each read under `opts`. The budget's limits hold
// for each record, but `Budget.steps` under `.Elements`, which counts the containers of the whole text. A text in
// pieces, or options of another format family, ends the records with `tape.Bad_Option` before any is read.
records_open :: proc(src: []u8, framing := tape.Framing.Lines, spec := Spec.Json, opts := Options{}) -> (r: Records) {
	if spec > max(Spec) {
		panic("json: spec out of range")
	}
	r.src, r.framing, r.spec, r.opts, r.pos = src, framing, spec, opts, u64(bom_length(src))
	if opts.pieces != nil {
		r.err, r.at = tape.Bad_Option{"pieces"}, .Done
	}
	if e := tape.options_refused(&FORMATS[spec], opts); e != nil {
		r.err, r.at = e, .Done
	}
	walk_init(&r.walk, src, nil, (^hook.No_Hooks)(nil), nil, {}, nil, build.read_depth(opts), opts.tolerate, opts.budget.steps)
	return
}

// Reads the next records of `r` into `out` and judges each, as `validate` judges its bytes alone. Returns how many it
// filled, and fewer than `len(out)` once the records have ended, when `err` says why, nil at the text's end. Only a
// record nesting past `WALK_LEVELS` allocates, for its open levels. Needs `READ_STACK` bytes of stack and faults on a
// thread with less.
@(require_results)
records_validate :: proc(r: ^Records, out: []tape.Record, allocator := context.allocator) -> (n: int) {
	probe_stack()
	lax := build.read_lax(r.opts)
	switch r.spec {
	case .Json:
		if lax {
			return records_validate_as(r, out, .Json, true, allocator)
		}
		return records_validate_as(r, out, .Json, false, allocator)
	case .Jsonc:
		if lax {
			return records_validate_as(r, out, .Jsonc, true, allocator)
		}
		return records_validate_as(r, out, .Jsonc, false, allocator)
	case .Json5:
		if lax {
			return records_validate_as(r, out, .Json5, true, allocator)
		}
		return records_validate_as(r, out, .Json5, false, allocator)
	}
	return
}

// Reads the next records of `r` into `out`, and for each the first value `path` reaches in it into the same place of
// `answers`, as `find` reads its bytes alone, with every offset from the text's first byte. Returns how many it filled,
// at most the shorter of the two slices, and fewer once the records have ended. Under `.Elements` and `.Members` the
// walk reads each value to its end whatever `read.stop_early` says, as the next starts there. Allocates as `find` does.
// Needs `READ_STACK` bytes of stack and faults on a thread with less.
@(require_results)
records_find :: proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	probe_stack()
	lax := build.read_lax(r.opts)
	switch r.spec {
	case .Json:
		if lax {
			return records_find_as(r, path, out, answers, .Json, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Json, false, read, allocator)
	case .Jsonc:
		if lax {
			return records_find_as(r, path, out, answers, .Jsonc, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Jsonc, false, read, allocator)
	case .Json5:
		if lax {
			return records_find_as(r, path, out, answers, .Json5, true, read, allocator)
		}
		return records_find_as(r, path, out, answers, .Json5, false, read, allocator)
	}
	return
}

// Reads the next records of `r` into `out`, and for each the document of its nodes the paths of `demand` reach into the
// same place of `docs`, as `scan` reads its bytes alone. Returns how many it filled, at most the shorter of the two
// slices, and fewer once the records have ended. Each document's nodes point into the text, and each is the caller's to
// free, so the memory a call holds is bounded by the slices it is given. Under `.Elements` and `.Members` the walk
// reads each value to its end whatever `read.stop_early` says, as the next starts there. Needs `READ_STACK` bytes of
// stack and faults on a thread with less.
@(require_results)
records_scan :: proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, read := tape.Read_Options{}, allocator := context.allocator) -> (n: int) {
	probe_stack()
	lax := build.read_lax(r.opts)
	switch r.spec {
	case .Json:
		if lax {
			return records_scan_as(r, demand, out, docs, .Json, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Json, false, read, allocator)
	case .Jsonc:
		if lax {
			return records_scan_as(r, demand, out, docs, .Jsonc, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Jsonc, false, read, allocator)
	case .Json5:
		if lax {
			return records_scan_as(r, demand, out, docs, .Json5, true, read, allocator)
		}
		return records_scan_as(r, demand, out, docs, .Json5, false, read, allocator)
	}
	return
}

@(private)
records_validate_as :: #force_no_inline proc(r: ^Records, out: []tape.Record, $S: Spec, $LAX: bool, caller: runtime.Allocator) -> int {
	frame :: #force_inline proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
		return record_frame_of(r, S, LAX, hook.No_Hooks)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^hook.No_Hooks, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walked(container_of(r, Records, "records"), S, LAX, lo, cut, alone, h, regs, a, ctx, hook.no_hook)
	}
	return build.records_validate(r, out, &RULES, caller, frame, walk)
}

@(private)
records_find_as :: #force_no_inline proc(r: ^Records, path: []tape.Step, out: []tape.Record, answers: []tape.Span_Answer, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	rewalk :: proc "contextless" (h: ^build.Finder, lo: u64) -> hook.Walk_Result {
		regs: hook.Regs
		return walk_again((^Walk(S, build.Finder, LAX, build.FINDER_CAPS))(h.walk), h.src, lo, &regs, build.finder_hook)
	}
	frame :: #force_inline proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
		return record_frame_of(r, S, LAX, build.Finder)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Finder, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walked(container_of(r, Records, "records"), S, LAX, lo, cut, alone, h, regs, a, ctx, build.finder_hook)
	}
	return build.records_find(r, path, out, answers, &FORMATS[S], &RULES, read, caller, respell, rewalk, frame, walk)
}

@(private)
records_scan_as :: #force_no_inline proc(r: ^Records, demand: ^tape.Demand, out: []tape.Record, docs: []tape.Document, $S: Spec, $LAX: bool, read: tape.Read_Options, caller: runtime.Allocator) -> int {
	rewalk :: proc "contextless" (h: ^build.Scanner, regs: ^hook.Regs, lo: u64) -> hook.Walk_Result {
		return walk_again((^Walk(S, build.Scanner, LAX, build.SCANNER_CAPS))(h.walk), h.b.doc.src, lo, regs, build.scanner_hook)
	}
	frame :: #force_inline proc(r: ^tape.Records) -> (lo, cut: u64, ok: bool) {
		return record_frame_of(r, S, LAX, build.Scanner)
	}
	walk :: #force_inline proc(r: ^tape.Records, lo, cut: u64, alone: bool, h: ^build.Scanner, regs: ^hook.Regs, a: runtime.Allocator, ctx: ^runtime.Context) -> build.Record_Walk {
		return record_walked(container_of(r, Records, "records"), S, LAX, lo, cut, alone, h, regs, a, ctx, build.scanner_hook)
	}
	return build.records_scan(r, demand, out, docs, &FORMATS[S], &RULES, read, caller, rewalk, node_bound, frame, walk)
}

// `record_frame` of the records `r` of a JSON spec, in the walk for hook `H`.
@(private)
record_frame_of :: #force_inline proc(r: ^tape.Records, $S: Spec, $LAX: bool, $H: typeid) -> (lo, cut: u64, ok: bool) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	j := container_of(r, Records, "records")
	return record_frame(j, (^Walk(S, H, LAX, C))(&j.walk))
}

// Walks the record from `lo` to `cut` for hook `h`, first in the walk of the whole text, or with `alone` as a text of
// its bytes alone.
@(private)
record_walked :: #force_inline proc(r: ^Records, $S: Spec, $LAX: bool, lo, cut: u64, alone: bool, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (walked: build.Record_Walk) {
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	w := (^Walk(S, H, LAX, C))(&r.walk)
	if alone {
		walked.res, walked.ok = record_alone(r, w, lo, cut, h, regs, allocator, ctx, on), true
	} else {
		walked.res, walked.hi, walked.again, walked.ok = record_first(r, w, lo, cut, h, regs, allocator, ctx, on)
	}
	walked.tolerated = w.tolerated
	return
}

// The next record's first byte, and under `.Lines` its line's end less a CR, under `.Elements` and `.Members` the text's
// end. Under `.Members` the key is read into `r.key` and the first byte is the value's. False once the records have
// ended. A fault in the text around the root container's elements or members ends them with the fault `validate` gives
// for the text.
@(private)
record_frame :: proc(r: ^Records, w: ^Walk($S, $H, $LAX, $C)) -> (lo, cut: u64, ok: bool) {
	if r.at == .Done {
		return
	}
	n := u64(len(r.src))
	if r.framing == .Lines {
		base := raw_data(r.src)
		lo = u64(intrinsics.ptr_sub(kernel.skip_ws(base[r.pos:], base[n:]), base))
		if lo == n {
			r.at = .Done
			return
		}
		cut = n
		if i := kernel.index_byte(r.src[lo:], '\n'); i >= 0 {
			cut = lo + u64(i)
		}
		r.pos = min(cut + 1, n)
		if r.src[cut - 1] == '\r' {
			cut -= 1
		}
		return lo, cut, true
	}
	at, next := element_next(r, w)
	switch next {
	case .Element:
		if r.framing == .Members {
			if at = record_key(r, w, at); at == 0 {
				records_refuse(r, nil)
				return
			}
		}
		return at, n, true
	case .End:
		r.at = .Done
	case .Fault:
		records_refuse(r, nil)
	}
	return
}

@(private)
Element_Next :: enum u8 {
	Element,
	End,
	Fault,
}

// Where the root container's next element starts, or under `.Members` its next member's key, past the open bracket or
// the comma before it, or whether the container and the text end there or hold something else.
@(private)
element_next :: proc "contextless" (r: ^Records, w: ^Walk($S, $H, $LAX, $C)) -> (at: u64, next: Element_Next) #no_bounds_check {
	base := raw_data(r.src)
	end := base[len(r.src):]
	open, close := u8('['), u8(']')
	if r.framing == .Members {
		open, close = '{', '}'
	}
	q := element_gap(base[r.pos:], end, S)
	if q == nil || q == end {
		return 0, .Fault
	}
	switch r.at {
	case .Start:
		if q[0] != open {
			return 0, .Fault
		}
		when LAX {
			// The root container takes a step, as each container does.
			w.steps[0] -= 1
			if w.steps[0] == 0 {
				return 0, .Fault
			}
		}
		r.at, r.pos = .Open, u64(intrinsics.ptr_sub(q, base)) + 1
		if q = element_gap(q[1:], end, S); q == nil || q == end {
			return 0, .Fault
		}
		fallthrough
	case .Open:
		if q[0] == close {
			return 0, element_close(q, end, S)
		}
	case .After:
		if q[0] == close {
			return 0, element_close(q, end, S)
		}
		if q[0] != ',' {
			return 0, .Fault
		}
		if q = element_gap(q[1:], end, S); q == nil || q == end {
			return 0, .Fault
		}
		when S != .Json {
			if q[0] == close {
				return 0, element_close(q, end, S)
			}
		}
	case .Done:
	}
	return u64(intrinsics.ptr_sub(q, base)), .Element
}

// Whether the text ends past the root container's close bracket at `q`, with white space and comments alone after it.
@(private)
element_close :: #force_inline proc "contextless" (q, end: [^]u8, $S: Spec) -> Element_Next {
	return .End if element_gap(q[1:], end, S) == end else .Fault
}

// The first byte past the white space and comments from `p`, nil at a comment that does not end.
@(private)
element_gap :: #force_inline proc "contextless" (p, end: [^]u8, $S: Spec) -> [^]u8 {
	when S == .Json {
		return kernel.skip_ws(p, end)
	} else {
		q, _, kind := comment_run(p, end, false, S)
		return q if kind == .None else nil
	}
}

// Ends the records with the error `validate` gives for the text, or `err` when it gives none.
@(private, cold)
records_refuse :: proc(r: ^Records, err: tape.Error) {
	r.err = validate(r.src, r.spec, r.opts)
	if r.err == nil {
		r.err = err
	}
	r.at = .Done
}

// Walks the record that `record_frame` framed from `lo` to `cut` for hook `h` from registers `regs`, and returns the
// walk's result, the record's end, and under `.Lines` whether the record must be walked again alone, which the walk
// in the whole text reads as no walk of its line would. False once the records have ended, as under `.Elements` a
// fault in an element ends them.
@(private)
record_first :: #force_inline proc(r: ^Records, w: ^Walk($S, $H, $LAX, $C), lo, cut: u64, h: ^H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> (res: hook.Walk_Result, hi: u64, alone, ok: bool) {
	base := raw_data(r.src)
	n := u64(len(r.src))
	if r.framing == .Lines {
		res = record_walk(r, w, lo, base[min(n, cut + RECORD_AHEAD):], build.read_depth(r.opts), h, regs, allocator, ctx, false, on)
		return res, cut, !line_read(r.src, res, cut), true
	}
	when LAX {
		left := w.steps[0]
	}
	res = record_walk(r, w, lo, base[n:], build.read_depth(r.opts) - 1, h, regs, allocator, ctx, false, on)
	if u8(res) == hook.WALK_STOPPED {
		// The hook refused the value, which leaves the walk short of its end, so a walk with no hook finds it.
		// The refusal is the record's error, as it is for a line.
		when LAX {
			w.steps[0] = left
		}
		plain := (^Walk(S, hook.No_Hooks, LAX, hook.NO_HOOKS_CAPS))(w)
		none: hook.No_Hooks
		none_regs: hook.Regs
		end := record_walk(r, plain, lo, base[n:], build.read_depth(r.opts) - 1, &none, &none_regs, allocator, ctx, false, hook.no_hook)
		if u8(end) != 0 {
			_, err, _ := hook.walk_error(end, &RULES)
			records_refuse(r, err)
			return
		}
		hi = u64(end) >> 16
		r.pos, r.at = hi, .After
		return res, hi, false, true
	}
	if u8(res) != 0 {
		_, err, _ := hook.walk_error(res, &RULES)
		records_refuse(r, err)
		return
	}
	hi = u64(res) >> 16
	r.pos, r.at = hi, .After
	return res, hi, false, true
}

// The hook of the walk that reads a member's key, which keeps the key and stops the walk.
@(private)
Member_Key :: struct {
	protocol: hook.Protocol(hook.NO_HOOKS_CAPS, hook.Unused, hook.Unused, hook.Unused),
	key:      tape.Token,
}

#assert(size_of(Walk(.Json5, Member_Key, true, hook.NO_HOOKS_CAPS)) == size_of(Walk(.Json, hook.No_Hooks, true, hook.NO_HOOKS_CAPS)))
#assert(offset_of(Walk(.Json5, Member_Key, true, hook.NO_HOOKS_CAPS), gaps) == offset_of(Walk(.Json, hook.No_Hooks, true, hook.NO_HOOKS_CAPS), gaps))

@(private)
member_key_hook :: proc "contextless" (h: ^Member_Key, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action) {
	h.key = t
	return s, .Stop
}

// The level of the root object, as the walk's states name a container: its depth and its kind bit.
@(private)
MEMBER_LEVEL :: u64(1 << 1 | 1)

// Reads the key of the member at `at` into `r.key` with the walk's own key states, and returns where its value starts,
// past the colon and the gaps around it, or 0 when the key, the colon or the text fails.
@(private)
record_key :: proc "contextless" (r: ^Records, w: ^Walk($S, $H, $LAX, $C), at: u64) -> u64 {
	base := raw_data(r.src)
	end := base[len(r.src):]
	h: Member_Key
	regs: hook.Regs
	res := key_walk(r, (^Walk(S, Member_Key, LAX, hook.NO_HOOKS_CAPS))(w), at, &h, &regs)
	if u8(res) != hook.WALK_STOPPED {
		return 0
	}
	q := element_gap(base[u64(res) >> 16:], end, S)
	if q == nil || q == end || q[0] != ':' {
		return 0
	}
	if q = element_gap(q[1:], end, S); q == nil || q == end {
		return 0
	}
	r.key = h.key
	return u64(intrinsics.ptr_sub(q, base))
}

// Walks the key of the member at `at` for hook `h`, which stops on it, and returns the walk's result.
@(private)
key_walk :: proc "contextless" (r: ^Records, w: ^Walk($S, Member_Key, $LAX, $C), at: u64, h: ^Member_Key, regs: ^hook.Regs) -> hook.Walk_Result {
	stack: [2]u32
	when LAX {
		left := w.steps[0]
	}
	walk_start(w, r.src, raw_data(stack[:]), h, regs, {}, nil, build.read_depth(r.opts), r.opts.tolerate, r.opts.budget.steps)
	when LAX {
		w.piece[0] = nil
		w.steps[0] = left
	}
	w.depth = min(w.limit, WALK_LEVELS)
	res := enter_member(raw_data(r.src)[at:], raw_data(r.src)[len(r.src):], MEMBER_LEVEL, INDENT_START, w, regs^, GAP_OFF, member_key_hook)
	w.hooks, w.regs, w.ctx, w.stack, w.allocator = nil, nil, nil, nil, {}
	return res
}

// Walks the record from `lo` to `cut` as a text of those bytes alone, and returns the walk's result.
@(private, cold)
record_alone :: #force_no_inline proc(r: ^Records, w: ^Walk($S, $H, $LAX, $C), lo, cut: u64, h: ^H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	return record_walk(r, w, lo, raw_data(r.src)[cut:], build.read_depth(r.opts), h, regs, allocator, ctx, true, on)
}

// Whether the walk in the whole text with result `res` read the record that ends at `cut` as a walk of its bytes alone
// reads them: its value ended, or the hook stopped the walk, within them, and only white space follows the value.
@(private)
line_read :: #force_inline proc "contextless" (src: []u8, res: hook.Walk_Result, cut: u64) -> bool #no_bounds_check {
	hi := u64(res) >> 16
	if hi > cut {
		return false
	}
	switch u8(res) {
	case 0:
		for c in src[hi:cut] {
			if c != ' ' && c != '\t' && c != '\r' {
				return false
			}
		}
		return true
	case hook.WALK_STOPPED:
		return true
	}
	return false
}

// Walks the value at `lo` to `end` for hook `h` from registers `regs`, in the walk of `r` with its gap table, within
// `limit` levels. With `TAIL` what follows the value up to `end` is judged as a text's tail.
@(private)
record_walk :: #force_inline proc "contextless" (r: ^Records, w: ^Walk($S, $H, $LAX, $C), lo: u64, end: [^]u8, limit: u64, h: ^H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $TAIL: bool, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	stack: [WALK_LEVELS]u32 = ---
	when LAX {
		left := w.steps[0]
	}
	walk_start(w, r.src, raw_data(stack[:]), h, regs, allocator, ctx, limit, r.opts.tolerate, r.opts.budget.steps)
	when LAX {
		w.piece[0] = nil
		if r.framing != .Lines {
			w.steps[0] = left
		}
	}
	w.depth = held_depth(h, regs, min(w.limit, WALK_LEVELS))
	when .Walk in C {
		h.walk = w
	}
	res := enter(raw_data(r.src)[lo:], end, INDENT_START, w, regs^, GAP_START, on)
	when TAIL {
		res = walk_tail(w, res, end, on)
	}
	when .Walk in C {
		h.walk = nil
	}
	when LAX {
		if u8(res) == hook.WALK_STOPPED && w.steps[0] == 0 {
			res = hook.walk_result(u64(res) >> 16, hook.WALK_STEPS)
		}
	}
	if w.owned {
		levels_free(w)
	}
	// The records keep the walk past the call, and none of the caller's frame.
	w.hooks, w.regs, w.ctx, w.stack, w.allocator = nil, nil, nil, nil, {}
	return res
}
