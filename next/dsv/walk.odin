package dsv

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// The walk of a delimited text over its passes (pass.odin): the options it reads, the header's keys it gives each
// row's cells, the pass instance it runs and the width fault it places.

// The header cells a walk keeps in its frame. A wider header's keys come from the read's allocator.
@(private)
FRAME_KEYS :: 128

// What a walk learned of the header: its cells as the keys it gave each row's cells, and the most cells a record had.
@(private)
Head :: struct {
	keys:   []tape.Token,
	widest: int,
}

// The delimiter byte of `spec` when `delimiter` is 0: `,` for CSV and Plain and a tab for TSV.
@(private)
spec_delimiter :: #force_inline proc "contextless" (spec: Spec, delimiter: u8) -> u8 {
	return delimiter if delimiter != 0 else '\t' if spec == .Tsv else ','
}

// The dsv options of `opts`, or the option of `opts` spec `S` cannot read. A delimiter is refused when it is CR, LF,
// non-ASCII or, under CSV, a quote, and under TSV also a backslash or one of `t`, `n`, `r`, `0`. A comment byte is
// refused when it is CR, LF, the delimiter, non-ASCII or, under CSV, a quote, and under TSV also a backslash.
@(private)
pass_options :: #force_inline proc "contextless" ($S: Spec, opts: tape.Options) -> (p: Pass_Options, refused: tape.Error) {
	if refused = tape.options_refused(&FORMATS[S], opts); refused != nil {
		return
	}
	d, _ := opts.format.(tape.Dsv_Options)
	delim, c := spec_delimiter(S, d.delimiter), d.comment
	bad_delim := delim == '\r' || delim == '\n' || delim >= 0x80
	bad_comment := c != 0 && (c == '\r' || c == '\n' || c == delim || c >= 0x80)
	when S == .Csv {
		bad_delim ||= delim == '"'
		bad_comment ||= c == '"'
	} else when S == .Tsv {
		bad_delim ||= delim == '\\' || delim == 't' || delim == 'n' || delim == 'r' || delim == '0'
		bad_comment ||= c == '\\'
	}
	if bad_delim {
		return {}, tape.Bad_Option{"delimiter"}
	}
	if bad_comment {
		return {}, tape.Bad_Option{"comment"}
	}
	return {tolerate = opts.tolerate, delim = delim, comment = c, no_header = d.no_header, infer = d.infer, limit = u64(opts.budget.depth) if opts.budget.depth != 0 else tape.DEFAULT_DEPTH}, nil
}

// Whether a pass under `p` reads every default, so it runs the instance that folds them.
@(private)
is_default :: #force_inline proc "contextless" ($S: Spec, p: Pass_Options) -> bool {
	return p.tolerate == {} && p.delim == spec_delimiter(S, 0) && p.comment == 0 && !p.no_header && !p.infer && p.limit >= 2
}

// Walks `src` as `S` for hook `h` from its registers `regs`, and returns where its root value ends or the error, and
// whether the walk used a rule of `opts.tolerate`. `head`, when given, holds the buffer for the header's keys, sized by
// `header_cells`, and is given the most cells a record had. Without it the keys are kept in the walk's frame, or past
// `FRAME_KEYS` in `allocator`. `ctx` is the caller's context for that allocation, nil for a hook with no tokens. A stop
// of the hook is no error, nor one of the hook's room, which the hook reports.
@(private)
walk_text :: #force_inline proc "contextless" (src: []u8, $S: Spec, $LAX: bool, p: Pass_Options, h: ^$H, regs: ^hook.Regs, allocator: runtime.Allocator, ctx: ^runtime.Context, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), head: ^Head, steps: u64 = 0) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	hook.check(H)
	C :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0)
	w: Pass(S, H, LAX, C)
	w.n, w.h, w.delim, w.tolerate, w.start, w.line = len(src), h, p.delim, p.tolerate, 1, 1
	w.in_header = !p.no_header
	when LAX {
		w.steps[0] = steps + 1 if steps != 0 && steps < max(u64) else max(u64)
	}
	when .Rooms in C {
		w.rooms = hook.rooms_end(h)
	}
	when .Columns in C {
		w.columns = ~u64(0)
	}
	owned: []tape.Token
	when H != hook.No_Hooks || LAX {
		frame: [FRAME_KEYS]tape.Token = ---
		if head != nil {
			w.keys = head.keys
		} else if !p.no_header {
			count := header_cells(src, int(text_start(src, 0)), S, p.delim, p.comment)
			if count <= FRAME_KEYS {
				w.keys = frame[:count]
			} else {
				context = ctx^
				e: runtime.Allocator_Error
				if owned, e = make([]tape.Token, count, allocator); e != nil {
					return 0, e, false
				}
				w.keys = owned
			}
		}
	}
	w.p = p
	when .Walk in C {
		h.walk = &w
	}
	r := run(&w, src, 0, p, regs, on)
	when .Walk in C {
		h.walk = nil
	}
	if owned != nil {
		context = ctx^
		delete(owned, allocator)
	}
	when LAX {
		if u8(r) == hook.WALK_STOPPED && w.steps[0] == 0 {
			r = hook.walk_result(u64(r) >> 16, hook.WALK_STEPS)
		}
	}
	if head != nil {
		head.widest = w.widest
	}
	root_close, err, _ = hook.walk_error(r, &RULES)
	return root_close, err, w.tolerated
}

