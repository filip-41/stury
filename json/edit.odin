package json

// The path edits `set`, `insert`, `remove` and the span edit `splice`. The geometry is in edit_ops.odin and
// edit_jsonc.odin.

import "base:runtime"
import "core:mem"
import core_pkg "../core"
import "core:slice"

// One value-replacing edit: `src[lo:hi]` becomes `bytes`.
Edit :: struct {
	lo, hi: u64,
	bytes:  []u8,
}

// Why an edit was refused. Nothing was written and the source is unchanged.
Edit_Error_Kind :: enum u8 {
	Bad_Edit,      // an edit out of range, or edits unsorted or overlapping
	Bad_Path,      // the path text does not parse (`offset` is where in the text the parser stopped)
	Over_Capacity, // a fixed scan limit (`Capacity`) refused the path, as one past MAX_PATH_STEPS, or the source
	Not_Found,     // the path matched nothing
	Type_Mismatch, // `set`: the path found nothing, and every answer was a step meeting a value of another kind
	Bad_Source,    // the source is not valid JSON
	Bad_Result,    // the edited text, or the value's text, is not valid JSON (`offset` is into that text)
	Too_Deep,      // the value, nested where it lands, would pass MAX_DEPTH
	Encode,        // `marshal` refused the value
	Exists,        // `insert`: the object already has the member
	Bad_Comment,   // the comment text is not one `//` line or one `/* */` block
	Unplaceable,   // no place for the entry: `remove` of the root, `insert` into a value of the wrong kind or
	               // past an array's end, `set` with `upsert` on a path not ending in a name or below a non-object
	Out_Of_Memory, // the allocator refused
	Internal,      // a scan refusal no edit can produce: a bug in this package, not in the caller's request
}

// An edit's refusal, located as `Unmarshal_Error` is: `offset` and `syntax` are set for `.Bad_Source`,
// `.Bad_Result` and `.Bad_Path` (`syntax` for the first two only), `encode` for `.Encode`.
Edit_Error :: struct {
	kind:   Edit_Error_Kind,
	syntax: Error_Kind,   // the walk's result
	encode: Encode_Error, // marshal's refusal
	offset: u64,
}

// `src` with every edit applied.
//
//	- Edits must be sorted by `lo` and disjoint (`edits[i].hi <= edits[i+1].lo`, every `hi <= len(src)`).
//	- The result is validated `.Strict`, or as JSONC under `.Jsonc`, since an arbitrary span need not be a
//	  whole value.
//	- Under `.Jsonc` an edit whose bytes open a comment that runs on into source bytes it did not replace
//	  (an unterminated `//` or `/*`) is `.Bad_Result` at the comment, with no `syntax`: the comment would
//	  swallow the values there.
splice :: proc(src: []byte, edits: []Edit, allocator := context.allocator, dialect := Dialect.Json) -> (out: []byte, err: Maybe(Edit_Error)) {
	if !edits_ordered(src, edits) {
		return nil, Edit_Error{kind = .Bad_Edit}
	}
	applied, aerr := edits_apply(src, edits, allocator)
	if aerr != nil {
		return nil, aerr
	}
	if dialect == .Jsonc {
		err = judged_jsonc_splice(applied, edits, allocator)
		if err != nil {
			delete(applied, allocator)
			return nil, err
		}
		return applied, nil
	}
	return judged(applied, nil, allocator, dialect)
}

