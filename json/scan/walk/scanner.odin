package walk

import "base:runtime"
import core_pkg "../../../core"

// A value's class, which the first byte of a value gives (`lex.VCLASS`) and the walk dispatches on: core's walk
// classes, so `vc - VC_OBJECT < 2` tests for either container (0 wraps).
VC_NONE :: core_pkg.VC_NONE
VC_OBJECT :: core_pkg.VC_OBJECT // `{`
VC_ARRAY :: core_pkg.VC_ARRAY // `[`
VC_STRING :: core_pkg.VC_STRING // `"`
VC_LITERAL :: core_pkg.VC_LITERAL // `true`, `false` or `null`
VC_NUMBER :: core_pkg.VC_NUMBER // `-` or a digit

// JSON's faults within a neutral `Error_Kind`, carried in `Error.detail`.
Fault :: enum u8 {
	None,
	Literal, // `.Bad_Char`: a byte breaking `true`, `false`, `null`, or JSON5's `Infinity` or `NaN`
	Cut_Number, // `.Truncated`: a `.JSON_Seq` record that is a number alone, which RFC 7464 §2.4 holds may be cut short
	Record_Too_Long, // `.Limit_Format`: a record past `Record_Opts.max_record_bytes`, at its first byte
}

// The scanner's fault: core's two-word `Walk_Error`. A JSON fault is a kind past core's last arm, and
// `error_of` makes the `Error` callers see.
Scan_Error :: core_pkg.Walk_Error

// `.Bad_Char` with `Fault.Literal`, as a `Scan_Error` kind.
KIND_LITERAL :: Error_Kind(int(max(Error_Kind)) + 1)

// The `Error` of the scanner's fault `e`.
error_of :: proc(e: Scan_Error) -> Public_Error {
	if e.kind == KIND_LITERAL {
		return {offset = e.offset, kind = .Bad_Char, detail = u8(Fault.Literal)}
	}
	return {offset = e.offset, kind = e.kind}
}

// `error_of` a walk's result.
fault_of :: proc(m: Maybe(Scan_Error)) -> Maybe(Public_Error) {
	if e, bad := m.?; bad {
		return error_of(e)
	}
	return nil
}

// JSON's whitespace (RFC 8259 `ws`), which jq's lexer and the CLI share.
is_space :: #force_inline proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

// The index of the first byte of `src` at or past `pos` that is not `is_space`, or `len(src)`.
skip_space :: #force_inline proc(src: []byte, pos: int) -> int {
	i := pos
	for i < len(src) && is_space(src[i]) {
		i += 1
	}
	return i
}

// The end of `src[lo:hi]` with its trailing `is_space` bytes cut, never below `lo`.
skip_space_back :: #force_inline proc(src: []byte, lo, hi: int) -> int {
	i := hi
	for i > lo && is_space(src[i - 1]) {
		i -= 1
	}
	return i
}

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
	json5:     bool,   // keys are JSON5 tokens: an escaped one decodes by `json5_escape_unit`, unquoted or quoted
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
