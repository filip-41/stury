// JSON's walk: one pass over a document, each grammar state a procedure that hands over to the next with
// `#must_tail` (states.odin). A state reads the first byte of the token it stands on and branches on it. Strings
// (strings.odin), numbers and literals (scalars.odin) and whitespace (whitespace.odin) are read by leaves.
package json

import "base:intrinsics"
import core "../core"
import kernel "../core/kernel"

// The deepest nesting a text may have. The open bracket past it is `Too_Deep` at that bracket.
MAX_DEPTH :: 1024

// The grammar a text follows, at compile time, so a build carries only the specs it names.
Spec :: enum u8 {
	Strict, // RFC 8259
}

// What a walk takes at run time. Strict JSON needs nothing.
Options :: struct {}

// JSON's rules within a `core.Fault_Kind`, in `core.Fault.detail`.
Detail :: enum u8 {
	None,
	Literal, // `Bad_Char`: a byte breaking `true`, `false` or `null`
}

// A text that holds one document: one leading BOM, the document, then only whitespace.
validate :: proc "contextless" (src: []u8, $S: Spec, opts := Options{}) -> Maybe(core.Fault) {
	p := raw_data(src)
	h: No_Hooks
	regs: core.Hook_Regs
	r := walk_document(src, core.text_start(src, 0), S, &h, &regs, no_hook)
	if r & 0xff != 0 {
		return fault_of(r)
	}
	end := p[len(src):]
	q := skip_ws(p[r >> 16:], end)
	if q != end {
		return core.Fault{u64(intrinsics.ptr_sub(q, p)), .Trailing, 0}
	}
	return nil
}

// One document read from `lo`, past one BOM at the text's first byte and the whitespace before the document: one past
// its last byte, or the fault. When a hook stops the walk, `hi` is one past the token it stopped on. `regs` goes to
// the first token and holds what the hook returned last.
walk :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	r := walk_document(src, core.text_start(src, lo), S, h, regs, on)
	return r >> 16, fault_of(r)
}

@(private)
No_Hooks :: struct {}

@(private)
no_hook :: #force_inline proc "contextless" (h: ^No_Hooks, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) {
	return s, .Next
}

// A walk's result in one word: a position in bits 16 and up, a detail in bits 8 to 15, and the fault's kind in
// bits 0 to 7, 0 for none. With no fault the position is where the document ended and the detail is STOPPED when a
// hook stopped the walk.
@(private)
fault_at :: #force_inline proc "contextless" (pos: u64, kind: core.Fault_Kind, detail: u8 = 0) -> u64 {
	return pos << 16 | u64(detail) << 8 | u64(kind)
}

@(private)
STOPPED :: 1

@(private)
fault_of :: #force_inline proc "contextless" (r: u64) -> Maybe(core.Fault) {
	if r & 0xff == 0 {
		return nil
	}
	return core.Fault{r >> 16, core.Fault_Kind(r & 0xff), u8(r >> 8)}
}

// What the states share beyond their registers. `stack[i]` has bit 0 set when the container at depth `i` is an
// object, and is written by the open that pushes past it (`MAX_DEPTH` slots), so the walk never reads a slot it did
// not write. `tier` picks the string reader built for this CPU.
@(private)
Walk :: struct($S: Spec, $H: typeid) {
	base:   [^]u8,
	hooks:  ^H,
	stack:  [^]u8,
	regs:   ^core.Hook_Regs,
	tier:   kernel.Tier,
	// The block of the string being read where its first backslash is, for `string_escaped` to read on from.
	resume: [^]u8,
}

// Set in the stack slot of the depth where a walk that passes over a skipped value ends: a close to that depth ends
// it. `]` with this bit shifted into it is no close bracket, so the close loop stops there as it reads the slot.
@(private)
PASS_END :: 4

@(private)
walk_document :: #force_inline proc "contextless" (src: []u8, lo: u64, $S: Spec, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	// `= ---` on an array leaves it unwritten (a struct would be zeroed), and every slot is written before it is read.
	stack: [MAX_DEPTH]u8 = ---
	w := Walk(S, H){raw_data(src), h, raw_data(stack[:]), regs, kernel.tier(), nil}
	end := w.base[len(src):]
	return st_value(skip_ws(w.base[lo:], end), end, 0, 0, &w, regs.a, regs.b, regs.c, on)
}

// The features every state is built with: one build of the states for each target, on x86-64 for its floor tier.
when ODIN_ARCH == .amd64 {
	@(private)
	STATE_TIER :: kernel.Tier.V2
} else {
	@(private)
	STATE_TIER :: kernel.Tier.Base
}

@(private)
STATE_FEATURES :: kernel.FEATURES[STATE_TIER]

// The walk without hooks from `p`, in state `st_open` or `st_value`, ending where the stack marks PASS_END or at
// the end of a root value: a call, since `#must_tail` cannot jump between the walk's instances.
@(private)
pass_over :: #force_inline proc "contextless" (w: ^Walk($S, $H), p, end: [^]u8, d, ind: u64, $open: bool) -> u64 {
	h: No_Hooks
	regs: core.Hook_Regs
	v := Walk(S, No_Hooks){w.base, &h, w.stack, &regs, w.tier, nil}
	when open {
		return st_open(p, end, d, ind, &v, 0, 0, 0, no_hook)
	} else {
		return st_value(p, end, d, ind, &v, 0, 0, 0, no_hook)
	}
}

// Hands the token from `p` to `q` to the hook, and answers what it asks. The readers refuse a token wider than
// `Token.n` holds before it gets here.
@(private)
emit :: #force_inline proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, kind: core.Kind, role: core.Role, p, q: [^]u8, spelling: u16) -> core.Action {
	a: core.Action
	hs^, a = on(w.hooks, hs^, core.Token{at(w, p), u32(intrinsics.ptr_sub(q, p)), kind, role, spelling})
	return a
}

@(private)
at :: #force_inline proc "contextless" (w: ^Walk($S, $H), p: [^]u8) -> u64 {
	return u64(intrinsics.ptr_sub(p, w.base))
}

@(private)
fault :: #force_inline proc "contextless" (w: ^Walk($S, $H), hs: core.Hook_Regs, p: [^]u8, kind: core.Fault_Kind, detail := Detail.None) -> u64 {
	w.regs^ = hs
	return fault_at(at(w, p), kind, u8(detail))
}

// The document ended at `p`.
@(private)
ended :: #force_inline proc "contextless" (w: ^Walk($S, $H), hs: core.Hook_Regs, p: [^]u8) -> u64 {
	w.regs^ = hs
	return fault_at(at(w, p), NO_FAULT)
}

// A hook stopped the walk on the token that ends at `p`.
@(private)
stopped :: #force_inline proc "contextless" (w: ^Walk($S, $H), hs: core.Hook_Regs, p: [^]u8) -> u64 {
	w.regs^ = hs
	return fault_at(at(w, p), NO_FAULT, STOPPED)
}