// `out` validated as `.Jsonc`, and `.Bad_Result` at any comment that an edit's bytes open and the source bytes
// after them close: it swallows what stood there, which the edit did not replace.
@(private = "file")
judged_jsonc_splice :: proc(out: []byte, edits: []Edit, allocator: runtime.Allocator) -> Maybe(Edit_Error) {
	facts, ferr := make([dynamic]Fact, allocator)
	if ferr != nil {
		return Edit_Error{kind = .Out_Of_Memory}
	}
	defer delete(facts)
	if e, bad := validate(out, .Jsonc, facts = &facts).?; bad {
		return Edit_Error{kind = e.kind == .Out_Of_Memory ? .Out_Of_Memory : .Bad_Result, syntax = e.kind, offset = e.offset}
	}
	// Each edit's bytes sit at `lo + shift` in `out`, the source's bytes between edits as they were.
	shift := 0
	for e in edits {
		from, to := int(e.lo) + shift, int(e.lo) + shift + len(e.bytes)
		shift += len(e.bytes) - int(e.hi - e.lo)
		for f in facts {
			if int(f.lo) >= from && int(f.lo) < to && int(f.hi) > to {
				for b in out[to:f.hi] {
					if !core_pkg.is_space(b) {
						return Edit_Error{kind = .Bad_Result, offset = f.lo}
					}
				}
			}
		}
	}
	return nil
}

// `out` validated as `dialect` reads it: a text that does not read is `.Bad_Result`, freed, never a silent
// misreading. An `err` passes through.
@(private)
judged :: proc(out: []byte, err: Maybe(Edit_Error), allocator: runtime.Allocator, dialect: Dialect) -> ([]byte, Maybe(Edit_Error)) {
	if err != nil {
		return nil, err
	}
	if e, bad := validate(out, dialect).?; bad {
		delete(out, allocator)
		return nil, Edit_Error{kind = .Bad_Result, syntax = e.kind, offset = e.offset}
	}
	return out, nil
}

// Replace every value the path finds with `value`, written canonically once.
//
//	- The source is scanned `.Strict` and duplicate keys resolve `.Last`.
//	- No re-validating: a strict source with whole values swapped for whole canonical values is still
//	  valid, and the depth guard covers the one thing the grammar does not.
//	- Every allocation, scratch included, is `allocator`'s, as in `insert` and `remove`.
//	- `upsert` also adds the member to each object the path's last name is missing from, as `insert`
//	  would. The path must then end in a name, and everything before it must find objects.
//	- A path that finds nothing is `.Not_Found`, or `.Type_Mismatch` when every answer was a step meeting
//	  a value of another kind (a name on an array).
//	- `.Jsonc` reads the source as JSONC. A member it adds goes after the last entry's comments.
//	- Every path edit takes the path as text or as a parsed `Path` (`Path_Spec`). Text that does not parse
//	  is `.Bad_Path` at the byte the parser stopped on.
set :: proc(src: []byte, path: Path_Spec, value: any, allocator := context.allocator, upsert := false, dialect := Dialect.Json) -> (out: []byte, err: Maybe(Edit_Error)) {
	watch := Refusal_Watch{backing = allocator}
	out, err = watched_set(src, path, value, watched(&watch), upsert, dialect)
	return unless_refused(&watch, out, err)
}

@(private = "file")
watched_set :: proc(src: []byte, path: Path_Spec, value: any, allocator: runtime.Allocator, upsert: bool, dialect: Dialect) -> (out: []byte, err: Maybe(Edit_Error)) {
	steps: [core_pkg.MAX_PATH_STEPS]Step
	p, names := edit_parse(path, steps[:], allocator) or_return
	defer delete(names, allocator)
	// The target sits inside one container per step.
	repl := canonical(value, len(p.steps), allocator, dialect) or_return
	defer delete(repl)
	if upsert {
		// The member the path names, inserted into or replaced in each object its container steps find.
		n := len(p.steps)
		name: Name
		named := false
		if n > 0 {
			name, named = p.steps[n - 1].(Name)
		}
		if !named {
			return nil, Edit_Error{kind = .Unplaceable}
		}
		if p.limit != 0 {
			return nil, Edit_Error{kind = .Bad_Path}
		}
		return insert_at(src, {steps = p.steps[:n - 1]}, string(name), repl[:], allocator, dialect, upsert = true)
	}
	paths := [1]Path{p}
	req: Request({.Path})
	defer request_destroy(&req)
	edit_scan(src, &req, paths[:], dialect, allocator) or_return
	edits := make([dynamic]Edit, 0, len(req.answers), allocator)
	defer delete(edits)
	mismatched := 0
	for a in req.answers {
		if a.outcome == .Found {
			append(&edits, Edit{lo = a.lo, hi = a.hi, bytes = repl[:]})
		} else if a.outcome == .Type_Mismatch {
			mismatched += 1
		}
	}
	if len(edits) == 0 {
		return nil, Edit_Error{kind = .Type_Mismatch if mismatched == len(req.answers) && mismatched > 0 else .Not_Found}
	}
	// Every answer sits at the path's depth, so answers never nest, and sorted they are disjoint.
	slice.sort_by(edits[:], proc(a, b: Edit) -> bool {
		return a.lo < b.lo
	})
	return edits_apply(src, edits[:], allocator)
}

