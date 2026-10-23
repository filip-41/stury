package json

// The path edits `set`, `insert`, `remove` and the span edit `splice`. The geometry is in edit_ops.odin and
// edit_jsonc.odin.

import "base:runtime"
import core_pkg "../core"
import "scan/walk"
import "core:slice"

// One value-replacing edit: `src[lo:hi]` becomes `bytes`.
Edit :: core_pkg.Edit

// The reason a path edit was refused. The kinds are core's and shared with CSV. JSON never reports
// `Unsupported_Path`, `Bad_Option` or `Bad_Row`.
Path_Error_Kind :: core_pkg.Path_Error_Kind

// A refused edit, located as an `Unmarshal_Error` is. `offset` and `syntax` are set for `.Bad_Source` and
// `.Bad_Result` (`syntax` may stay `.None` there), `offset` alone for `.Bad_Path`, and `encode` for `.Encode`.
// Both JSON's and CSV's `render_error` write it.
Path_Error :: core_pkg.Path_Error

// `src` with every edit applied.
//
//	- Edits must be sorted by `lo` and disjoint (`edits[i].hi <= edits[i+1].lo`, every `hi <= len(src)`).
//	- The result is validated `.Strict`, or as JSONC under `.Jsonc`, since an arbitrary span need not be a
//	  whole value.
//	- Under `.Jsonc` an edit whose bytes open a comment that runs on into source bytes it did not replace
//	  (an unterminated `//` or `/*`) is `.Bad_Result` at the comment, with no `syntax`: the comment would
//	  swallow the values there.
@(require_results)
splice :: proc(src: []byte, edits: []Edit, allocator := context.allocator, dialect := Dialect.Json) -> (out: []byte, err: Maybe(Path_Error)) {
	if !core_pkg.edits_ordered(src, edits) {
		return nil, Path_Error{kind = .Bad_Edit}
	}
	applied, aerr := core_pkg.edits_apply(src, edits, allocator, core_pkg.PATH_OUT_OF_MEMORY)
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
judged_jsonc_splice :: proc(out: []byte, edits: []Edit, allocator: runtime.Allocator) -> Maybe(Path_Error) {
	facts, ferr := make([dynamic]Fact, allocator)
	if ferr != nil {
		return core_pkg.PATH_OUT_OF_MEMORY
	}
	defer delete(facts)
	if e, bad := validate(out, .Jsonc, facts = &facts).?; bad {
		return Path_Error{kind = e.kind == .Out_Of_Memory ? .Out_Of_Memory : .Bad_Result, syntax = e.kind, offset = e.offset}
	}
	// Each edit's bytes sit at `lo + shift` in `out`, the source's bytes between edits as they were.
	shift := 0
	for e in edits {
		from, to := int(e.lo) + shift, int(e.lo) + shift + len(e.bytes)
		shift += len(e.bytes) - int(e.hi - e.lo)
		for f in facts {
			if int(f.lo) >= from && int(f.lo) < to && int(f.hi) > to {
				for b in out[to:f.hi] {
					if !walk.is_space(b) {
						return Path_Error{kind = .Bad_Result, offset = f.lo}
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
judged :: proc(out: []byte, err: Maybe(Path_Error), allocator: runtime.Allocator, dialect: Dialect) -> ([]byte, Maybe(Path_Error)) {
	if err != nil {
		return nil, err
	}
	if e, bad := validate(out, dialect).?; bad {
		delete(out, allocator)
		return nil, Path_Error{kind = .Bad_Result, syntax = e.kind, offset = e.offset}
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
@(require_results)
set :: proc(src: []byte, path: Path_Spec, value: any, allocator := context.allocator, upsert := false, dialect := Dialect.Json) -> (out: []byte, err: Maybe(Path_Error)) {
	watch := core_pkg.Refusal_Watch{backing = allocator}
	out, err = watched_set(src, path, value, core_pkg.watched(&watch), upsert, dialect)
	return core_pkg.unless_refused(&watch, out, err, core_pkg.PATH_OUT_OF_MEMORY)
}

@(private = "file")
watched_set :: proc(src: []byte, path: Path_Spec, value: any, allocator: runtime.Allocator, upsert: bool, dialect: Dialect) -> (out: []byte, err: Maybe(Path_Error)) {
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
			return nil, Path_Error{kind = .Unplaceable}
		}
		if p.limit != 0 {
			return nil, Path_Error{kind = .Bad_Path}
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
		return nil, Path_Error{kind = .Type_Mismatch if mismatched == len(req.answers) && mismatched > 0 else .Not_Found}
	}
	// Every answer sits at the path's depth, so answers never nest, and sorted they are disjoint.
	slice.sort_by(edits[:], proc(a, b: Edit) -> bool {
		return a.lo < b.lo
	})
	return core_pkg.edits_apply(src, edits[:], allocator, core_pkg.PATH_OUT_OF_MEMORY)
}

// Where `insert` puts its entry: a member name for an object, an element index for an array. An index
// counts from the end when negative, as `child`'s does: `-1` places the entry before the last element, and
// `APPEND` after it, whatever the length.
Insert_At :: union #no_nil {
	string,
	int,
}

// An `Insert_At` past an array's last element, whatever its length.
APPEND :: core_pkg.APPEND

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
@(require_results)
insert :: proc(src: []byte, path: Path_Spec, at: Insert_At, value: any, allocator := context.allocator, dialect := Dialect.Json) -> (out: []byte, err: Maybe(Path_Error)) {
	watch := core_pkg.Refusal_Watch{backing = allocator}
	out, err = watched_insert(src, path, at, value, core_pkg.watched(&watch), dialect)
	return core_pkg.unless_refused(&watch, out, err, core_pkg.PATH_OUT_OF_MEMORY)
}

@(private = "file")
watched_insert :: proc(src: []byte, path: Path_Spec, at: Insert_At, value: any, allocator: runtime.Allocator, dialect: Dialect) -> (out: []byte, err: Maybe(Path_Error)) {
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
@(require_results)
remove :: proc(src: []byte, path: Path_Spec, allocator := context.allocator, dialect := Dialect.Json) -> (out: []byte, err: Maybe(Path_Error)) {
	watch := core_pkg.Refusal_Watch{backing = allocator}
	out, err = watched_remove(src, path, core_pkg.watched(&watch), dialect)
	return core_pkg.unless_refused(&watch, out, err, core_pkg.PATH_OUT_OF_MEMORY)
}

@(private = "file")
watched_remove :: proc(src: []byte, path: Path_Spec, allocator: runtime.Allocator, dialect: Dialect) -> (out: []byte, err: Maybe(Path_Error)) {
	steps: [core_pkg.MAX_PATH_STEPS]Step
	p, names := edit_parse(path, steps[:], allocator) or_return
	defer delete(names, allocator)
	n := len(p.steps)
	if n == 0 {
		return nil, Path_Error{kind = .Unplaceable}
	}
	if dialect == .Jsonc {
		return remove_in(src, p, allocator, true)
	}
	return remove_in(src, p, allocator, false)
}

// `value`'s canonical text, a `Raw` in it validated under `dialect`, refused past the depth left below `depth`
// enclosing containers.
@(private)
canonical :: proc(value: any, depth: int, allocator: runtime.Allocator, dialect: Dialect) -> (repl: [dynamic]u8, err: Maybe(Path_Error)) {
	repl = make([dynamic]u8, allocator)
	// Validating a JSONC `Raw` lists its comments, scratch the edit's like every other. The caller's
	// allocator is back in place on every return.
	prev := context.allocator
	context.allocator = allocator
	defer context.allocator = prev
	if merr := marshal_append(&repl, value, {}, nil, nil, dialect); merr != .None {
		delete(repl)
		return nil, Path_Error{kind = .Encode, encode = merr}
	}
	if e, bad := validate(repl[:], dialect, limits = Limits{max_depth = u64(max(MAX_DEPTH - depth, 0))}).?; bad {
		delete(repl)
		if e.kind == .Too_Deep {
			return nil, Path_Error{kind = .Too_Deep}
		}
		return nil, Path_Error{kind = .Bad_Result, syntax = e.kind, offset = e.offset}
	}
	return repl, nil
}

// The steps of `path`: a `Path` as it is, text parsed into `steps` with its escaped names decoded into
// `names`, which the caller frees with `allocator`. On a refusal nothing is kept. A `Path` past
// `MAX_PATH_STEPS` is refused here, before an edit extends it by a step.
@(private)
edit_parse :: proc(path: Path_Spec, steps: []Step, allocator: runtime.Allocator) -> (p: Path, names: []u8, err: Maybe(Path_Error)) {
	text, is_text := path.(string)
	if !is_text {
		if p = path.(Path); len(p.steps) > core_pkg.MAX_PATH_STEPS {
			return {}, nil, Path_Error{kind = .Over_Capacity}
		}
		return p, nil, nil
	}
	aerr: runtime.Allocator_Error
	if names, aerr = make([]u8, len(text), allocator); aerr != nil {
		return {}, nil, core_pkg.PATH_OUT_OF_MEMORY
	}
	perr: Maybe(Parse_Fault)
	if p, perr = parse_path(text, steps, names); perr != nil {
		delete(names, allocator)
		// `names` holds every escaped name, so a buffer too small is the steps: a path past the bound.
		if perr.?.error == .Out_Of_Room {
			return {}, nil, Path_Error{kind = .Over_Capacity}
		}
		return {}, nil, Path_Error{kind = .Bad_Path, offset = perr.?.offset}
	}
	return
}

// The `.Strict` scan for `paths` every path edit starts from, its refusals and faults as edit errors.
@(private)
edit_scan :: proc(src: []byte, req: ^Request($KINDS), paths: []Path, dialect: Dialect, allocator: runtime.Allocator) -> Maybe(Path_Error) {
	req.paths = paths
	req.dialect = dialect
	req.strictness = .Strict
	req.allocator = allocator
	switch e in scan(src, req) {
	case Error:
		if e.kind == .Out_Of_Memory {
			return core_pkg.PATH_OUT_OF_MEMORY
		}
		return Path_Error{kind = .Bad_Source, syntax = e.kind, offset = e.offset}
	case Request_Error:
		#partial switch e.kind {
		case .Out_Of_Memory:
			return core_pkg.PATH_OUT_OF_MEMORY
		case .Over_Capacity:
			return Path_Error{kind = .Over_Capacity}
		case:
			// Unreachable, as the edits build their own requests. An error beats a panic in the caller.
			return Path_Error{kind = .Internal}
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
places_apply :: proc(src: []byte, places: []Place, text: []u8, allocator: runtime.Allocator) -> (out: []byte, err: Maybe(Path_Error)) {
	if len(places) == 0 {
		return nil, Path_Error{kind = .Not_Found}
	}
	edits, aerr := make([]Edit, len(places), allocator)
	if aerr != nil {
		return nil, core_pkg.PATH_OUT_OF_MEMORY
	}
	defer delete(edits, allocator)
	for p, i in places {
		edits[i] = {lo = p.at, hi = p.cut, bytes = text[p.from:p.to]}
	}
	return core_pkg.edits_apply(src, edits, allocator, core_pkg.PATH_OUT_OF_MEMORY)
}
