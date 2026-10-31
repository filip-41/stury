// JSON's walk: each grammar state is a procedure that tail-calls the next with `#must_tail` (states.odin). A state
// reads the first byte of its token and branches on it. Strings (strings.odin), numbers and literals (scalars.odin)
// and whitespace (whitespace.odin) are read by leaf procedures.
package json

import "base:intrinsics"
import "base:runtime"
import core "../core"
import kernel "../core/kernel"

// The deepest nesting a text may have when `Options.max_depth` is 0. An open bracket past the limit faults
// `Too_Deep` at that bracket.
MAX_DEPTH :: 1024

// `Spec` is the grammar a text follows, a compile-time parameter, so a build compiles only the specs it names.
Spec :: enum u8 {
	Json, // RFC 8259
	Jsonc, // RFC 8259 with `//` and `/* */` comments wherever whitespace may stand, and a comma before a close bracket
	Json5, // JSON5 1.0.0
}

// A `Feature` names a rule set a spec adds to RFC 8259. States test features with `when`, so a spec's walk compiles
// only its own rules.
@(private)
Feature :: enum u8 {
	Comments,
	Trailing_Commas,
	Es5, // JSON5's ECMAScript forms: its numbers, strings, unquoted keys and whitespace (json5.odin)
}

// `FEATURES` holds the features of each spec. Both specs with comments also have trailing commas: a close bracket
// after a comment run is read without checking whether an open bracket or a comma came before the run.
@(private)
FEATURES :: [Spec]bit_set[Feature] {
	.Json  = {},
	.Jsonc = {.Comments, .Trailing_Commas},
	.Json5 = {.Comments, .Trailing_Commas, .Es5},
}

// `Options` holds a walk's run-time options. The zero value is the default.
Options :: struct {
	// The deepest nesting a text may have, 0 for `MAX_DEPTH`. A depth up to `MAX_DEPTH` keeps the stack in
	// `walk_document`'s frame, and a larger one allocates one byte per level on the default heap.
	max_depth: u32,
	// The rules a text may break, each with a fixed reading. Empty by default.
	tolerate:  bit_set[Tolerance; u8],
}

// `Tolerance` names a rule a caller lets a text break. The walk does not fault there, and the decoded string shows the
// tolerant reading.
Tolerance :: enum u8 {
	// Ill-formed UTF-8 in a string: each maximal subpart of an ill-formed sequence reads as U+FFFD.
	Invalid_Utf8,
	// A `\u` escape of a surrogate half that no other half pairs with reads as U+FFFD.
	Lone_Surrogate,
}

// `Detail` holds JSON's detail for a `core.Fault_Kind`, in `core.Fault.detail`.
Detail :: enum u8 {
	None,
	Literal, // `Bad_Char`: a byte breaking `true`, `false` or `null`
	Identifier, // `Bad_Char`: a byte that starts no key, quoted or not, where an object's key must start
	Colon, // `Bad_Char`: a byte where a member's colon must be
}

// `RULES` is JSON's `core.Rules`, one per `Detail` value, which every fault the walk returns points to.
@(rodata)
RULES := core.Rules{"json", {{}, {"literal", "Invalid literal"}, {"identifier", "Invalid unquoted key"}, {"colon", "Missing colon after key"}}}

// Checks that `src` holds exactly one document: an optional leading BOM, the document, then whitespace and, in a
// spec with comments, comments up to the text's end. Returns the fault, or nil.
validate :: proc "contextless" (src: []u8, $S: Spec, opts := Options{}) -> Maybe(core.Fault) {
	p := raw_data(src)
	end := p[len(src):]
	h: core.No_Hooks
	regs: core.Hook_Regs
	r := walk_document(src, skip_ws(p[core.text_start(src, 0):], end), S, opts, &h, &regs, core.no_hook)
	if r & 0xff != 0 {
		return core.fault_of(r, &RULES)
	}
	return tail_fault(src, r >> 16, S)
}

// Returns the fault for the bytes after a document that ends at `hi`, or nil when only whitespace and, in a spec
// with comments, comments up to the text's end follow it. Any other byte faults `Trailing`.
@(private)
tail_fault :: proc "contextless" (src: []u8, hi: u64, $S: Spec) -> Maybe(core.Fault) {
	p := raw_data(src)
	end := p[len(src):]
	q := skip_ws(p[hi:], end)
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

// Reads one document starting at `lo`. Returns one past its last byte and the fault, or nil. Before the document it
// passes over one BOM at the text's first byte, whitespace, record separators 0x1E, and comments that no document
// follows before the text's end or a 0x1E, so a stream of documents (NDJSON, RFC 7464, jq's input) is a loop of
// walks from where the last one ended. Outside a string a later BOM faults `Bad_Char` in JSON and JSONC and is
// whitespace in JSON5. When only those bytes remain, or `lo` is past the text's end, no token is made and the text's
// end is returned with no fault. When a hook stops the walk, `hi` is one past the token it stopped on and no later
// byte was read, so `hi` is no document boundary. `regs` is passed to the first token and holds what the hook
// returned last.
walk :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	q, _ := document_start(src, lo, S)
	h2, f2, _ := walk_from(src, q, S, opts, h, regs, on)
	return h2, f2
}