// Where `insert` puts its entry: a member name for an object, an element index for an array. An index
// counts from the end when negative, as `child`'s does: `-1` places the entry before the last element, and
// `APPEND` after it, whatever the length.
Insert_At :: union #no_nil {
	string,
	int,
}

// An `Insert_At` past an array's last element, whatever its length.
APPEND :: max(int)

// Add `value`, written canonically once, to every container the path finds: as member `at` of an object,
// after its last member, or as element `at` of an array.
//
//	- The entry copies the separator between its neighbours and a member's key-to-value bytes, so pretty
//	  input stays pretty. A lone entry's separator is a comma and the whitespace before that entry, and an
//	  empty container takes the entry compact, before its close.
//	- A member the object already has is `.Exists` (`set` with `upsert` replaces it).
//	- An index past either end, a name for an array, or neighbours with more than whitespace and a comma
//	  between them, is `.Unplaceable`.
//	- Duplicate keys resolve `.Last`.
//	- `.Jsonc` reads the source as JSONC and places the entry between its neighbours' extents, each entry's
//	  comments and comma included (`entry_at`). The result is validated as JSONC.
insert :: proc(src: []byte, path: Path_Spec, at: Insert_At, value: any, allocator := context.allocator, dialect := Dialect.Json) -> (out: []byte, err: Maybe(Edit_Error)) {
	watch := Refusal_Watch{backing = allocator}
	out, err = watched_insert(src, path, at, value, watched(&watch), dialect)
	return unless_refused(&watch, out, err)
}

@(private = "file")
watched_insert :: proc(src: []byte, path: Path_Spec, at: Insert_At, value: any, allocator: runtime.Allocator, dialect: Dialect) -> (out: []byte, err: Maybe(Edit_Error)) {
	steps: [core_pkg.MAX_PATH_STEPS]Step
	p, names := edit_parse(path, steps[:], allocator) or_return
	defer delete(names, allocator)
	repl := canonical(value, len(p.steps) + 1, allocator, dialect) or_return
	defer delete(repl)
	return insert_at(src, p, at, repl[:], allocator, dialect)
}

// Remove every value the path finds, with its member key, and exactly one separator beside it: the one
// after it, or before it for a container's last entries.
//
//	- Removing every entry leaves the container empty, `{}` or `[]`.
//	- Duplicate keys resolve `.All`, so after a `remove` the path finds nothing.
//	- The root is `.Unplaceable`.
//	- `.Jsonc` reads the source as JSONC and removes each entry with the comments attached to it
//	  (`remove_in`). The result is validated as JSONC.
remove :: proc(src: []byte, path: Path_Spec, allocator := context.allocator, dialect := Dialect.Json) -> (out: []byte, err: Maybe(Edit_Error)) {
	watch := Refusal_Watch{backing = allocator}
	out, err = watched_remove(src, path, watched(&watch), dialect)
	return unless_refused(&watch, out, err)
}

