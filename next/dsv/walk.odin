// The walk of a delimited text: one pass 64 bytes at a time (pass.odin). Each block is sorted into the masks of its
// delimiter, LF, CR and quote bytes, `prefix_xor` of the quote mask gives the bytes inside quoted fields, and every
// later test is a bit test on a mask: quote placement, a CR that no LF follows, the delimiters and LFs that are the
// text's rather than a cell's, and the delimiters between two LFs that count a record's cells for the width check.
// UTF-8 is judged a block at a time as well, and only for a block whose bytes are not all ASCII.
//
// A text read with a hook reads the same masks a second way, as positions (records.odin): the separators of a block
// in order, each ending a cell or a record, give every token's span. `validate` reads with `$EMIT` false, and its
// instance of the pass holds no position code and no key buffer at all. The bytes the masks cannot judge are read
// one at a time in text.odin, only where a block's masks say it needs them.
package dsv

import "base:runtime"
import core "../core"
import kernel "../core/kernel"

// The grammar a text follows. Each is its own instance of the pass, so one spec carries no code of the other.
Spec :: enum u8 {
	Csv, // RFC 4180: comma, and a quoted field whose `""` is a quote
	Tsv, // tab, a quote is text, and a backslash escapes `\t`, `\n`, `\r`, `\0` or `\\`
}

// What a walk takes at run time. The zero value has a header.
Options :: struct {
	no_header: bool, // the first record is data, not column names
	// The rules a text may break, each read one fixed way. None by default.
	tolerate:  bit_set[Tolerance; u8],
}

// A rule a caller lets a text break. The walk stops faulting there and keeps the cells' bytes as they are: the value
// a cell decodes to is where the reading shows.
Tolerance :: enum u8 {
	// Ill-formed UTF-8 in a cell: each maximal subpart of an ill-formed sequence reads as U+FFFD.
	Invalid_Utf8,
	// A record with fewer cells than the first: its missing columns are absent. With no header a record may have any
	// number of cells, and with one a cell past the header's last is still a fault.
	Ragged,
	// A quote inside an unquoted cell (CSV) is a byte of the cell, and the quotes after it pair up without it.
	Bare_Quote,
}

// The rules of a delimited text within a `core.Fault_Kind`, in `core.Fault.detail`.
Detail :: enum u8 {
	None,
	Field_Count, // `Bad_Structure`: a record with more or fewer cells than the first, at its first byte
}

// A delimited text's rules, per value of `Detail`, which every fault the walk returns points to.
@(rodata)
RULES := core.Rules{"dsv", {{}, {"field_count", "Record has the wrong number of fields"}}}

// One text read from `lo`, past one BOM at the text's first byte, with a hook: one past its last byte, or the fault.
// When a hook stops the walk, `hi` is one past the token it stopped on. A `lo` past the text's end reads an empty
// text. The tokens are an `Array` for the text, then per record a `Map` (an `Array` with no header) holding, per
// cell, its column's header cell as a `Plain` of role `Key` and the cell as a `Plain` value, and an `End` on its line
// end (LF or CR LF, `n` 0 where the text ends without one). The text's `End` is at its end, `n` 0. A cell's span
// keeps its quotes and leaves out the CR of a CRLF. The header makes no tokens of its own, and a line that is empty
// or holds only a CR is no record.
walk :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	// One allocation per walk, of one 16-byte token per header cell, so that no cell of a record looks its column's
	// header cell up again. It is scratch freed before the walk returns, so it comes from the default heap, which
	// keeps the walk callable from a hook. When it cannot be had, the walk is `No_Memory` before it reads a byte.
	// `validate` allocates nothing.
	context = runtime.default_context()
	from := min(lo, u64(len(src)))
	keys: []core.Token
	if !opts.no_header {
		err: runtime.Allocator_Error
		keys, err = make([]core.Token, header_cells(src, int(core.text_start(src, from)), S))
		if err != nil {
			return 0, fault_of(fault_at(0, .No_Memory))
		}
	}
	defer delete(keys)
	r := run(src, from, S, opts, h, regs, on, true, keys)
	return r >> 16, fault_of(r)
}

// Whether `src`, after one leading BOM, is a text of spec `S`: the walk's verdict, with no hook. Whether the first
// record is a header changes the verdict only under `.Ragged`.
validate :: proc "contextless" (src: []u8, $S: Spec, opts := Options{}) -> Maybe(core.Fault) {
	return fault_of(judge(src, 0, S, opts))
}

