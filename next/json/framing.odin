// JSON's record services (`core/records`). `.Lines` (NDJSON) and `.Seq` (RFC 7464) frame a record by a scan for the
// byte that ends it, and a record is read in place in the whole text, not as a slice cut from it.
package json

import "base:intrinsics"
import core "../core"
import kernel "../core/kernel"
import records "../core/records"

@(private, rodata)
RECORDS := records.Services {
	next  = next_record,
	judge = judge_record,
}

@(private)
next_record :: proc(it: ^records.Reader) -> (records.Record, bool) {
	#partial switch it.framing {
	case .Lines, .Seq:
		return frame_line(it)
	}
	it.fault = core.Fault{kind = .Bad_Option}
	return {}, false
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
		q := u64(intrinsics.ptr_sub(skip_ws(p[it.pos:], end), p))
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
	p := raw_data(src)
	n := u64(len(src))
	i := lo
	for i + 64 <= n {
		if m := kernel.pack(kernel.eq(kernel.load(p[i:]), c)); m != 0 {
			return i + u64(intrinsics.count_trailing_zeros(m))
		}
		i += 64
	}
	for i < n && p[i] != c {
		i += 1
	}
	return i
}

@(private)
judge_record :: proc(it: ^records.Reader, rec: records.Record) -> Maybe(core.Fault) {
	switch Spec(it.as.read.spec) {
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
	opts := options_of(it.as.read)
	fault, cold := walk_line(it.src, rec, S, opts, &h, &regs, core.no_hook)
	if cold {
		return walk_text(it.src[:rec.at + u64(len(rec.text))], rec.at, S, opts, &h, &regs, core.no_hook)
	}
	return fault
}

@(private)
FAULT_REACH :: 16

// The walk options a `core.Read_As` holds.
@(private)
options_of :: #force_inline proc "contextless" (read: core.Read_As) -> Options {
	return {max_depth = read.max_depth, tolerate = transmute(bit_set[Tolerance; u8])read.opts[0]}
}

// Walks record `rec` of a `.Lines` or `.Seq` text in place in `src`. Returns the fault that a walk of the record's
// text alone gives, as `walk_text` on `src` cut at the record's end, or `cold` when only that walk can tell: the walk
// in place ran past the record's end, by a value spread over lines, or faulted near it. A fault depends on no byte
// more than `FAULT_REACH` past the byte it names, as a lone surrogate's escape is judged by the escape after it, so one
// further from the end is the same in both walks. The walk reads at most 64 bytes past the record, so a value spread
// over many lines costs no more than one.
@(private)
walk_line :: #force_inline proc(src: []u8, rec: records.Record, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (fault: Maybe(core.Fault), cold: bool) {
	cut := rec.at + u64(len(rec.text))
	hi, f, _ := walk_from(src[:min(u64(len(src)), cut + 64)], raw_data(src)[rec.at:], S, opts, h, regs, on)
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