@(private = "file")
watched_remove :: proc(src: []byte, path: Path_Spec, allocator: runtime.Allocator, dialect: Dialect) -> (out: []byte, err: Maybe(Edit_Error)) {
	steps: [core_pkg.MAX_PATH_STEPS]Step
	p, names := edit_parse(path, steps[:], allocator) or_return
	defer delete(names, allocator)
	n := len(p.steps)
	if n == 0 {
		return nil, Edit_Error{kind = .Unplaceable}
	}
	if dialect == .Jsonc {
		return remove_in(src, p, allocator, true)
	}
	return remove_in(src, p, allocator, false)
}

// `value`'s canonical text, a `Raw` in it validated under `dialect`, refused past the depth left below `depth`
// enclosing containers.
@(private)
canonical :: proc(value: any, depth: int, allocator: runtime.Allocator, dialect: Dialect) -> (repl: [dynamic]u8, err: Maybe(Edit_Error)) {
	repl = make([dynamic]u8, allocator)
	// Validating a JSONC `Raw` lists its comments, scratch the edit's like every other. The caller's
	// allocator is back in place on every return.
	prev := context.allocator
	context.allocator = allocator
	defer context.allocator = prev
	if merr := marshal_append(&repl, value, {}, nil, nil, dialect); merr != .None {
		delete(repl)
		return nil, Edit_Error{kind = .Encode, encode = merr}
	}
	if e, bad := validate(repl[:], dialect, limits = Limits{max_depth = u64(max(MAX_DEPTH - depth, 0))}).?; bad {
		delete(repl)
		if e.kind == .Too_Deep {
			return nil, Edit_Error{kind = .Too_Deep}
		}
		return nil, Edit_Error{kind = .Bad_Result, syntax = e.kind, offset = e.offset}
	}
	return repl, nil
}

// The steps of `path`: a `Path` as it is, text parsed into `steps` with its escaped names decoded into
// `names`, which the caller frees with `allocator`. On a refusal nothing is kept. A `Path` past
// `MAX_PATH_STEPS` is refused here, before an edit extends it by a step.
@(private)
edit_parse :: proc(path: Path_Spec, steps: []Step, allocator: runtime.Allocator) -> (p: Path, names: []u8, err: Maybe(Edit_Error)) {
	text, is_text := path.(string)
	if !is_text {
		if p = path.(Path); len(p.steps) > core_pkg.MAX_PATH_STEPS {
			return {}, nil, Edit_Error{kind = .Over_Capacity}
		}
		return p, nil, nil
	}
	aerr: runtime.Allocator_Error
	if names, aerr = make([]u8, len(text), allocator); aerr != nil {
		return {}, nil, Edit_Error{kind = .Out_Of_Memory}
	}
	perr: Maybe(Parse_Fault)
	if p, perr = parse_path(text, steps, names); perr != nil {
		delete(names, allocator)
		// `names` holds every escaped name, so a buffer too small is the steps: a path past the bound.
		if perr.?.error == .Out_Of_Room {
			return {}, nil, Edit_Error{kind = .Over_Capacity}
		}
		return {}, nil, Edit_Error{kind = .Bad_Path, offset = perr.?.offset}
	}
	return
}

// The `.Strict` scan for `paths` every path edit starts from, its refusals and faults as edit errors.
@(private)
edit_scan :: proc(src: []byte, req: ^Request($Q), paths: []Path, dialect: Dialect, allocator: runtime.Allocator) -> Maybe(Edit_Error) {
	req.paths = paths
	req.dialect = dialect
	req.strictness = .Strict
	req.allocator = allocator
	switch e in scan(src, req) {
	case Error:
		if e.kind == .Out_Of_Memory {
			return Edit_Error{kind = .Out_Of_Memory}
		}
		return Edit_Error{kind = .Bad_Source, syntax = e.kind, offset = e.offset}
	case Request_Error:
		#partial switch e.kind {
		case .Out_Of_Memory:
			return Edit_Error{kind = .Out_Of_Memory}
		case .Over_Capacity:
			return Edit_Error{kind = .Over_Capacity}
		case:
			// Unreachable, as the edits build their own requests. An error beats a panic in the caller.
			return Edit_Error{kind = .Internal}
		}
	}
	return nil
}

