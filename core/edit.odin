package core

// The parts of text editing shared by every codec: the byte-span edit, its ordering rule, its application, and
// an allocator wrapper that distinguishes a refused allocation from an edit that found nothing.

import "base:runtime"
import "core:mem"

// One edit: `src[lo:hi]` is replaced by `bytes`.
Edit :: struct {
	lo, hi: u64,
	bytes:  []u8,
}

// Where `insert` puts its entry: a member name for an object, an entry index for an array (a CSV text's
// records are one), `APPEND` after the last entry whatever the count. JSON counts a negative index from the end
// (`-1` places the entry before the last one); CSV refuses it and a name.
Insert_At :: union #no_nil {
	string,
	int,
}

// An `Insert_At` after the last entry, whatever the count.
APPEND :: max(int)

// Whether `edits` are sorted by `lo`, disjoint, and inside `src`.
edits_ordered :: proc(src: []byte, edits: []Edit) -> bool {
	at: u64
	for e in edits {
		if e.lo < at || e.hi < e.lo || e.hi > u64(len(src)) {
			return false
		}
		at = e.hi
	}
	return true
}

// Returns `src` with sorted, disjoint edits applied, built with one copy per gap and one per replacement into an
// exact, uninitialized allocation. Returns `oom` when the allocation is refused.
edits_apply :: proc(src: []byte, edits: []Edit, allocator: runtime.Allocator, oom: $E) -> (out: []byte, err: Maybe(E)) {
	n := len(src)
	for e in edits {
		n += len(e.bytes) - int(e.hi - e.lo)
	}
	buf, aerr := mem.alloc_bytes_non_zeroed(n, allocator = allocator)
	if aerr != nil {
		return nil, oom
	}
	w := 0
	at: u64
	for e in edits {
		w += copy(buf[w:], src[at:e.lo])
		w += copy(buf[w:], e.bytes)
		at = e.hi
	}
	copy(buf[w:], src[at:])
	return buf, nil
}

// `edits_apply` behind `edits_ordered`: a list a scan or a placement bug left unordered is `.Bad_Edit` rather
// than a panic in `edits_apply`'s `src[at:e.lo]`.
edits_apply_checked :: proc(src: []byte, edits: []Edit, allocator: runtime.Allocator) -> (out: []byte, err: Maybe(Path_Error)) {
	if !edits_ordered(src, edits) {
		return nil, Path_Error{kind = .Bad_Edit}
	}
	return edits_apply(src, edits, allocator, PATH_OUT_OF_MEMORY)
}

// An edited text `out` as its validation `fault` judged it: `out` when it reads, else freed and `.Bad_Result`.
judged_result :: proc(out: []byte, fault: Maybe(Error), allocator: runtime.Allocator) -> ([]byte, Maybe(Path_Error)) {
	if e, bad := fault.?; bad {
		delete(out, allocator)
		return nil, path_error_of(e, .Bad_Result)
	}
	return out, nil
}

// Nil when a path edit found `found` targets, else `.Not_Found`, or `.Type_Mismatch` when every one of its
// `answered` answers was a step meeting a value of another kind (`mismatched`).
edit_found :: proc(found: int, mismatched := 0, answered := 0) -> Maybe(Path_Error) {
	if found > 0 {
		return nil
	}
	return Path_Error{kind = .Type_Mismatch if mismatched == answered && mismatched > 0 else .Not_Found}
}

// Refusal_Watch wraps a path edit's allocator `backing` and records any refusal. An edit whose scratch lost an
// entry to a refusal then returns out of memory (`unless_refused`) instead of a result missing an edit.
Refusal_Watch :: struct {
	backing: runtime.Allocator,
	refused: bool,
}

watched :: proc(w: ^Refusal_Watch) -> runtime.Allocator {
	return {watch_proc, w}
}

@(private = "file")
watch_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	w := (^Refusal_Watch)(data)
	out, err := w.backing.procedure(w.backing.data, mode, size, alignment, old_memory, old_size, loc)
	if err == .Out_Of_Memory {
		w.refused = true
	}
	return out, err
}

// Returns the edit's result, or frees `out` and returns `oom` when the watch recorded a refusal.
unless_refused :: proc(w: ^Refusal_Watch, out: []byte, err: Maybe($E), oom: E) -> ([]byte, Maybe(E)) {
	if w.refused {
		delete(out, w.backing)
		return nil, oom
	}
	return out, err
}

// The capabilities every format package gives, one procedure type each over the format's own read options,
// record iterator, record, document and request. A format's suite fills one with its procedures, so a signature
// that drifts from these fails the build.
Format :: struct($Opts, $Records, $Record, $Document, $Request: typeid) {
	validate:         proc(src: []byte, opts: Opts, runner: ^Batch_Runner) -> Maybe(Error),
	records:          proc(src: []byte, opts: Opts, allocator: runtime.Allocator) -> Records,
	next_record:      proc(it: ^Records) -> (Record, bool),
	each_record:      proc(src: []byte, task: proc(data: rawptr, piece: ^Records, k: int) -> bool, data: rawptr, opts: Opts, runner: ^Batch_Runner) -> Maybe(Error),
	validate_records: proc(src: []byte, opts: Opts, runner: ^Batch_Runner, allocator: runtime.Allocator) -> ([]Record_Fault, Maybe(Error)),
	find:             proc(src: []byte, path: Path_Spec, opts: Opts, allocator: runtime.Allocator) -> (Answer, Maybe(Error)),
	build:            proc(src: []byte, opts: Opts, allocator: runtime.Allocator) -> (Document, Maybe(Error)),
	query:            proc(doc: ^Document, path: Path_Spec, out: ^[dynamic]Answer) -> Maybe(Path_Error),
	set:              proc(src: []byte, path: Path_Spec, value: any, opts: Opts, allocator: runtime.Allocator) -> ([]byte, Maybe(Path_Error)),
	insert:           proc(src: []byte, path: Path_Spec, at: Insert_At, value: any, opts: Opts, allocator: runtime.Allocator) -> ([]byte, Maybe(Path_Error)),
	remove:           proc(src: []byte, path: Path_Spec, opts: Opts, allocator: runtime.Allocator) -> ([]byte, Maybe(Path_Error)),
	splice:           proc(src: []byte, edits: []Edit, opts: Opts, allocator: runtime.Allocator) -> ([]byte, Maybe(Path_Error)),
	request_init:     proc(req: ^Request, paths: ..Path_Spec, opts := Opts{}, allocator := context.allocator) -> Maybe(Error),
	scan:             proc(src: []byte, req: ^Request) -> Maybe(Error),
	answers:          proc(req: ^Request, path: int) -> ([]Answer, Maybe(Error)),
	route_of:         proc(src: []byte, paths: []Path, which: int, opts: Opts) -> (Route, Maybe(Error)),
}
