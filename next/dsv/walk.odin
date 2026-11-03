// `kernel` is used only in a generic procedure, which the unused-import check does not read.
#+vet !unused-imports
// The walk of a delimited text, in passes of 64-byte blocks (pass.odin). A block is reduced to masks of its delimiter,
// LF, CR and quote bytes, `prefix_xor` of the quote mask marks the bytes inside quoted fields, and every later test is
// a bit test on a mask, for quote placement, a CR that no LF follows, the delimiters and LFs that are the text's rather
// than a cell's, and the delimiters between two LFs that count a record's cells for the width check. UTF-8 is judged a
// block at a time, and only for a block that is not all ASCII.
//
// A hooked read turns the same masks into positions (records.odin). The block's separators in order, each ending a cell
// or a record, give every token's span. `validate` compiles the pass with `$EMIT` false, which leaves out the position
// code and the key buffer. The bytes the masks cannot judge are read one at a time in text.odin, on the blocks whose
// masks say they are needed.
package dsv

import "base:runtime"
import core "../core"
import kernel "../core/kernel"
import build "../core/build"

// The grammar a text follows, chosen at compile time. Each spec instantiates its own pass, so a CSV build holds no TSV
// code.
Spec :: enum u8 {
	Csv, // RFC 4180, a field whose first byte is a quote is quoted, and `""` inside it reads as `"`
	Tsv, // a quote is text, and a backslash escapes `t`, `n`, `r`, `0` or `\\`
	Plain, // no quotes and no escapes, a quote is text, and a cell cannot hold the delimiter, CR or LF
}

// Run-time options for a walk. The zero value reads a header, uses the spec's delimiter and sets no comment byte.
Options :: struct {
	no_header: bool, // the first record is data, not column names
	// The byte between cells, 0 for the spec's own, which is `,` for CSV and Plain and a tab for TSV. A walk whose
	// spec cannot read the byte returns `.Bad_Option` before reading the text.
	delimiter: byte,
	// A line whose first byte is this is no record, 0 for none. At any other byte, or inside a quoted field, it is
	// cell text. A byte the spec cannot read is refused as `.Bad_Option`, like the delimiter.
	comment:   byte,
	// The rules a text may break. Empty by default.
	tolerate:  bit_set[Tolerance; u8],
	crlf:      bool, // a write ends each record with CR LF, where a read takes either
	// A document's unquoted cell that is empty, `true`, `false` or exactly a JSON number resolves as Null, True, False or
	// Number, as `core.resolve` and a JSON write read it. Off, every value cell is a String.
	infer:     bool,
}

// A rule a caller lets a text break. The walk stops faulting on it. The tolerance shows in the value a cell decodes to
// or in the record width check.
Tolerance :: enum u8 {
	// Ill-formed UTF-8 in a cell is not a fault. Each maximal subpart of an ill-formed sequence decodes as U+FFFD.
	Invalid_Utf8,
	// A record of any width is not a fault. A narrower record's missing columns are absent. With a header, a wider
	// record's cells past the header's last are columns named by their 1-based position, `"3"` for the third.
	Ragged,
	// A quote inside an unquoted cell (CSV) is a cell byte, and the block's quotes pair up without it.
	Bare_Quote,
}

// The `core.Fault.detail` values a delimited text's faults use.
Detail :: enum u8 {
	None,
	Field_Count, // `Bad_Char`, at the delimiter past the width of a wide record or the line end of a narrow one
	Bare_Quote, // `Bad_Char`, a quote inside an unquoted CSV cell
	Bad_Utf8, // `Bad_Char`, at the lead byte of an ill-formed sequence
	Lone_Cr, // `Bad_Char`, a CR with no LF after it
	After_Quote, // `Bad_Char`, a byte after a closing quote that is not a quote, the delimiter or a line end
	Open_Quote, // `Truncated`, at the opening quote of a quoted cell the text never closes
	Cut_Utf8, // `Truncated`, at `len(src)`, where the text ends inside a UTF-8 sequence
}

// A delimited text's rules, indexed by `Detail`. Every fault the walk returns points to this table.
@(rodata)
RULES := core.Rules{"dsv", {{}, {"field_count", "Record has the wrong number of fields"}, {"bare_quote", "Quote inside an unquoted field"}, {"bad_utf8", "Invalid UTF-8"}, {"lone_cr", "Carriage return not before a line feed"}, {"after_quote", "Character after a closing quote"}, {"open_quote", "Unfinished quoted field"}, {"cut_utf8", "Unfinished UTF-8 sequence"}}}