// The walk's verdict on the text from `lo`, with no hook. Only a text longer than `Token.n` holds can hold a cell
// that is, and only the hooked lane keeps the spans of cells, so such a text is read by the hooked lane with a hook
// that asks for nothing and no keys.
@(private)
judge :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options) -> u64 {
	h: No_Hooks
	regs: core.Hook_Regs
	if u64(len(src)) - lo > u64(max(u32)) {
		return run(src, lo, S, opts, &h, &regs, no_hook, true, nil)
	}
	return run(src, lo, S, opts, &h, &regs, no_hook, false, nil)
}

// A hook that asks for nothing: what `validate` passes for its tokens, which folds away to no code.
@(private)
No_Hooks :: struct {}

@(private)
no_hook :: #force_inline proc "contextless" (h: ^No_Hooks, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return s, .Next
}

// The pass built for this CPU's vector width, unless `-define:WALK_TIER=<n>` picks another for a test build.
@(private)
run :: #force_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, keys: []core.Token) -> u64 {
	when ODIN_ARCH == .amd64 {
		switch kernel.tier() {
		case .V4:
			return pass_v4(src, lo, S, opts, h, regs, on, EMIT, keys)
		case .V3:
			return pass_v3(src, lo, S, opts, h, regs, on, EMIT, keys)
		case .V2:
			return pass_v2(src, lo, S, opts, h, regs, on, EMIT, keys)
		}
		unreachable()
	} else {
		return pass_base(src, lo, S, opts, h, regs, on, EMIT, keys)
	}
}

// The pass once per tier, each with its tier's features and its own copy of the loop, as kernel.md asks: a hot loop
// that calls a kernel generic over `$T` is built once per tier, so that a v4 build holds v4 compares and a v2 build
// holds SSE ones. `#force_no_inline` keeps each one a procedure of its own.
when ODIN_ARCH == .amd64 {
	@(private, enable_target_feature = kernel.FEATURES[.V2])
	pass_v2 :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, keys: []core.Token) -> u64 {
		return pass(.V2, S, EMIT, src, lo, opts, h, regs, on, keys)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V3])
	pass_v3 :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, keys: []core.Token) -> u64 {
		return pass(.V3, S, EMIT, src, lo, opts, h, regs, on, keys)
	}
	@(private, enable_target_feature = kernel.FEATURES[.V4])
	pass_v4 :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, keys: []core.Token) -> u64 {
		return pass(.V4, S, EMIT, src, lo, opts, h, regs, on, keys)
	}
} else {
	@(private)
	pass_base :: #force_no_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), $EMIT: bool, keys: []core.Token) -> u64 {
		return pass(.Base, S, EMIT, src, lo, opts, h, regs, on, keys)
	}
}

// A pass's result in one word: a position in bits 16 and up, a detail in bits 8 to 15, and the fault's kind in
// bits 0 to 7, 0 for none. With no fault the position is where the walk ended, and the detail is STOPPED when a
// hook stopped it.
@(private)
fault_at :: #force_inline proc "contextless" (pos: int, kind: core.Fault_Kind, detail := Detail.None) -> u64 {
	return u64(pos) << 16 | u64(detail) << 8 | u64(kind)
}

// Set in the result's detail field when a hook asked the walk to stop: no fault, and `hi` is one past the token it
// stopped on.
@(private)
STOPPED :: Detail(1)

@(private)
fault_of :: #force_inline proc "contextless" (r: u64) -> Maybe(core.Fault) {
	if r & 0xff == 0 {
		return nil
	}
	return core.Fault{at = r >> 16, rules = &RULES, kind = core.Fault_Kind(r & 0xff), detail = u8(r >> 8)}
}

// Hands one token to the hook and takes its registers back. The token is built here, from the words the call sites
// hold, so that no site has to give a whole `Token` an address or a second copy.
@(private)
emit :: #force_inline proc "contextless" (h: ^$H, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, lo: u64, n: u32, kind: core.Kind, role: core.Role, spelling: u16) -> core.Action {
	a: core.Action
	hs^, a = on(h, hs^, core.Token{lo, n, kind, role, spelling})
	return a
}

// A hook stopped the walk on the token from `lo`, `n` bytes long.
@(private)
stopped :: #force_inline proc "contextless" (lo: u64, n: u32) -> u64 {
	return fault_at(int(lo) + int(n), .None, STOPPED)
}
