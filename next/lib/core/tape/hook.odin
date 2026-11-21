package tape

import "base:runtime"

// A hook is the consumer of a walk's tokens, such as a document's builder, or none for a validate. It is a compile-time
// parameter of the walk, which is compiled once per hook with the hook inlined.

// A hook's answer to a token.
Action :: enum u8 {
	Next,
	Stop, // end the walk after this token; the text past it is not read
}

// Three words of a hook's state that the walk's states carry in argument registers. They suit what changes with every
// token, such as a cursor or a count.
Hook_Regs :: struct {
	a, b, c: u64,
}

// The hook of a walk that keeps nothing, which compiles to no code.
No_Hooks :: struct {}

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