// The delimiter a walk of `S` reads. `opts.delimiter` 0 selects the spec's own, `,` for CSV and Plain and a tab for
// TSV. The pass reads it once into a register and compares each block against it.
@(private)
delimiter_of :: #force_inline proc "contextless" ($S: Spec, opts: Options) -> byte {
	if opts.delimiter != 0 {
		return opts.delimiter
	}
	when S == .Tsv {
		return '\t'
	} else {
		return ','
	}
}

// Whether `S` can read the delimiter and comment byte in `opts`. A delimiter is refused when it is CR, LF, non-ASCII
// or, under CSV, a quote, and under TSV also a backslash or one of `t`, `n`, `r`, `0`. A comment byte is refused when
// it is CR, LF, the delimiter, non-ASCII or, under CSV, a quote, and under TSV also a backslash.
@(private)
options_ok :: #force_inline proc "contextless" ($S: Spec, opts: Options) -> bool {
	delim := delimiter_of(S, opts)
	if delim == '\r' || delim == '\n' || delim >= 0x80 {
		return false
	}
	when S == .Csv {
		if delim == '"' {
			return false
		}
	}
	when S == .Tsv {
		if delim == '\\' || delim == 't' || delim == 'n' || delim == 'r' || delim == '0' {
			return false
		}
	}
	if c := opts.comment; c != 0 {
		if c == '\r' || c == '\n' || c == delim || c >= 0x80 {
			return false
		}
		when S == .Csv {
			if c == '"' {
				return false
			}
		}
		when S == .Tsv {
			if c == '\\' {
				return false
			}
		}
	}
	return true
}

// The `.Bad_Option` fault at byte 0 for options `S` cannot read, or nil.
@(private)
option_fault :: #force_inline proc "contextless" ($S: Spec, opts: Options) -> Maybe(core.Fault) {
	if options_ok(S, opts) {
		return nil
	}
	return core.Fault{at = 0, rules = &RULES, kind = .Bad_Option}
}

// Reads a text of spec `S` from `lo`, past one BOM at its first byte, with hook `on`. Returns `hi`, one past the last
// byte read, or the fault. A BOM at a later byte is a cell byte. A `lo` past `len(src)` reads an empty text. When the
// hook stops the walk, `hi` is one past the token it stopped on and the text past it is unread, so `hi` is no document
// boundary.
// The tokens are an `Array` for the text, then for each record a `Map` (an `Array` when `opts.no_header`), each cell as
// its column's header cell (`Plain`, role `Key`) and the cell itself (`Plain`, role `Value`), and an `End` over the
// record's line end, 1 byte for LF and 2 for CR LF. The text's `End` is at its end, with `n` 0. A cell's span keeps its
// quotes and leaves out the CR of a CR LF. The header makes no tokens, and an empty line or a line holding only a CR is
// no record. `regs` nil starts from zero registers and keeps none. `opts` is `Options{}` by default.
walk :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	return walk_keys(src, lo, S, opts, h, regs, on, nil)
}

// The walk behind `build`: a caller that holds a buffer of one token per header cell passes it as `keys`, and the walk
// writes the header's cells there and allocates none. With nil, the walk allocates the buffer.
@(private)
walk_keys :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), keys: []core.Token) -> (hi: u64, fault: Maybe(core.Fault)) {
	if f, bad := option_fault(S, opts).?; bad {
		return 0, f
	}
	// The nil test runs once per walk, not per token.
	zero: core.Hook_Regs
	reg := regs
	if reg == nil {
		reg = &zero
	}
	// With no `keys` buffer and a header, allocates one 16-byte token per header cell for the walk to write the
	// header's cells into. Data cells read their column's key from it by index. The buffer is scratch freed before
	// the walk returns, so it comes from the default heap, which keeps the walk callable from a hook. If the
	// allocation fails the walk returns `No_Memory` before reading a byte. `validate` allocates nothing.
	from := min(lo, u64(len(src)))
	key_buf := keys
	owned: []core.Token
	if key_buf == nil && !opts.no_header {
		context = runtime.default_context()
		err: runtime.Allocator_Error
		key_buf, err = make([]core.Token, header_cells(src, int(core.text_start(src, from)), S, opts))
		if err != nil {
			return 0, core.fault_of(core.fault_at(0, .No_Memory), &RULES)
		}
		owned = key_buf
	}
	r := run(src, from, S, opts, h, reg, on, true, key_buf)
	if owned != nil {
		context = runtime.default_context()
		delete(owned)
	}
	return r >> 16, core.fault_of(r, &RULES)
}

