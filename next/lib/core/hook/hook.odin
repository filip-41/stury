package hook

import "base:intrinsics"
import "base:runtime"
import "stury:lib/core/tape"

// The protocol between a format's walk and its hooks, imported by formats, the hooks of `lib/ops` and the C ABI. A hook
// consumes a walk's tokens, as a document's builder does, and a validate has none. A hook is a compile-time parameter
// of the walk, which is compiled once per hook with the hook inlined.

// A hook's answer to a token.
Action :: enum u8 {
	Next,
	// On an `Array` or `Object`, pass what it holds with no tokens up to its `End`, while the walk still validates its
	// bytes. On a `Key`, pass the member's value with no token: a scalar is judged, a container is judged whole, and no
	// `End` follows, as no opening token was given. The facts between the key and its value are still given. `Next` on
	// any other token. Only a hook with `.Skips` gives it, and every walk honours it.
	Skip,
	// On an `Array` or `Object`, validate it and the rest of the text with no more tokens. Only a hook with `.Skips`
	// gives it.
	Rest,
	// On an `Array` or `Object`, store it whole through the inner hook of the hook's `Keeps`, which then gets its `End`.
	// Only a hook with `.Keeps` gives it.
	Keep,
	// On an `Object`, store its members through the hook's `Keeps` as `Keep` does, each container value as one node,
	// which then gets its `End`. Only a hook with `.Keeps` gives it.
	Keep_Stubs,
	Stop, // end the walk after this token, and the text past it is not read
	// Answer of a hook with `.Rooms` whose room has no place for the token's node. The walk grows the room and gives
	// the token again.
	Grow,
}

// Behaviors of a hook beyond taking tokens. The walk compiles in a capability's code only for a hook that names it.
Capability :: enum u8 {
	Skips, // answers `Skip` and `Rest`
	Unspelled, // reads no number's spelling, so the walk gives a plain decimal `Number` a spelling of 0
	Levels, // keeps a level per open container, through the protocol's `Levels`
	Rooms, // stores each token's node in a room the walk checks, through the protocol's `Rooms`
	Keeps, // answers `Keep` and `Keep_Stubs`, through the protocol's `Keeps`
	Number_Blocks, // receives the arrays of numbers a walk reads in blocks
	Walk, // reads values again inside its calls, in the walk set in its field `walk: rawptr`
	Credits, // reads a key's escape credit, which the walk gives a key it reads whole and no other
	// Answers `Skip` on a member's key the same way for the member at the same place in each object of an array, so a
	// walk whose members are placed by position, as a delimited text's cells are, may pass such a member with no token
	// once the hook skipped it in an earlier object. The walk adds the members it passed so to the hook's field
	// `dropped: u64` before it gives the object's `End`.
	Columns,
}

Capabilities :: bit_set[Capability; u16]

// The type of the field `protocol` every hook has: its capabilities `C`, and for `.Levels`, `.Rooms` and `.Keeps` a
// `Levels`, `Rooms` and `Keeps` type naming its procs, `Unused` for one it lacks. `check` says what is wrong.
Protocol :: struct($C: Capabilities, $L, $R, $K: typeid) {}

// The type of a protocol's `Levels`, `Rooms` or `Keeps` for a hook without that capability.
Unused :: struct {}

PROTOCOL_FIELD :: "protocol"

// Fails to compile, naming the gap, unless hook type `H` keeps the protocol.
check :: #force_inline proc "contextless" ($H: typeid) {
	#assert(intrinsics.type_has_field(H, PROTOCOL_FIELD), "a hook has a field `protocol: hook.Protocol(...)`")
	P :: intrinsics.type_field_type(H, PROTOCOL_FIELD)
	#assert(intrinsics.type_is_specialization_of(P, Protocol), "a hook's `protocol` field is a `hook.Protocol(...)`")
	C :: intrinsics.type_polymorphic_record_parameter_value(P, 0)
	L :: intrinsics.type_polymorphic_record_parameter_value(P, 1)
	R :: intrinsics.type_polymorphic_record_parameter_value(P, 2)
	K :: intrinsics.type_polymorphic_record_parameter_value(P, 3)
	#assert((.Levels in C) == intrinsics.type_is_specialization_of(L, Levels), "a hook has `.Levels` exactly when its protocol names `hook.Levels(held, grow)`")
	#assert(.Levels in C || L == Unused, "a hook without `.Levels` names `hook.Unused` for it")
	#assert((.Rooms in C) == intrinsics.type_is_specialization_of(R, Rooms), "a hook has `.Rooms` exactly when its protocol names `hook.Rooms(end, grow)`")
	#assert(.Rooms in C || R == Unused, "a hook without `.Rooms` names `hook.Unused` for it")
	#assert((.Keeps in C) == intrinsics.type_is_specialization_of(K, Keeps), "a hook has `.Keeps` exactly when its protocol names `hook.Keeps(Inner, of, whole, stubs)`")
	#assert(.Keeps in C || K == Unused, "a hook without `.Keeps` names `hook.Unused` for it")
	#assert(.Keeps not_in C || .Skips in C, "a hook with `.Keeps` has `.Skips`, as the walk reads its keeps where it reads its skips")
	#assert(.Number_Blocks not_in C || .Skips not_in C, "a hook with `.Number_Blocks` answers only `Next` and `Stop`, so it has no `.Skips`")
	#assert(.Walk not_in C || intrinsics.type_has_field(H, "walk"), "a hook with `.Walk` has a field `walk: rawptr`")
	#assert(.Columns not_in C || .Skips in C, "a hook with `.Columns` has `.Skips`, as it passes members by `Skip`")
	when .Columns in C {
		#assert(intrinsics.type_field_type(H, "dropped") == u64, "a hook with `.Columns` has a field `dropped: u64`")
	}
	when .Walk in C {
		#assert(intrinsics.type_field_type(H, "walk") == rawptr, "a hook's `walk` field is a `rawptr`")
	}
	when .Keeps in C {
		check(intrinsics.type_polymorphic_record_parameter_value(K, 0))
	}
}