// Walks again the record at `lo` of `w`'s text, which the walk passed and judged, for its hook: the record's tokens as
// its own walk gave them, its cells keyed by the header's, up to its `End`, past which no byte is read.
@(private)
walk_record_again :: proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	v: Pass(S, H, LAX, C)
	v.n, v.h, v.delim, v.tolerate, v.start, v.line, v.width, v.keys, v.p = len(src), w.h, w.delim, w.tolerate, 1, 1, w.width, w.keys, w.p
	v.opened, v.unclosed, v.again = true, true, true
	when LAX {
		v.steps[0] = max(u64)
	}
	p := w.p
	p.limit = max(u64)
	return run_pass(&v, src, lo, p, regs, on, true)
}

// Runs the pass instance for `p` over `src` from `lo`: one that folds the defaults when `p` takes them, else one with
// the comment code or one without. A validate whose walk counts no steps and whose text fits `Token.n` takes the
// instance with no tokens, and places its width fault.
@(private)
run :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, p: Pass_Options, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	when H == hook.No_Hooks && !LAX {
		if u64(len(src)) - lo <= u64(max(u32)) && p.limit >= 2 {
			width := w.width
			return field_count_fault(src, lo, S, p, run_pass(w, src, lo, p, regs, on, false), width)
		}
	}
	return run_pass(w, src, lo, p, regs, on, true)
}

@(private)
run_pass :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, p: Pass_Options, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), $EMIT: bool) -> hook.Walk_Result {
	if is_default(S, p) {
		return pass_default(w, src, lo, regs, on, EMIT)
	}
	if p.comment != 0 {
		return pass_options_of(w, src, lo, p, regs, on, EMIT, true)
	}
	return pass_options_of(w, src, lo, p, regs, on, EMIT, false)
}

// The tier the pass is built for besides the floor: on x86-64 the CPU's `.V3` where it has one, whose 32-byte registers
// halve the mask code of a block. Each tier is its own out-of-line instance (`pass_default_v3` and `pass_options_v3`
// in tier_amd64.odin), since a procedure takes only its own features.
@(private)
PASS_FLOOR :: kernel.Tier(0)

@(private)
PASS_FLOOR_FEATURES :: kernel.FEATURES[PASS_FLOOR]

// The pass with literal default options, which fold the option tests out of its code.
@(private)
pass_default :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), $EMIT: bool) -> hook.Walk_Result {
	when ODIN_ARCH == .amd64 {
		if kernel.tier() == .V3 {
			return pass_default_v3(w, src, lo, regs, on, EMIT)
		}
	}
	return pass_default_floor(w, src, lo, regs, on, EMIT)
}

@(private)
pass_options_of :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, p: Pass_Options, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), $EMIT, $COMMENTS: bool) -> hook.Walk_Result {
	when ODIN_ARCH == .amd64 {
		if kernel.tier() == .V3 {
			return pass_options_v3(w, src, lo, p, regs, on, EMIT, COMMENTS)
		}
	}
	return pass_options_floor(w, src, lo, p, regs, on, EMIT, COMMENTS)
}

