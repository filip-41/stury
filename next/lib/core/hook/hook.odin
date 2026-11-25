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
	// `dropped: u64` before it gives the object's `End`, and learns the columns the hook takes from the first object
	// only when its field `alike: bool` says the hook answers the same in every object. The objects after the first may
	// be replayed through the hook's field `replay: Replay`.
	Columns,
	// Reads a text in windows, so the walk keeps the state of the window in its field `piece`. A walk with it also
	// counts steps.
	Windows,
	// Stores no node for a key token, as a table's rows name their cells by place through a header stored apart, so the
	// walk makes no room for one. It stores the room's other tokens, so a hook with `.Unkeyed` has `.Rooms`.
	Unkeyed,
	// Takes a replayed object's members as their value tokens, each in its turn and with no key, in place of the
	// `cells` of its `Replay`, and answers each with `Next`. A hook with `.Cell_Values` has `.Columns`.
	Cell_Values,
	// In an object, `b` points at the `Expected_Key` of the key it takes next, which it takes by moving `b` past
	// `EXPECTED_STRIDE` bytes and changing nothing else, so a walk may match that key itself and give no token for it.
	// The walk may keep the keys it matched in the `Expected_Memo` the hook's field `expected` points at.
	Expects,
}

Capabilities :: bit_set[Capability; u32]

// The columns a walk of `.Columns` gives a bit each in its `u64` of the columns a hook takes, the last bit standing for
// every column from there on, and so the most cells a record the hook replays holds.
COLUMN_BITS :: 63

#assert(COLUMN_BITS + 1 == 8 * size_of(u64))

// How a walk of `.Columns` replays the objects after the first. Before its first token the walk sets `fixed` to say that
// each object after the first gives the keys of the columns the hook took in the first, at the same places, or the walk
// ends at a fault. A hook that makes in such an object what it made in the first sets `replays` at the object's opening
// token and clears it at its `End`. In between the walk gives the cells of the columns it learnt with no token: each is
// the value token it would give, stored in the next entry of `cells` and counted in `given`.
Replay :: struct {
	fixed:   bool,
	replays: bool,
	cells:   []tape.Token,
	given:   int,
}

// The key a hook with `.Expects` takes next: `word` the second word of its token with no spelling, `head` its first eight
// bytes and `tail` its last eight, or for a key of at most eight bytes the mask of its bytes. `word` is `max(u64)` where
// the hook expects no key. A key of more than sixteen bytes is the hook's to match.
Expected_Key :: struct {
	word, head, tail: u64,
}

// The bytes from one `Expected_Key` of a hook to the next.
EXPECTED_STRIDE :: 48

// The keys a walk matched for a hook with `.Expects`, by places of the walk's own, each entry a place and the `b` the
// walk matched that place's key at, so that a key the walk knows repeats the bytes of the last key at its place is
// taken at the same `b` with no compare. A walk reads only entries it wrote, so a memo needs no zeroing.
Expected_Memo :: distinct [256][2]u64

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
	#assert(.Unkeyed not_in C || .Rooms in C, "a hook with `.Unkeyed` has `.Rooms`, whose room it stores the other tokens in")
	#assert(.Columns not_in C || .Skips in C, "a hook with `.Columns` has `.Skips`, as it passes members by `Skip`")
	#assert(.Cell_Values not_in C || .Columns in C, "a hook with `.Cell_Values` has `.Columns`, whose replays it takes")
	when .Expects in C {
		#assert(intrinsics.type_field_type(H, "expected") == ^Expected_Memo, "a hook with `.Expects` has a field `expected: ^hook.Expected_Memo`")
	}
	when .Columns in C {
		#assert(intrinsics.type_field_type(H, "dropped") == u64, "a hook with `.Columns` has a field `dropped: u64`")
		#assert(intrinsics.type_field_type(H, "alike") == bool, "a hook with `.Columns` has a field `alike: bool`")
		#assert(intrinsics.type_field_type(H, "replay") == Replay, "a hook with `.Columns` has a field `replay: Replay`")
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
WALK_EXPANSION :: u8(0xFA) // the text's references expanded past `Budget.expansion`
WALK_MORE :: u8(0xFB) // the walk read the window of a text in pieces to its end, and the text continues
WALK_STEPS :: u8(0xFC) // the walk opened a container past `Budget.steps`
WALK_NO_MEMORY :: u8(0xFD) // a stack could not grow
WALK_STOPPED :: u8(0xFE) // a hook returned `.Stop`
WALK_TOO_DEEP :: u8(0xFF) // the nesting passed `Budget.depth`

#assert(len(tape.Fault_Kind) < int(WALK_EXPANSION))

walk_result :: #force_inline proc "contextless" (at: u64, outcome: u8, detail: u8 = 0) -> Walk_Result {
	return Walk_Result(at << 16 | u64(detail) << 8 | u64(outcome))
}

// The result `r` of a walk with `steps` of `Budget.steps` left: past the budget the walk stops its hook, so a stop with
// none left is `WALK_STEPS`.
steps_result :: #force_inline proc "contextless" (r: Walk_Result, steps: u64) -> Walk_Result {
	if u8(r) == WALK_STOPPED && steps == 0 {
		return walk_result(u64(r) >> 16, WALK_STEPS)
	}
	return r
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
	case WALK_EXPANSION:
		err = tape.Exceeded{at = at, kind = .Expansion}
	case WALK_NO_MEMORY:
		err = runtime.Allocator_Error.Out_Of_Memory
	case:
		err = tape.Fault{at = at, rules = rules, kind = tape.Fault_Kind(u8(r)), detail = u8(u64(r) >> 8)}
	}
	return
}

// What `fan_each` shares: the next index to claim, the count of them and the argument given to each task.
@(private)
Fan_Each :: struct {
	next, count: int,
	arg:         rawptr,
}

// Runs `task(arg, k)` once for each `k` below `count`, on the calling thread and on the threads of `runner`, each thread
// claiming the next index while any is left. The calls share the work through `arg`. Specializing on `$task` gives each
// workload a distinct trampoline address so `host.Pool` tracks per-task adaptive widths independently.
fan_each :: proc(runner: ^tape.Runner, count: int, $task: proc(arg: rawptr, k: int), arg: rawptr) {
	each := Fan_Each{count = count, arg = arg}
	fan(runner, proc(arg: rawptr) {
			e := (^Fan_Each)(arg)
			for {
				k := intrinsics.atomic_add(&e.next, 1)
				if k >= e.count {
					return
				}
				task(e.arg, k)
			}
		}, &each)
}

// Runs `task(arg)` on the calling thread and on the threads of `runner`, and returns once every call has. The calls
// share the work through `arg`, as only the caller's call is certain to run.
fan :: proc(runner: ^tape.Runner, task: proc(arg: rawptr), arg: rawptr) {
	runner.start(runner.data, runner.threads, task, arg)
	task(arg)
	runner.finish(runner.data)
}