// The walk's verdict on `src` for spec `S`, with no hook and after one leading BOM. Whether the first record is a
// header changes the verdict only under `.Ragged`. It is `core.validate` with `as(spec, opts)`.
validate :: #force_inline proc "contextless" (src: []u8, spec: Spec, opts := Options{}) -> Maybe(core.Fault) {
	return core.validate(src, as(spec, opts))
}

// The handle's validate: the walk compiled for the handle's spec.
@(private)
validate_as :: proc "contextless" (src: []u8, as: core.As) -> Maybe(core.Fault) {
	return validate_from(src, as, 0, 0)
}

// The handle's verdict on the text from `lo`, a record's start, checking records against `width` when it is above 0.
@(private)
validate_from :: proc "contextless" (src: []u8, as: core.As, lo: u64, width: int) -> Maybe(core.Fault) {
	switch Spec(as.spec) {
	case .Csv:   return validate_spec(src, .Csv, options_of(as), lo, width)
	case .Tsv:   return validate_spec(src, .Tsv, options_of(as), lo, width)
	case .Plain: return validate_spec(src, .Plain, options_of(as), lo, width)
	}
	return core.Fault{rules = &RULES, kind = .Bad_Option}
}

@(private)
validate_spec :: proc "contextless" (src: []u8, $S: Spec, opts: Options, lo: u64 = 0, width := 0) -> Maybe(core.Fault) {
	if f, bad := option_fault(S, opts).?; bad {
		return f
	}
	return core.fault_of(judge(src, lo, S, opts, width), &RULES)
}

// The walk's verdict on the text from `lo`, with no hook, checking records against `width` when it is above 0. A cell can exceed `Token.n` only in a text longer than
// `max(u32)` bytes, and only the hooked lane checks cell width, so such a text runs with `$EMIT` true and
// `core.no_hook`. A shorter text runs with `$EMIT` false. `field_count_fault` then places a width fault.
@(private)
judge :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, width := 0) -> u64 {
	h: core.No_Hooks
	regs: core.Hook_Regs
	r: u64
	if u64(len(src)) - lo > u64(max(u32)) {
		r = run(src, lo, S, opts, &h, &regs, core.no_hook, true, nil, width)
	} else {
		r = run(src, lo, S, opts, &h, &regs, core.no_hook, false, nil, width)
	}
	return field_count_fault(src, lo, S, opts, r, width)
}

// The position of a width fault is the delimiter that opens the cell past the width in a wide record, or the line end's
// first byte in a narrow one. A width fault at or before a byte fault wins. A walk with no fault returns `r` unchanged,
// and a faulting one rescans the records with `scan_record`. A `width` above 0 is the width a walk from a row start
// checked rows against, and 0 reads it from the first record. `.Ragged` has no width fault to place.
@(private, cold)
field_count_fault :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, r: u64, width := 0) -> u64 {
	kind := core.Fault_Kind(r & 0xff)
	if kind == .None || .Ragged in opts.tolerate {
		return r
	}
	at, detail := r >> 16, u8(r >> 8)
	end := len(src)
	pos := record_start(src, int(core.text_start(src, min(lo, u64(end)))), opts.comment)
	if pos >= end {
		return r
	}
	delim := delimiter_of(S, opts)
	width := width
	if width == 0 {
		width = header_cells(src, pos, S, opts) if !opts.no_header else scan_record(src, pos, 0, S, delim).cells
	}
	for pos < end {
		if at < u64(pos) {
			return r
		}
		s := scan_record(src, pos, width, S, delim)
		if at <= u64(s.line_end) {
			if s.fault_at >= 0 {
				if detail == u8(Detail.Field_Count) || u64(s.fault_at) < at {
					return core.fault_at(u64(s.fault_at), .Bad_Char, u8(Detail.Field_Count))
				}
			} else if detail == u8(Detail.Field_Count) && s.cells < width {
				return core.fault_at(u64(s.line_end_lo), .Bad_Char, u8(Detail.Field_Count))
			}
			return r
		}
		pos = record_start(src, s.line_end + 1, opts.comment)
	}
	return r
}

