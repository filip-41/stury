package core

// The parts of text editing shared by every codec: the byte-span edit, its ordering rule, its application, an
// allocator wrapper that distinguishes a refused allocation from an edit that found nothing, and the driver of
// the path edits (`path_edit`) over a format's `Edits`.

import "base:runtime"
import "core:mem"
import "core:slice"

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

// A path edit's verb, with what it writes: `value` for all but `.Remove`, `at` for `.Insert`.
Edit_Op :: enum u8 {
	Set,
	// `.Set`, and the member added to each object the path's last name is missing from.
	Upsert,
	Insert,
	Remove,
}

Edit_Args :: struct {
	op:    Edit_Op,
	value: any,
	at:    Insert_At,
}

// One edit whose bytes live in a shared text buffer: `src[at:cut]` becomes `text[from:to]`.
Place :: struct {
	at, cut:  u64,
	from, to: int,
}

// A format's half of the path edits (`path_edit`) and its span edit. `shared` and `own`, the format's options
// block, are the format's read options, as every capability takes them.
Edits :: struct {
	// The edits `args` makes at `p` in `src`, appended to `places` with their bytes in `text`. Places need not
	// be sorted; each must be disjoint from the others. Scratch comes from `allocator`.
	plan:     proc(src: []byte, p: Path, args: Edit_Args, shared: Read_Opts, own: rawptr, text: ^[dynamic]u8, places: ^[dynamic]Place, allocator: runtime.Allocator) -> Maybe(Path_Error),
	// The edited text `out` of `src` judged: nil when it reads as the format reads its source.
	judge:    proc(src, out: []byte, op: Edit_Op, shared: Read_Opts, own: rawptr, allocator: runtime.Allocator) -> Maybe(Path_Error),
	// What a path past `MAX_PATH_STEPS` steps is refused as.
	too_long: Path_Error_Kind,
}

// `src` with the path edit `args` at `path` made through `e`: the path resolved, the format's places applied
// once, and the result judged. Every allocation, scratch included, is `allocator`'s; a refused one is
// `.Out_Of_Memory` rather than a result missing an edit.
@(require_results)
path_edit :: proc(e: Edits, src: []byte, path: Path_Spec, args: Edit_Args, shared: Read_Opts, own: rawptr, allocator: runtime.Allocator) -> (out: []byte, err: Maybe(Path_Error)) {
	watch := Refusal_Watch{backing = allocator}
	out, err = path_edit_watched(e, src, path, args, shared, own, watched(&watch))
	return unless_refused(&watch, out, err, PATH_OUT_OF_MEMORY)
}

@(private = "file")
path_edit_watched :: proc(e: Edits, src: []byte, path: Path_Spec, args: Edit_Args, shared: Read_Opts, own: rawptr, allocator: runtime.Allocator) -> (out: []byte, err: Maybe(Path_Error)) {
	buf: Path_Buf
	p, perr := path_resolve(path, &buf, allocator)
	defer delete(buf.heap, allocator)
	if fault, bad := perr.?; bad {
		if fault.kind == .Over_Capacity {
			fault.kind = e.too_long
		}
		return nil, fault
	}
	text := make([dynamic]u8, allocator)
	defer delete(text)
	places := make([dynamic]Place, allocator)
	defer delete(places)
	e.plan(src, p, args, shared, own, &text, &places, allocator) or_return
	out = places_apply(src, places[:], text[:], allocator) or_return
	if fault := e.judge(src, out, args.op, shared, own, allocator); fault != nil {
		delete(out, allocator)
		return nil, fault
	}
	return out, nil
}

// `places` sorted and applied to `src`, their bytes from `text`; places at one byte keep their order. None is
// `.Not_Found`; an overlap `.Bad_Edit`.
places_apply :: proc(src: []byte, places: []Place, text: []u8, allocator: runtime.Allocator) -> (out: []byte, err: Maybe(Path_Error)) {
	edit_found(len(places)) or_return
	slice.stable_sort_by(places, proc(a, b: Place) -> bool {
		return a.at < b.at
	})
	edits, aerr := make([]Edit, len(places), allocator)
	if aerr != nil {
		return nil, PATH_OUT_OF_MEMORY
	}
	defer delete(edits, allocator)
	for p, i in places {
		edits[i] = {lo = p.at, hi = p.cut, bytes = text[p.from:p.to]}
	}
	return edits_apply_checked(src, edits, allocator)
}
