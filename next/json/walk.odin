// JSON's walk: one pass over a document, each grammar state a procedure that hands over to the next with
// `#must_tail` (states.odin). A state reads the first byte of the token it stands on and branches on it. Strings
// (strings.odin), numbers and literals (scalars.odin) and whitespace (whitespace.odin) are read by leaves.
package json

import "base:intrinsics"
import "base:runtime"
import core "../core"
import kernel "../core/kernel"

// The deepest nesting a text may have unless `Options.max_depth` says otherwise. The open bracket past the limit is
// `Too_Deep` at that bracket.
MAX_DEPTH :: 1024

// The grammar a text follows, at compile time, so a build carries only the specs it names. Each is strict to itself.
Spec :: enum u8 {
	Json, // RFC 8259
	Jsonc, // RFC 8259 with `//` and `/* */` comments wherever whitespace may stand, and a comma before a close bracket
	Json5, // JSON5 1.0.0
}

// What a spec adds to RFC 8259, which the states test with `when`, so a spec's walk carries only its own rules.
@(private)
Feature :: enum u8 {
	Comments,
	Trailing_Commas,
	Es5, // JSON5's ECMAScript forms: its numbers, strings, unquoted keys and whitespace (json5.odin)
}

// Every spec with comments also takes trailing commas: a close bracket after a run of comments is read with no look
// back at whether an open bracket or a comma came before the run.
@(private)
FEATURES :: [Spec]bit_set[Feature] {
	.Json  = {},
	.Jsonc = {.Comments, .Trailing_Commas},
	.Json5 = {.Comments, .Trailing_Commas, .Es5},
}

// What a walk takes at run time. The zero value is the default.
Options :: struct {
	// The deepest nesting a text may have, 0 for `MAX_DEPTH`. Up to `MAX_DEPTH` the walk keeps its depth stack on its
	// own stack, and past it takes one byte per level from the default heap.
	max_depth: u32,
	// The rules a text may break, each read one fixed way. None by default.
	tolerate:  bit_set[Tolerance; u8],
}

// A rule a caller lets a text break. The walk stops faulting there and keeps the token's bytes as they are: the value
// a string decodes to is where the reading shows.
Tolerance :: enum u8 {
	// Ill-formed UTF-8 in a string: each maximal subpart of an ill-formed sequence reads as U+FFFD.
	Invalid_Utf8,
	// A `\u` escape of a surrogate half that no other half pairs with reads as U+FFFD.
	Lone_Surrogate,
}

// JSON's rules within a `core.Fault_Kind`, in `core.Fault.detail`.
Detail :: enum u8 {
	None,
	Literal, // `Bad_Char`: a byte breaking `true`, `false` or `null`
	Identifier, // `Bad_Char`: a byte that starts no key, quoted or not, where an object's key must start
	Colon, // `Bad_Char`: a byte where a member's colon must stand
}

// JSON's rules, per value of `Detail`, which every fault the walk returns points to.
@(rodata)
RULES := core.Rules{"json", {{}, {"literal", "Invalid literal"}, {"identifier", "Invalid unquoted key"}, {"colon", "Missing colon after key"}}}

// A text that holds one document: one leading BOM, the document, then only whitespace, and comments in a spec that
// has them.
validate :: proc "contextless" (src: []u8, $S: Spec, opts := Options{}) -> Maybe(core.Fault) {
	p := raw_data(src)
	end := p[len(src):]
	h: core.No_Hooks
	regs: core.Hook_Regs
	r := walk_document(src, skip_ws(p[core.text_start(src, 0):], end), S, opts, &h, &regs, core.no_hook)
	if r & 0xff != 0 {
		return core.fault_of(r, &RULES)
	}
	q := skip_ws(p[r >> 16:], end)
	when .Comments in FEATURES[S] {
		kind: core.Fault_Kind
		q, _, kind = comment_run(q, end, false, S)
		if kind != .None {
			return core.fault_of(core.fault_at(u64(intrinsics.ptr_sub(q, p)), kind), &RULES)
		}
	}
	if q != end {
		return core.fault_of(core.fault_at(u64(intrinsics.ptr_sub(q, p)), .Trailing), &RULES)
	}
	return nil
}