// Runs the pass for the CPU's vector tier (`kernel.tier()`), or for the tier `-define:WALK_TIER=<n>` forces in a test
// build. A text with no comment byte runs the pass instance with `$COMMENTS` false, which holds no comment code.
@(private)
run :: #force_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, keys: []core.Token, width := 0) -> u64 {
	// A document build or a record batch with the default options runs its own pass instance with literal options,
	// which fold the option tests and leave the instance for other options out of its registers.
	when H == build.Builder || H == Batch {
		if opts == {} {
			return run_tier(src, lo, S, opts, h, regs, on, EMIT, false, true, keys, width)
		}
	}
	if opts.comment != 0 {
		return run_tier(src, lo, S, opts, h, regs, on, EMIT, true, false, keys, width)
	}
	return run_tier(src, lo, S, opts, h, regs, on, EMIT, false, false, keys, width)
}

@(private)
run_tier :: #force_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, $COMMENTS: bool, $DEFAULT: bool, keys: []core.Token, width: int) -> u64 {
	when ODIN_ARCH == .amd64 {
		switch kernel.tier() {
		case .V4:
			return pass_v4(src, lo, S, opts, h, regs, on, EMIT, COMMENTS, DEFAULT, keys, width)
		case .V3:
			return pass_v3(src, lo, S, opts, h, regs, on, EMIT, COMMENTS, DEFAULT, keys, width)
		case .V2:
			return pass_v2(src, lo, S, opts, h, regs, on, EMIT, COMMENTS, DEFAULT, keys, width)
		}
		unreachable()
	} else {
		return pass_base(src, lo, S, opts, h, regs, on, EMIT, COMMENTS, DEFAULT, keys, width)
	}
}

// A pass procedure per vector tier, each with its tier's target features and its own copy of the loop, as kernel.md
// asks. A loop that calls a kernel generic over `$T` is instantiated per tier, so a v4 build holds v4 compares and a v2
// build holds SSE ones. `#force_no_inline` keeps each a separate procedure.
when ODIN_ARCH == .amd64 {
	@(private, enable_target_feature = kernel.FEATURES[.V2])
	pass_v2 :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, $COMMENTS: bool, $DEFAULT: bool, keys: []core.Token, width: int) -> u64 {
		return pass(.V2, S, EMIT, COMMENTS, src, lo, Options{} when DEFAULT else opts, h, regs, on, keys, width)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V3])
	pass_v3 :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, $COMMENTS: bool, $DEFAULT: bool, keys: []core.Token, width: int) -> u64 {
		return pass(.V3, S, EMIT, COMMENTS, src, lo, Options{} when DEFAULT else opts, h, regs, on, keys, width)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V4])
	pass_v4 :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, $COMMENTS: bool, $DEFAULT: bool, keys: []core.Token, width: int) -> u64 {
		return pass(.V4, S, EMIT, COMMENTS, src, lo, Options{} when DEFAULT else opts, h, regs, on, keys, width)
	}
} else {
	@(private)
	pass_base :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, $COMMENTS: bool, $DEFAULT: bool, keys: []core.Token, width: int) -> u64 {
		return pass(.Base, S, EMIT, COMMENTS, src, lo, Options{} when DEFAULT else opts, h, regs, on, keys, width)
	}
}

// Passes a token to the hook and stores the returned registers in `hs`. The token is built here from the call's words,
// so a call site gives no `Token` an address or a second copy.
@(private)
emit :: #force_inline proc "contextless" (h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, lo: u64, n: u32, kind: core.Kind, role: core.Role, spelling: u16) -> core.Action {
	a: core.Action
	hs^, a = on(h, hs^, core.Token{lo, n, kind, role, spelling})
	return a
}

// The walk's result when the hook stopped on the token at `lo` of `n` bytes. Its position is `lo + n`, its kind 0, and
// its detail `STOPPED`.
@(private)
stopped :: #force_inline proc "contextless" (lo: u64, n: u32) -> u64 {
	return core.fault_at(lo + u64(n), .None, core.STOPPED)
}
