package dsv

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/core/hook"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// The walk of a delimited text that every read runs: it picks the pass instance (pass.odin) for the options and the
// CPU's tier, gives each row's cells the header's keys, and places the width fault of a validate's pass.

// The most header keys a walk keeps in its frame. A wider header's keys come from the read's allocator. A delimited
// walk does not recurse, so its frame is a pass and these keys, which the assert holds to 4 KiB.
@(private)
FRAME_KEYS :: 128

#assert(size_of(Pass(.Csv, build.Scanner, true, build.SCANNER_CAPS)) + FRAME_KEYS * size_of(tape.Token) <= 4 * 1024)

// The header's cells as the keys given to each row's cells, and the most cells a record had.
@(private)
Head :: struct {
	keys:   []tape.Token,
	widest: int,
}

// Returns the buffer for `count` header keys: `room[:count]` when `count` fits `room`, else a block of `allocator`,
// made under `ctx`. The caller frees that block when the result is longer than `room`.
@(private)
header_keys :: proc "contextless" (count: int, room: []tape.Token, allocator: runtime.Allocator, ctx: ^runtime.Context) -> ([]tape.Token, tape.Error) {
	if count <= len(room) {
		return room[:count], nil
	}
	context = ctx^
	keys, err := make([]tape.Token, count, allocator)
	if e := build.took(err, raw_data(keys), count); e != nil {
		return nil, e
	}
	return keys, nil
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
	pass_start(&w, len(src), h, p, steps)
	w.in_header = !p.no_header
	owned: []tape.Token
	when H != hook.No_Hooks || LAX {
		frame: [FRAME_KEYS]tape.Token = ---
		if head != nil {
			w.keys = head.keys
		} else if !p.no_header {
			e: tape.Error
			if w.keys, e = header_keys(header_cells(src, S, p.delim, p.comment), frame[:], allocator, ctx); e != nil {
				return 0, e, false
			}
			if len(w.keys) > FRAME_KEYS {
				owned = w.keys
			}
		}
	}
	w.p = p
	when .Walk in C {
		h.walk = &w
	}
	when .Columns in C {
		// A record of another width than the header's is a fault, unless `.Ragged` reads it. A record the hook replays
		// has at most `hook.COLUMN_BITS` columns, as `column_bit` gives each its own bit only below that.
		cells: [hook.COLUMN_BITS]tape.Token = ---
		h.replay.fixed, h.replay.cells = .Ragged not_in p.tolerate, cells[:]
	}
	r: hook.Walk_Result
	when .Columns in C && S == .Csv && !LAX {
		if h.alike && len(w.keys) >= MASKED_WIDTH {
			// The same walk state read by the instance that takes the learnt columns by mask.
			m := (^Pass(S, H, LAX, C + MASK_COLUMNS))(&w)
			r = steps_ended(m, run(m, src, 0, p, regs, on))
		} else {
			r = steps_ended(&w, run(&w, src, 0, p, regs, on))
		}
	} else {
		r = steps_ended(&w, run(&w, src, 0, p, regs, on))
	}
	when .Walk in C {
		h.walk = nil
	}
	when .Columns in C {
		h.replay.cells = nil
	}
	if owned != nil {
		context = ctx^
		delete(owned, allocator)
	}
	if head != nil {
		head.widest = w.widest
	}
	root_close, err, _ = hook.walk_error(r, &RULES)
	return root_close, err, w.tolerated
}

// Walks the record at `lo` of `w`'s text a second time for its hook, after the walk passed and checked it. Gives the
// record's tokens as its own walk gave them, its cells keyed by the header's, up to its `End`. No byte past the `End`
// is read.
@(private)
walk_record_again :: proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	v: Pass(S, H, LAX, C)
	v.n, v.h, v.delim, v.tolerate, v.start, v.line, v.width, v.keys, v.p = len(src), w.h, w.delim, w.tolerate, 1, 1, w.width, w.keys, w.p
	v.opened, v.unclosed, v.again = true, true, true
	v.steps[0] = max(u64)
	p := w.p
	p.limit = max(u64)
	return run_pass(&v, src, lo, p, regs, on, true)
}

// Runs the pass instance for `p` over `src` from `lo`: the instance that folds in the defaults when `p` is the default
// options, else the one with the comment code, which a pass with no comment byte runs too. A validate whose walk counts no steps and whose text
// fits `Token.n` runs the instance with no tokens, then places its width fault.
@(private)
run :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, p: Pass_Options, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action)) -> hook.Walk_Result {
	when H == Record_Run {
		when LAX {
			if w.piece[0] != nil {
				r := run_pass(w, src, lo, p, regs, on, false)
				return field_count_fault(src, u64(w.rec_lo), S, p, r, w.width)
			}
		}
		width := w.width
		r := run_pass(w, src, lo, p, regs, on, false)
		return field_count_fault(src, record_run_from(w.h, src, lo, r), S, p, r, width)
	} else when H == hook.No_Hooks {
		if u64(len(src)) - lo <= u64(max(u32)) && p.limit >= RECORD_DEPTH && counts_cells(w) {
			when LAX {
				if w.piece[0] != nil {
					// A window holds the open record's first byte but not the text before it, so a width fault is
					// placed from there, against the width the pass has by now.
					r := run_pass(w, src, lo, p, regs, on, false)
					return field_count_fault(src, u64(w.rec_lo), S, p, r, w.width)
				}
			}
			width := w.width
			r := run_pass(w, src, lo, p, regs, on, false)
			return field_count_fault(src, lo, S, p, r, width)
		}
	}
	return run_pass(w, src, lo, p, regs, on, true)
}