// One document read from `lo`: one past its last byte, or the fault. One BOM at the text's first byte, whitespace, the
// record separator 0x1E, and comments with no document after them before the text's end or a 0x1E are passed over
// before the document, so a stream of documents, whether NDJSON, RFC 7464 or jq's input, is a loop of walks each from
// where the last one ended. A text with nothing but those left, and a `lo` past the text's end, holds no document: the
// walk makes no token and returns the text's end with no fault. When a
// hook stops the walk, `hi` is one past the token it stopped on. `regs` goes to the first token and holds what the hook
// returned last.
walk :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	p := raw_data(src)
	end := p[len(src):]
	q := skip_ws(p[core.text_start(src, min(lo, u64(len(src)))):], end)
	for q < end {
		if q[0] == 0x1e {
			q = skip_ws(q[1:], end)
			continue
		}
		// Comments before the text's end or a 0x1E are the foot of the document before them, or of none.
		when .Comments in FEATURES[S] {
			if gap(q, end, S) {
				if r, _, kind := comment_run(q, end, false, S); kind == .None && (r == end || r[0] == 0x1e) {
					q = r
					continue
				}
			}
		}
		break
	}
	if q == end {
		return u64(len(src)), nil
	}
	r := walk_document(src, q, S, opts, h, regs, on)
	return r >> 16, core.fault_of(r, &RULES)
}

// What the states share beyond their registers. `stack[i]` has bit 0 set when the container at depth `i` is an
// object, and is written by the open that pushes past it (`depth` slots), so the walk never reads a slot it did not
// write. `tier` picks the string reader built for this CPU.
@(private)
Walk :: struct($S: Spec, $H: typeid) {
	base:     [^]u8,
	hooks:    ^H,
	stack:    [^]u8,
	regs:     ^core.Hook_Regs,
	depth:    u64,
	tier:     kernel.Tier,
	// Whether the state that handed a comment run over read the comma before it. In the padding after `tier`, so a
	// spec without comments builds the same walk.
	crossed:  bool,
	// `Options.tolerate`, read only where a string faults.
	tolerate: bit_set[Tolerance; u8],
	// Where the state handed over picks up: for `string_escaped`, the block of the string being read where its first
	// backslash is, and for `st_comments_after`, the run's first comment, which the state before it read up to.
	resume:   [^]u8,
}

// Set in the stack slot of the depth where a walk that passes over a skipped value ends: a close to that depth ends
// it. `]` with this bit shifted into it is no close bracket, so the close loop stops there as it reads the slot.
@(private)
PASS_END :: 4

// The document from `p`, where its first byte must stand.
@(private)
walk_document :: #force_inline proc "contextless" (src: []u8, p: [^]u8, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	if opts.max_depth > MAX_DEPTH {
		return walk_deep(src, p, S, u64(opts.max_depth), opts.tolerate, h, regs, on)
	}
	// `= ---` on an array leaves it unwritten (a struct would be zeroed), and every slot is written before it is read.
	stack: [MAX_DEPTH]u8 = ---
	depth := u64(opts.max_depth) if opts.max_depth != 0 else MAX_DEPTH
	w := Walk(S, H){raw_data(src), h, raw_data(stack[:]), regs, depth, kernel.tier(), false, opts.tolerate, nil}
	return st_value(p, w.base[len(src):], 0, 0, &w, regs.a, regs.b, regs.c, on)
}

// The document from `p` with a depth stack past `MAX_DEPTH`, from the default heap and freed before it returns, which
// keeps the walk callable from a hook.
@(private, cold)
walk_deep :: #force_no_inline proc "contextless" (src: []u8, p: [^]u8, $S: Spec, depth: u64, tolerate: bit_set[Tolerance; u8], h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	context = runtime.default_context()
	stack, err := make([]u8, depth)
	if err != nil {
		return core.fault_at(0, .No_Memory)
	}
	defer delete(stack)
	w := Walk(S, H){raw_data(src), h, raw_data(stack), regs, depth, kernel.tier(), false, tolerate, nil}
	return st_value(p, w.base[len(src):], 0, 0, &w, regs.a, regs.b, regs.c, on)
}

// The features every state is built with: one tier for each target, on x86-64 its floor.
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
	h: core.No_Hooks
	regs: core.Hook_Regs
	v := Walk(S, core.No_Hooks){w.base, &h, w.stack, &regs, w.depth, w.tier, false, w.tolerate, nil}
	when open {
		return st_open(p, end, d, ind, &v, 0, 0, 0, core.no_hook)
	} else {
		return st_value(p, end, d, ind, &v, 0, 0, 0, core.no_hook)
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
	return core.fault_at(at(w, p), kind, u8(detail))
}

// The document ended at `p`.
@(private)
ended :: #force_inline proc "contextless" (w: ^Walk($S, $H), hs: core.Hook_Regs, p: [^]u8) -> u64 {
	w.regs^ = hs
	return core.fault_at(at(w, p), .None)
}

// A hook stopped the walk on the token that ends at `p`.
@(private)
stopped :: #force_inline proc "contextless" (w: ^Walk($S, $H), hs: core.Hook_Regs, p: [^]u8) -> u64 {
	w.regs^ = hs
	return core.fault_at(at(w, p), .None, core.STOPPED)
}