@(private, enable_target_feature = PASS_FLOOR_FEATURES)
pass_default_floor :: #force_no_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), $EMIT: bool) -> hook.Walk_Result {
	hs := regs^
	defer regs^ = hs
	return pass(w, src, lo, default_options(S), &hs, on, EMIT, false, PASS_FLOOR)
}

@(private, enable_target_feature = PASS_FLOOR_FEATURES)
pass_options_floor :: #force_no_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, p: Pass_Options, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), $EMIT, $COMMENTS: bool) -> hook.Walk_Result {
	hs := regs^
	defer regs^ = hs
	return pass(w, src, lo, p, &hs, on, EMIT, COMMENTS, PASS_FLOOR)
}

// The verdict on the text from `lo` with no tokens, for a hooked walk whose hook passed over the text or the rest of
// it, from the first byte of a record or of the text. `width` above 0 is the width the records are checked against,
// and 0 has the first record set it. The tolerances it took are the walk's.
@(private, cold)
judge_from :: #force_no_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, p: Pass_Options, width: int) -> hook.Walk_Result {
	v: Pass(S, hook.No_Hooks, false, hook.NO_HOOKS_CAPS)
	v.n, v.delim, v.tolerate, v.start, v.line, v.width = len(src), p.delim, p.tolerate, 1, 1, width
	v.in_header = !p.no_header && width == 0
	q := p
	q.limit = max(u64)
	regs: hook.Regs
	r := run(&v, src, lo, q, &regs, hook.no_hook)
	w.tolerated ||= v.tolerated
	return r
}

// The width fault of a validate's pass placed at its byte: the delimiter that opens the cell past the width in a wide
// record, or the line end's first byte in a narrow one. A width fault at or before a byte fault wins. A walk with no
// fault returns `r` unchanged, and a faulting one rescans the records with `scan_record`. A `width` above 0 is the
// width a pass from a record's first byte checked records against, and 0 reads it from the first record.
@(private, cold)
field_count_fault :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, p: Pass_Options, r: hook.Walk_Result, width: int) -> hook.Walk_Result {
	kind := u8(r)
	if kind == 0 || kind >= hook.WALK_MORE || .Ragged in p.tolerate {
		return r
	}
	at := u64(r) >> 16
	detail := Detail(u64(r) >> 8 & 0xFF)
	width_fault := detail == .Too_Many || detail == .Too_Few
	end := len(src)
	pos := record_start(src, int(text_start(src, min(lo, u64(end)))), p.comment)
	if pos >= end {
		return r
	}
	width := width
	if width == 0 {
		width = scan_record(src, pos, 0, S, p.delim).cells
	}
	for pos < end {
		if at < u64(pos) {
			return r
		}
		s := scan_record(src, pos, width, S, p.delim)
		if at <= u64(s.line_end) {
			if s.fault_at >= 0 {
				if width_fault || u64(s.fault_at) < at {
					return fault_at(u64(s.fault_at), .Bad_Width, .Too_Many)
				}
			} else if width_fault && s.cells < width {
				return fault_at(u64(s.line_end_lo), .Bad_Width, .Too_Few)
			}
			return r
		}
		pos = record_start(src, s.line_end + 1, p.comment)
	}
	return r
}

// Walks `src` as `S` for hook `h` from its registers `regs`, the walk the reads above run. Returns where its root value
// ends or the error, and whether the walk used a rule of `opts.tolerate`. A stop of the hook is no error. The hook
// keeps the protocol `hook.check` checks, and has no `.Walk`, as only the reads above read a record again.
walk :: proc(src: []u8, $S: Spec, opts: Options, h: ^$H, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), allocator := context.allocator) -> (root_close: u64, err: tape.Error, tolerated: bool) {
	#assert(.Walk not_in intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, hook.PROTOCOL_FIELD), 0))
	p, refused := pass_options(S, opts)
	if refused != nil {
		return 0, refused, false
	}
	ctx := context
	if opts.pieces != nil {
		return piece_read(src, S, opts, h, regs, &ctx, on, nil)
	}
	if opts.budget.steps != 0 {
		return walk_text(src, S, true, p, h, regs, allocator, &ctx, on, nil, opts.budget.steps)
	}
	return walk_text(src, S, false, p, h, regs, allocator, &ctx, on, nil)
}
