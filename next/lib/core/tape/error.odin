package tape

import "base:runtime"
import "stury:lib/base/spell"

// A `Budget` limit that ran out.
Exceeded :: struct {
	at:   u64, // 0 for memory and steps, which name no byte
	kind: Budget_Kind,
}

Fault_Kind :: spell.Fault_Kind

// Why and where a text failed to parse.
Fault :: struct {
	at:     u64,
	rules:  ^Rules,
	kind:   Fault_Kind,
	detail: u8, // index into `rules.details`, 0 for none
}

// A format's fault rules.
Rules :: struct {
	format:  string,
	details: []Rule,
}

Rule :: struct {
	code:    string, // stable, for callers to match on
	message: string, // may change
}

// The error of a library call, one arm per cause.
Error :: union {
	Fault,
	runtime.Allocator_Error,
	Exceeded,
}
