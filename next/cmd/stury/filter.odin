package main

// The jq interpreter over each input.

import "base:runtime"

// The interpreter's stack: 4 GiB of address space reserved, committed only as far as a filter recurses
// (the main thread's 8 MiB gives out near 20000 levels). jq keeps its stack on the heap, so where jq runs
// out of memory this runs out of stack, and the guard below it ends the run as jq does. If the reservation
// or the thread fails (run_deep), the run ends with "cannot allocate memory" and exit 2.
DEEP_STACK :: 4 << 30

// What run_deep hands the thread it starts.
Deep_Job :: struct {
	run:  ^Run,
	ins:  ^Inputs,
	body: proc(run: ^Run, ins: ^Inputs),
	ctx:  runtime.Context,
}
