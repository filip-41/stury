package tape

import "base:intrinsics"
import "base:runtime"

// A hook is the consumer of a walk's tokens, such as a document's builder, or none for a validate. It is a compile-time
// parameter of the walk, which is compiled once per hook with the hook inlined.

// A hook's answer to a token.
Action :: enum u8 {
	Next,
	// On an `Array` or `Object`, pass what it holds with no tokens up to its `End`, while the walk still judges its
	// bytes. `Next` on any other token. Only a hook with a `skips` field gives it.
	Skip,
	// On an `Array` or `Object`, judge it and the rest of the text with no more tokens. Only a hook with a `skips`
	// field gives it.
	Rest,
	// On an `Array` or `Object`, store it whole with the builder that starts the hook, which then gets its `End`. Only
	// a scan's hook gives it.
	Keep,
	Stop, // end the walk after this token; the text past it is not read
	// The walk's answer for a hook with a `rooms` field whose room has no place for the token's node. The walk grows the
	// room and gives the token again.
	Grow,
}

// The field that lets a hook answer `Skip` and `Rest`. The walks compile the checks only for a hook that has it.
Skips :: struct {}

// The names of the fields a walk looks for in a hook, of types `Skips`, `Unspelled`, `Levels`, `Number_Blocks` and
// `Rooms`, and `KEEPS_FIELD` of a type the hook's package declares.
SKIPS_FIELD :: "skips"
UNSPELLED_FIELD :: "unspelled"
LEVELS_FIELD :: "open_levels"
// The field of a hook that answers `Keep`, the hook that stores a container whole. Its type is a struct with one proc
// value parameter, the inner hook's `proc "contextless" (h: ^Inner, s: Hook_Regs, t: Token) -> (Hook_Regs, Action)`,
// which takes fact tokens too. The walk reads the container with that proc as the walk of `Inner`, which must be the
// first field of this hook, so a pointer to this hook is one to it.
KEEPS_FIELD :: "keeps"
NUMBER_BLOCKS_FIELD :: "number_blocks"
ROOMS_FIELD :: "rooms"

// The field of a hook that reads no number's spelling, so the walk gives a plain decimal `Number` token a spelling
// of 0 and any other number its own.
Unspelled :: struct {}

// The field of a hook that keeps a stack with a level per container open in it, which the walk sizes to its own depth
// and grows before it nests past it. `Held` is the levels the stack holds and `Grow` makes it hold `want` or returns
// false when memory is refused. Both read the hook through a `rawptr`, as a proc type cannot name a type that holds it.
// A hook that reads no levels from the walk has no such field.
Levels :: struct($Held: proc "contextless" (h: rawptr) -> int, $Grow: proc "contextless" (h: rawptr, want: int) -> bool) {}

// The levels the stack of `h`, a hook with an `open_levels` field, holds.
levels_held :: #force_inline proc "contextless" (h: ^$H) -> int {
	return levels_held_by(intrinsics.type_polymorphic_record_parameter_value(type_of(h.open_levels), 0), h)
}

// Makes the stack of `h`, a hook with an `open_levels` field, hold `want` levels, or returns false.
levels_grow :: #force_inline proc "contextless" (h: ^$H, want: int) -> bool {
	return levels_grow_by(intrinsics.type_polymorphic_record_parameter_value(type_of(h.open_levels), 1), h, want)
}

@(private)
levels_held_by :: #force_inline proc "contextless" ($Held: proc "contextless" (h: rawptr) -> int, h: rawptr) -> int {
	return Held(h)
}

@(private)
levels_grow_by :: #force_inline proc "contextless" ($Grow: proc "contextless" (h: rawptr, want: int) -> bool, h: rawptr, want: int) -> bool {
	return Grow(h, want)
}

// The field of a hook that stores each token's node at the address in its register `a`, in a room that ends at the
// address `End` gives and that the walk checks before each node. `Grow` makes place for at least one more node, for
// the token at offset `at`, or returns false when memory or the budget refuses it. Both read the hook through a
// `rawptr`, as `Levels` does.
Rooms :: struct($End: proc "contextless" (h: rawptr) -> uintptr, $Grow: proc "contextless" (h: rawptr, s: ^Hook_Regs, at: u64) -> bool) {}

// The address one past the room of `h`, a hook with a `rooms` field.
rooms_end :: #force_inline proc "contextless" (h: ^$H) -> uintptr {
	return rooms_end_by(intrinsics.type_polymorphic_record_parameter_value(type_of(h.rooms), 0), h)
}

// Grows the room of `h`, a hook with a `rooms` field, for the token at `at`, or returns false.
rooms_grow :: #force_inline proc "contextless" (h: ^$H, s: ^Hook_Regs, at: u64) -> bool {
	return rooms_grow_by(intrinsics.type_polymorphic_record_parameter_value(type_of(h.rooms), 1), h, s, at)
}

@(private)
rooms_end_by :: #force_inline proc "contextless" ($End: proc "contextless" (h: rawptr) -> uintptr, h: rawptr) -> uintptr {
	return End(h)
}

@(private)
rooms_grow_by :: #force_inline proc "contextless" ($Grow: proc "contextless" (h: rawptr, s: ^Hook_Regs, at: u64) -> bool, h: rawptr, s: ^Hook_Regs, at: u64) -> bool {
	return Grow(h, s, at)
}

// The field of a hook that takes the tokens of the arrays of numbers the walk reads in blocks, which it gives in text
// order. The hook answers every token with `Next`, and the walk gives a hook with a `rooms` field a block only while
// its room has place for a node per byte.
Number_Blocks :: struct {}

// Three words of a hook's state that the walk's states carry in argument registers. They suit what changes with every
// token, such as a cursor or a count.
Hook_Regs :: struct {
	a, b, c: u64,
}

// The hook of a walk that keeps nothing, which compiles to no code.
No_Hooks :: struct {
	number_blocks: Number_Blocks,
}

no_hook :: #force_inline proc "contextless" (h: ^No_Hooks, s: Hook_Regs, t: Token) -> (Hook_Regs, Action) {
	return s, .Next
}

// A walk's outcome in one word. Bits 16 and up hold the offset where it ended or failed, bits 8 to 15 a detail and bits
// 0 to 7 the outcome, a `Fault_Kind` or a `WALK_` outcome.
Walk_Result :: distinct u64

// Walk outcomes past the `Fault_Kind` values.
WALK_NO_MEMORY :: u8(0xFD) // a stack could not grow
WALK_STOPPED :: u8(0xFE) // a hook returned `.Stop`
WALK_TOO_DEEP :: u8(0xFF) // the nesting passed `Budget.depth`

#assert(len(Fault_Kind) < int(WALK_NO_MEMORY))

walk_result :: #force_inline proc "contextless" (at: u64, outcome: u8, detail: u8 = 0) -> Walk_Result {
	return Walk_Result(at << 16 | u64(detail) << 8 | u64(outcome))
}

// Where the walk ended or failed, and its error, nil for a walk that read its text or was stopped.
walk_error :: #force_inline proc "contextless" (r: Walk_Result, rules: ^Rules) -> (at: u64, err: Error, stopped: bool) {
	at = u64(r) >> 16
	switch u8(r) {
	case 0:
	case WALK_STOPPED:
		stopped = true
	case WALK_TOO_DEEP:
		err = Exceeded{at = at, kind = .Depth}
	case WALK_NO_MEMORY:
		err = runtime.Allocator_Error.Out_Of_Memory
	case:
		err = Fault{at = at, rules = rules, kind = Fault_Kind(u8(r)), detail = u8(u64(r) >> 8)}
	}
	return
}