// The `Levels` of a protocol: a hook that keeps a stack with a level per container open in it, which the walk sizes to
// its own depth and grows before it nests past it. `Held` is the levels the stack holds and `Grow` makes it hold `want`
// or returns false when memory is refused. It is given the hook's registers and the offset of the text the walk is at,
// so that a hook whose room the new levels would sit after can grow that room first. Both read the hook through a `rawptr`, as a proc type cannot name a type
// that holds it.
Levels :: struct($Held: proc "contextless" (h: rawptr) -> int, $Grow: proc "contextless" (h: rawptr, want: int, s: ^Regs, at: u64) -> bool) {}

// The levels the stack of `h`, a hook with `.Levels`, holds.
levels_held :: #force_inline proc "contextless" (h: ^$H) -> int {
	L :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, PROTOCOL_FIELD), 1)
	return levels_held_by(intrinsics.type_polymorphic_record_parameter_value(L, 0), h)
}

// Makes the stack of `h`, a hook with `.Levels`, hold `want` levels, or returns false.
levels_grow :: #force_inline proc "contextless" (h: ^$H, want: int, s: ^Regs, at: u64) -> bool {
	L :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, PROTOCOL_FIELD), 1)
	return levels_grow_by(intrinsics.type_polymorphic_record_parameter_value(L, 1), h, want, s, at)
}

@(private)
levels_held_by :: #force_inline proc "contextless" ($Held: proc "contextless" (h: rawptr) -> int, h: rawptr) -> int {
	return Held(h)
}

@(private)
levels_grow_by :: #force_inline proc "contextless" ($Grow: proc "contextless" (h: rawptr, want: int, s: ^Regs, at: u64) -> bool, h: rawptr, want: int, s: ^Regs, at: u64) -> bool {
	return Grow(h, want, s, at)
}

// The `Rooms` of a protocol: a hook that stores each token's node at the address in its register `a`, in a room that
// ends at the address `End` gives and that the walk checks before each node, a keep's inner walk included. `Grow`
// makes place for at least one more node, for the token at offset `at`, or returns false when memory or the budget
// refuses it. Both read the hook through a `rawptr`, as `Levels` does.
Rooms :: struct($End: proc "contextless" (h: rawptr) -> uintptr, $Grow: proc "contextless" (h: rawptr, s: ^Regs, at: u64) -> bool) {}

// The address one past the room of `h`, a hook with `.Rooms`.
rooms_end :: #force_inline proc "contextless" (h: ^$H) -> uintptr {
	R :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, PROTOCOL_FIELD), 2)
	return rooms_end_by(intrinsics.type_polymorphic_record_parameter_value(R, 0), h)
}

// Grows the room of `h`, a hook with `.Rooms`, for the token at `at`, or returns false.
rooms_grow :: #force_inline proc "contextless" (h: ^$H, s: ^Regs, at: u64) -> bool {
	R :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, PROTOCOL_FIELD), 2)
	return rooms_grow_by(intrinsics.type_polymorphic_record_parameter_value(R, 1), h, s, at)
}

@(private)
rooms_end_by :: #force_inline proc "contextless" ($End: proc "contextless" (h: rawptr) -> uintptr, h: rawptr) -> uintptr {
	return End(h)
}

@(private)
rooms_grow_by :: #force_inline proc "contextless" ($Grow: proc "contextless" (h: rawptr, s: ^Regs, at: u64) -> bool, h: rawptr, s: ^Regs, at: u64) -> bool {
	return Grow(h, s, at)
}

// The `Keeps` of a protocol: a hook whose `Keep` and `Keep_Stubs` the walk answers by reading the container in the
// same walk as one of hook type `Inner`, at the address `Of` gives for the hook, with `Whole` for `Keep` and `Stubs`
// for `Keep_Stubs`. Both take fact tokens too, and read the inner hook through a `rawptr`, as `Levels` does. The walk
// gives the outer hook the container's `End` after.
Keeps :: struct($Inner: typeid, $Of: proc "contextless" (h: rawptr) -> rawptr, $Whole, $Stubs: proc "contextless" (h: rawptr, s: Regs, t: tape.Token) -> (Regs, Action)) {}

