package walk

import "base:runtime"

// JSON's whitespace, shared across the codec and the CLI.
is_space :: #force_inline proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// A value's class, which the first byte of a value gives (`lex.VCLASS`) and the walk dispatches on: 0 is not a
// value's first byte. The container classes are adjacent and the scalar ones follow, so `vc <= VC_ARRAY` and
// `vc >= VC_STRING` split them, and `vc - VC_OBJECT < 2` tests for either container (0 wraps).
VC_NONE :: 0
VC_OBJECT :: 1 // `{`
VC_ARRAY :: 2 // `[`
VC_STRING :: 3 // `"`
VC_LITERAL :: 4 // `true`, `false` or `null`
VC_NUMBER :: 5 // `-` or a digit

// The walk cursor: source, position, and the resolved caps. Internal.
Scanner :: struct {
	src:    []byte,
	pos:    u64,
	limits: Limits,
	// What a walk past MAX_DEPTH allocates its spilled frame array with, and frees it with. Captured when the
	// scanner is made, so the free uses the allocator the allocation did even if `context.allocator` moves
	// mid-walk (a shape leaf's `any` decode does).
	alloc: runtime.Allocator,
}

// One open container: offset of its opening bracket, its member count so far, its node row, and whether
// it is an object (closing bracket, key after comma). Gap-free, so the walk's `= ---` frame stack is
// left uninitialized.
Open_Frame :: struct {
	lo:      u64,
	// `.Nodes`: the direct children counted so far, the row's `cnt` at the close.
	members: u64,
	// `.Nodes`: the container's row, patched at its close (`NO_ROW` when it has none).
	row:     u32,
	is_obj:  b32,
}

#assert(size_of(Open_Frame) == 24)

// `.Unique`: the keys of every open object, to find a key repeating one of its own object's. An
// open-addressed table (`slots`, linear probing) over the keys in the order they were met (`entries`). An
// object's keys leave at its close, newest first, so a cleared slot lies on no older key's probe and the
// table needs no tombstones.
Key_Set :: struct {
	entries:   [^]Key_Entry,
	// 0 when empty, else an entry's index + 1 under the slot mask (`2 * cap - 1`) and its hash's bits above it
	slots:     [^]u32,
	n:         u32,    // live entries
	cap:       u32,    // a power of two
	seed:      u64,    // the hash's key, per scan
	spilled:   bool,   // `entries` and `slots` came from `allocator`, not the scan entry's scratch
	allocator: runtime.Allocator,
}

// One remembered key: its token (quotes included), its hash, and the walk depth of its object, with
// `KEY_ESCAPED` set when the token holds an escape. Gap-free.
Key_Entry :: struct {
	lo, hi: u64,
	hash:   u32,
	depth:  u32,
}

KEY_ESCAPED :: u32(1) << 31

#assert(size_of(Key_Entry) == 24)