// Reads the run before a document, for `walk` and `build`: one BOM at the text's first byte, whitespace, record
// separators 0x1E, and comments that no document follows before the text's end or a 0x1E. Returns the document's
// first byte or the text's end, and the first 0x1E crossed, which a stream passes over and `build` refuses.
@(private)
document_start :: proc "contextless" (src: []u8, lo: u64, $S: Spec) -> (q: [^]u8, sep: [^]u8) {
	p := raw_data(src)
	end := p[len(src):]
	q = skip_ws(p[core.text_start(src, min(lo, u64(len(src)))):], end)
	for q < end {
		if q[0] == 0x1e {
			if sep == nil {
				sep = q
			}
			q = skip_ws(q[1:], end)
			continue
		}
		// A comment before the text's end or a 0x1E is the foot of the document before it, or of no document.
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
	return
}

// Reads the document at `q`, where `document_start` left it. Returns one past its last byte, the fault or nil, and
// whether a hook stopped the walk.
@(private)
walk_from :: #force_inline proc "contextless" (src: []u8, q: [^]u8, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault), stopped: bool) {
	if q == raw_data(src)[len(src):] {
		return u64(len(src)), nil, false
	}
	r := walk_document(src, q, S, opts, h, regs, on)
	return r >> 16, core.fault_of(r, &RULES), r & 0xff == 0 && u8(r >> 8) == core.STOPPED
}

// `Walk` holds the state a walk carries besides its registers. `stack[i]` bit 0 is set when the container at depth
// `i` is an object. The open that pushes past depth `i` writes `stack[i]`, and `depth` slots are allocated, so no slot
// is read before it is written. `tier` selects the string reader built for this CPU.
@(private)
Walk :: struct($S: Spec, $H: typeid) {
	base:     [^]u8,
	hooks:    ^H,
	stack:    [^]u8,
	regs:     ^core.Hook_Regs,
	depth:    u64,
	tier:     kernel.Tier,
	// Whether the state that passed a comment run to `st_comments_after` read the comma before it. It fills the
	// padding after `tier`, so a spec without comments builds the same `Walk` size.
	crossed:  bool,
	// `Options.tolerate`, read only where a string faults.
	tolerate: bit_set[Tolerance; u8],
	// Where the next state continues: for `string_escaped`, the block holding the string's first backslash, for
	// `st_comments_after`, the run's first comment, which the previous state has read up to.
	resume:   [^]u8,
}

// `PASS_END` is set in the stack slot of the depth where a walk that passes over a skipped value ends, so a close to
// that depth ends the pass. `]` with this bit shifted into bit 5 is no `]` or `}`, so the close loop stops when it
// reads the slot.
@(private)
PASS_END :: 4

// Reads the document whose first byte is `p`. Keeps the depth stack in this frame up to `MAX_DEPTH`, and allocates
// it on the default heap above that.
@(private)
walk_document :: #force_inline proc "contextless" (src: []u8, p: [^]u8, $S: Spec, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> u64 {
	if opts.max_depth > MAX_DEPTH {
		return walk_deep(src, p, S, u64(opts.max_depth), opts.tolerate, h, regs, on)
	}
	// `= ---` leaves the array unwritten, where a struct would be zeroed. Every slot is written before it is read.
	stack: [MAX_DEPTH]u8 = ---
	depth := u64(opts.max_depth) if opts.max_depth != 0 else MAX_DEPTH
	w := Walk(S, H){raw_data(src), h, raw_data(stack[:]), regs, depth, kernel.tier(), false, opts.tolerate, nil}
	return st_value(p, w.base[len(src):], 0, 0, &w, regs.a, regs.b, regs.c, on)
}

// `walk_document` for a depth past `MAX_DEPTH`. Allocates `depth` bytes on the default heap and frees them before
// returning, so a hook can call the walk.
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

// `STATE_TIER` is the CPU tier every state is built for: `V2` on x86-64, `Base` elsewhere.
when ODIN_ARCH == .amd64 {
	@(private)
	STATE_TIER :: kernel.Tier.V2
} else {
	@(private)
	STATE_TIER :: kernel.Tier.Base
}

@(private)
STATE_FEATURES :: kernel.FEATURES[STATE_TIER]

// Runs the walk without hooks from `p`, starting in `st_open` or `st_value`, until the stack marks `PASS_END` or a
// root value ends. It is a call because `#must_tail` cannot jump between two instances of the walk.
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

// Passes the token over `p..q` to the hook and returns its `Action`. The readers refuse a token wider than `Token.n`
// holds before they call `emit`.
@(private)
emit :: #force_inline proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, kind: core.Kind, role: core.Role, p, q: [^]u8, spelling: u16) -> core.Action {
	a: core.Action
	hs^, a = on(w.hooks, hs^, core.Token{at(w, p), u32(intrinsics.ptr_sub(q, p)), kind, role, spelling})
	return a
}

// `emit_string` is `emit` for a quoted string, whose token spans the bytes between the quotes. `SPELLING_QUOTED` marks
// the pair as outside the span, so a read does not probe `src` for it and `span` adds it back.
@(private)
emit_string :: #force_inline proc "contextless" (w: ^Walk($S, $H), $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), hs: ^core.Hook_Regs, kind: core.Kind, role: core.Role, p, q: [^]u8, spelling: u16) -> core.Action {
	a: core.Action
	hs^, a = on(w.hooks, hs^, core.Token{at(w, p) + 1, u32(intrinsics.ptr_sub(q, p) - 2), kind, role, spelling | core.SPELLING_QUOTED})
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

// Returns the fault value for a document that ended at `p`, with kind `.None`.
@(private)
ended :: #force_inline proc "contextless" (w: ^Walk($S, $H), hs: core.Hook_Regs, p: [^]u8) -> u64 {
	w.regs^ = hs
	return core.fault_at(at(w, p), .None)
}

// Returns the fault value for a hook that stopped the walk at the token ending at `p`, with `core.STOPPED` in the
// detail.
@(private)
stopped :: #force_inline proc "contextless" (w: ^Walk($S, $H), hs: core.Hook_Regs, p: [^]u8) -> u64 {
	w.regs^ = hs
	return core.fault_at(at(w, p), .None, core.STOPPED)
}