// Gives token `t` to the inner hook of `h`, a hook with `.Keeps`, as the walk does inside a container `h` answered
// `Keep_Stubs` for with `STUBS` and else `Keep`.
keeps_give :: #force_inline proc "contextless" (h: ^$H, s: Regs, t: tape.Token, $STUBS: bool) -> (Regs, Action) {
	K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, PROTOCOL_FIELD), 3)
	when STUBS {
		return keeps_give_by(intrinsics.type_polymorphic_record_parameter_value(K, 1), intrinsics.type_polymorphic_record_parameter_value(K, 3), h, s, t)
	} else {
		return keeps_give_by(intrinsics.type_polymorphic_record_parameter_value(K, 1), intrinsics.type_polymorphic_record_parameter_value(K, 2), h, s, t)
	}
}

// The inner hook of `h`, a hook with `.Keeps`, which the protocol's `Keeps` names the type of.
keeps_inner :: #force_inline proc "contextless" (h: ^$H) -> rawptr {
	K :: intrinsics.type_polymorphic_record_parameter_value(intrinsics.type_field_type(H, PROTOCOL_FIELD), 3)
	return keeps_inner_by(intrinsics.type_polymorphic_record_parameter_value(K, 1), h)
}

@(private)
keeps_inner_by :: #force_inline proc "contextless" ($Of: proc "contextless" (h: rawptr) -> rawptr, h: rawptr) -> rawptr {
	return Of(h)
}

@(private)
keeps_give_by :: #force_inline proc "contextless" ($Of: proc "contextless" (h: rawptr) -> rawptr, $Give: proc "contextless" (h: rawptr, s: Regs, t: tape.Token) -> (Regs, Action), h: rawptr, s: Regs, t: tape.Token) -> (Regs, Action) {
	return Give(Of(h), s, t)
}

// Three words of a hook's state, passed in the walk's argument registers from token to token. They suit what changes
// with every token, such as a cursor or a count.
Regs :: struct {
	a, b, c: u64,
}

// The hook of a walk that keeps nothing, which compiles to no code.
No_Hooks :: struct {
	protocol: Protocol(NO_HOOKS_CAPS, Unused, Unused, Unused),
}

NO_HOOKS_CAPS :: Capabilities{.Number_Blocks}

no_hook :: #force_inline proc "contextless" (h: ^No_Hooks, s: Regs, t: tape.Token) -> (Regs, Action) {
	return s, .Next
}

// A walk's outcome in one word. Bits 16 and up hold the offset where it ended or failed, bits 8 to 15 a detail and bits
// 0 to 7 the outcome, a `Fault_Kind` or a `WALK_` outcome.
Walk_Result :: distinct u64

// Walk outcomes past the `Fault_Kind` values.
WALK_MORE :: u8(0xFB) // the walk read the window of a text in pieces to its end, and the text continues
WALK_STEPS :: u8(0xFC) // the walk opened a container past `Budget.steps`
WALK_NO_MEMORY :: u8(0xFD) // a stack could not grow
WALK_STOPPED :: u8(0xFE) // a hook returned `.Stop`
WALK_TOO_DEEP :: u8(0xFF) // the nesting passed `Budget.depth`

#assert(len(tape.Fault_Kind) < int(WALK_MORE))

walk_result :: #force_inline proc "contextless" (at: u64, outcome: u8, detail: u8 = 0) -> Walk_Result {
	return Walk_Result(at << 16 | u64(detail) << 8 | u64(outcome))
}

// Where the walk ended or failed, and its error, nil for a walk that read its text or its window, or was stopped.
walk_error :: #force_inline proc "contextless" (r: Walk_Result, rules: ^tape.Rules) -> (at: u64, err: tape.Error, stopped: bool) {
	at = u64(r) >> 16
	switch u8(r) {
	case 0, WALK_MORE:
	case WALK_STOPPED:
		stopped = true
	case WALK_TOO_DEEP:
		err = tape.Exceeded{at = at, kind = .Depth}
	case WALK_STEPS:
		err = tape.Exceeded{at = at, kind = .Steps}
	case WALK_NO_MEMORY:
		err = runtime.Allocator_Error.Out_Of_Memory
	case:
		err = tape.Fault{at = at, rules = rules, kind = tape.Fault_Kind(u8(r)), detail = u8(u64(r) >> 8)}
	}
	return
}

// Runs `task(arg)` on the calling thread and on the threads of `runner`, and returns once every call has. The calls
// share the work through `arg`, as only the caller's call is certain to run.
fan :: proc(runner: ^tape.Runner, task: proc(arg: rawptr), arg: rawptr) {
	runner.start(runner.data, runner.threads, task, arg)
	task(arg)
	runner.finish(runner.data)
}