// Whether a validate's walk counts the cells of its records instead of giving tokens: every walk of a whole text, and a
// walk of a window of a text in pieces once the header, whose keys it gives, has ended or been read.
@(private)
counts_cells :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C)) -> bool {
	when LAX {
		return w.piece[0] == nil || !w.in_header || w.piece[0].keyed
	} else {
		return true
	}
}

@(private)
run_pass :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, p: Pass_Options, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), $EMIT: bool) -> hook.Walk_Result {
	when !EMIT {
		if w.steps[0] == max(u64) && is_default(S, p) {
			when LAX {
				if w.piece[0] != nil {
					return pass_default_floor((^Pass(S, H, false, (C - MASK_COLUMNS) + PIECE_WINDOW))(w), src, lo, regs, on, false)
				}
			}
			return pass_default((^Pass(S, H, false, C - MASK_COLUMNS))(w), src, lo, regs, on, false)
		}
	} else when !LAX {
		if is_default(S, p) {
			return pass_default(w, src, lo, regs, on, EMIT)
		}
	}
	// Non-default options, pieces and step-budgeted walks share one `pass_with` instance per `(S, H, C - MASK_COLUMNS)`.
	return pass_with(as_lax(w), src, lo, p, regs, on, EMIT)
}

// The floor tier of the pass. On x86-64 the pass is also built for the CPU's `.V3` where it has one, whose 32-byte
// registers halve the mask code of a block. Each tier is a separate out-of-line instance (`pass_default_v3` and
// `pass_with_v3` in tier_amd64.odin), since a procedure has only its own target features.
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
pass_with :: #force_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, p: Pass_Options, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), $EMIT: bool) -> hook.Walk_Result {
	when ODIN_ARCH == .amd64 {
		if kernel.tier() == .V3 {
			return pass_with_v3(w, src, lo, p, regs, on, EMIT)
		}
	}
	return pass_with_floor(w, src, lo, p, regs, on, EMIT)
}

@(private, enable_target_feature = PASS_FLOOR_FEATURES)
pass_default_floor :: #force_no_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), $EMIT: bool) -> hook.Walk_Result {
	hs := regs^
	defer regs^ = hs
	return pass(w, src, lo, default_options(S), &hs, on, EMIT, false, PASS_FLOOR)
}

@(private, enable_target_feature = PASS_FLOOR_FEATURES)
pass_with_floor :: #force_no_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, p: Pass_Options, regs: ^hook.Regs, $on: proc "contextless" (h: ^H, s: hook.Regs, t: tape.Token) -> (hook.Regs, hook.Action), $EMIT: bool) -> hook.Walk_Result {
	hs := regs^
	defer regs^ = hs
	return pass(w, src, lo, p, &hs, on, EMIT, true, PASS_FLOOR)
}

// Returns the verdict on the text from `lo`, run without tokens, for a hooked walk whose hook passed over the text or
// the rest of it. `lo` is the first byte of a record or of the text. `width` above 0 is the width the records are
// checked against, and 0 has the first record set it. The tolerances this run took count as the walk's. It reads under
// the walk's own tolerances, which `p` of an instance that folds the defaults leaves out.
@(private, cold)
judge_from :: #force_no_inline proc "contextless" (w: ^Pass($S, $H, $LAX, $C), src: []u8, lo: u64, p: Pass_Options, width: int) -> hook.Walk_Result {
	v: Pass(S, hook.No_Hooks, false, hook.NO_HOOKS_CAPS + C & ONE_RECORD)
	q := p
	q.tolerate, q.limit = w.tolerate, max(u64)
	pass_start(&v, len(src), nil, q, 0)
	v.width, v.in_header = width, !p.no_header && width == 0
	regs: hook.Regs
	r := run(&v, src, lo, q, &regs, hook.no_hook)
	w.tolerated ||= v.tolerated
	return r
}

// Places the width fault of a validate's pass at its byte: the delimiter that opens the cell past the width in a wide
// record, or the line end's first byte in a narrow one. A width fault at or before a byte fault wins. Returns `r`
// unchanged for a walk with no fault. A faulting walk has its records rescanned with `scan_record`. A `width` above 0
// is the width a pass from a record's first byte checked records against, and 0 reads it from the first record.
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
			if s.wide_at >= 0 {
				if width_fault || u64(s.wide_at) < at {
					return fault_at(u64(s.wide_at), .Bad_Width, .Too_Many)
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

// Walks `src` as `S` for hook `h` from its registers `regs`, as the reads above do. Returns where its root value ends
// or the error, and whether the walk used a rule of `opts.tolerate`. A stop of the hook is no error. The hook follows
// the protocol `hook.check` checks and has no `.Walk`, since only the reads above read a record again.
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