// `base` and one more step, in `buf`.
@(private)
extend :: proc(buf: []Step, base: []Step, last: Step) -> Path {
	copy(buf, base)
	buf[len(base)] = last
	return {steps = buf[:len(base) + 1]}
}

// The `Found` answers of path `q`, in document order. Answers at one depth never nest, so a container's
// entries are contiguous.
@(private)
found :: proc(answers: []Path_Answer, q: u32, allocator: runtime.Allocator) -> [dynamic]Path_Answer {
	out := make([dynamic]Path_Answer, allocator)
	for a in answers {
		if a.query == q && a.outcome == .Found {
			append(&out, a)
		}
	}
	slice.sort_by(out[:], proc(a, b: Path_Answer) -> bool {
		return a.lo < b.lo
	})
	return out
}

// The answers in `rows` held by the container starting at `owner`, from cursor `at` on. Containers come in
// document order and never nest.
@(private)
held_by :: proc(rows: []Path_Answer, at: ^int, owner: u64) -> []Path_Answer {
	for at^ < len(rows) && rows[at^].lo < owner {
		at^ += 1
	}
	from := at^
	for at^ < len(rows) && rows[at^].owner == owner {
		at^ += 1
	}
	return rows[from:at^]
}

// One edit whose bytes live in a shared text buffer: `src[at:cut]` becomes `text[from:to]`.
@(private)
Place :: struct {
	at, cut:  u64,
	from, to: int,
}

@(private)
places_apply :: proc(src: []byte, places: []Place, text: []u8, allocator: runtime.Allocator) -> (out: []byte, err: Maybe(Edit_Error)) {
	if len(places) == 0 {
		return nil, Edit_Error{kind = .Not_Found}
	}
	edits, aerr := make([]Edit, len(places), allocator)
	if aerr != nil {
		return nil, Edit_Error{kind = .Out_Of_Memory}
	}
	defer delete(edits, allocator)
	for p, i in places {
		edits[i] = {lo = p.at, hi = p.cut, bytes = text[p.from:p.to]}
	}
	return edits_apply(src, edits, allocator)
}

// The allocator of a path edit: `backing`, remembering a refusal, so that an edit whose scratch lost an
// entry to one answers `.Out_Of_Memory` (`unless_refused`) rather than a result missing an edit.
@(private)
Refusal_Watch :: struct {
	backing: runtime.Allocator,
	refused: bool,
}

@(private)
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

// The edit's answer, or `.Out_Of_Memory` with `out` freed when the watch saw a refusal.
@(private)
unless_refused :: proc(w: ^Refusal_Watch, out: []byte, err: Maybe(Edit_Error)) -> ([]byte, Maybe(Edit_Error)) {
	if w.refused {
		delete(out, w.backing)
		return nil, Edit_Error{kind = .Out_Of_Memory}
	}
	return out, err
}

// Whether `edits` are sorted by `lo`, disjoint, and inside `src`.
@(private)
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

// `src` with sorted, disjoint edits applied: one copy per gap and one per replacement into an exact,
// uninitialized allocation.
@(private)
edits_apply :: proc(src: []byte, edits: []Edit, allocator: runtime.Allocator) -> (out: []byte, err: Maybe(Edit_Error)) {
	n := len(src)
	for e in edits {
		n += len(e.bytes) - int(e.hi - e.lo)
	}
	buf, aerr := mem.alloc_bytes_non_zeroed(n, allocator = allocator)
	if aerr != nil {
		return nil, Edit_Error{kind = .Out_Of_Memory}
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
