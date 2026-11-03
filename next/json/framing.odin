// JSON's record services (`core/records`). `.Lines` (NDJSON) and `.Seq` (RFC 7464) frame a record by a scan for the
// byte that ends it, and a record is read in place in the whole text, not as a slice cut from it.
package json

import "base:intrinsics"
import "base:runtime"
import core "../core"
import kernel "../core/kernel"
import typed "../core/typed"
import records "../core/records"

@(private, rodata)
RECORDS := records.Services {
	next  = next_record,
	judge = judge_record,
	read  = read_record,
	build = build_record,
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
	fault, cold := walk_line(it.src, rec.at, rec.at + u64(len(rec.text)), S, opts, &h, &regs, core.no_hook)
	if cold {
		return walk_text(it.src[:rec.at + u64(len(rec.text))], rec.at, S, opts, &h, &regs, core.no_hook)
	}
	return fault
}

@(private)
read_record :: proc(it: ^records.Reader, target: rawptr, T: typeid, plan: ^typed.Plan, read: typed.Read_Options, allocator: runtime.Allocator, err: ^core.Typed_Error) -> bool {
	switch Spec(it.as.read.spec) {
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
	rec, ok := next_record(it)
	if !ok {
		return false
	}
	lo := rec.at
	cut := lo + u64(len(rec.text))
	opts := options_of(it.as.read)
	c := read.collect
	kept: typed.Collected
	if c != nil {
		kept = c^
	}
	if !read_value(it.src, lo, cut, S, target, T, plan, read, opts, it.frames, allocator, err, true) {
		return true
	}
	if c != nil {
		resize(&c.errors, len(kept.errors))
		c.truncated = kept.truncated
	}
	scratch, failed := runtime.mem_alloc(type_info_of(T).size, type_info_of(T).align, context.temp_allocator)
	if failed != nil {
		err^ = {kind = .Out_Of_Memory}
		return true
	}
	err^ = {}
	read_value(it.src, lo, cut, S, raw_data(scratch), T, plan, read, opts, it.frames, context.temp_allocator, err, false)
	return true
}

// Builds the document of `rec`'s text. Its offsets in a fault count from the input's first byte.
@(private)
build_record :: proc(it: ^records.Reader, rec: records.Record, allocator: runtime.Allocator) -> (doc: core.Document, err: core.Document_Error) {
	spec := Spec(it.as.read.spec)
	// A BOM is the input's, and passed over only at its first byte.
	if rec.at > 0 && spec != .Json5 && len(rec.text) >= 3 && rec.text[0] == 0xef && rec.text[1] == 0xbb && rec.text[2] == 0xbf {
		return {}, {kind = .Walk, at = rec.at, inner = {at = rec.at, rules = &RULES, kind = .Bad_Char}}
	}
	opts := options_of(it.as.read)
	switch spec {
	case .Json:  doc, err = build(rec.text, .Json, opts, false, allocator)
	case .Jsonc: doc, err = build(rec.text, .Jsonc, opts, false, allocator)
	case .Json5: doc, err = build(rec.text, .Json5, opts, false, allocator)
	}
	if err.kind != .None {
		err.at += rec.at
		err.inner.at += rec.at
	}
	return
}

@(private)
FAULT_REACH :: 16

// The walk options a `core.Read_As` holds.
@(private)
options_of :: #force_inline proc "contextless" (read: core.Read_As) -> Options {
	return {max_depth = read.max_depth, tolerate = transmute(bit_set[Tolerance; u8])read.opts[0]}
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
