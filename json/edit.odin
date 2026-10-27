package json

// The path edits `set`, `upsert`, `insert`, `remove` and the span edit `splice`. The geometry is in edit_ops.odin
// and edit_jsonc.odin.

import "base:runtime"
import core_pkg "../core"
import scan_pkg "scan"
import "scan/walk"
import "core:slice"

// One value-replacing edit: `src[lo:hi]` becomes `bytes`.
Edit :: core_pkg.Edit

// The reason a path edit was refused. The kinds are core's and shared with CSV. JSON never reports
// `Unsupported_Path` or `Bad_Row`, and reports `Bad_Option` only for a dialect the edits do not take (`.Json5`).
Path_Error_Kind :: core_pkg.Path_Error_Kind

// A refused edit, located as an `Unmarshal_Error` is. `offset` and `syntax` are set for `.Bad_Source` and
// `.Bad_Result` (`syntax` may stay `.None` there), `offset` alone for `.Bad_Path`, and `encode` for `.Encode`.
// Both JSON's and CSV's `render_error` write it.
Path_Error :: core_pkg.Path_Error

// `.Bad_Option` for a dialect the edits do not read.
@(private)
edit_refused :: proc(dialect: Dialect) -> Maybe(Path_Error) {
	if !scan_pkg.edits_read(dialect) {
		return Path_Error{kind = .Bad_Option}
	}
	return nil
}

// `src` with every edit applied.
//
//	- Edits must be sorted by `lo` and disjoint (`edits[i].hi <= edits[i+1].lo`, every `hi <= len(src)`).
//	- The result is validated `.Strict`, or as JSONC under `.Jsonc`, since an arbitrary span need not be a
//	  whole value. Of `opts`, only `dialect` is read.
//	- `.Json5` has no edits yet: `.Bad_Option` (also `set`, `upsert`, `insert` and `remove`).
//	- Under `.Jsonc` an edit whose bytes open a comment that runs on into source bytes it did not replace
//	  (an unterminated `//` or `/*`) is `.Bad_Result` at the comment, with no `syntax`: the comment would
//	  swallow the values there.
@(require_results)
splice :: proc(src: []byte, edits: []Edit, opts := Read_Opts{}, allocator := context.allocator) -> (out: []byte, err: Maybe(Path_Error)) {
	dialect := opts.dialect
	edit_refused(dialect) or_return
	applied, aerr := core_pkg.edits_apply_checked(src, edits, allocator)
	if aerr != nil {
		return nil, aerr
	}
	if scan_pkg.has_comments(dialect) {
		err = judged_jsonc_splice(applied, edits, allocator, dialect)
		if err != nil {
			delete(applied, allocator)
			return nil, err
		}
		return applied, nil
	}
	return judged(applied, nil, allocator, dialect)
}

// `out` validated as `dialect`, which reads comments, and `.Bad_Result` at any comment that an edit's bytes open and the source bytes
// after them close: it swallows what stood there, which the edit did not replace.
@(private = "file")
judged_jsonc_splice :: proc(out: []byte, edits: []Edit, allocator: runtime.Allocator, dialect: Dialect) -> Maybe(Path_Error) {
	facts, ferr := make([dynamic]Fact, allocator)
	if ferr != nil {
		return core_pkg.PATH_OUT_OF_MEMORY
	}
	defer delete(facts)
	if e, bad := validate_facts(out, {dialect = dialect}, &facts).?; bad {
		return core_pkg.path_error_of(e, .Bad_Result)
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
	return core_pkg.judged_result(out, validate(out, {dialect = dialect}), allocator)
}

// Replace every value the path finds with `value`, written canonically once.
//
//	- The source is scanned `.Strict` under `opts`' dialect and limits. Under `.Default` duplicates a key repeated
//	  on the path's way is refused: `.Bad_Source` with `syntax = .Duplicate_Key` at the repeated key, as `.Refuse` reports it.
//	  `.Last`, `.First`, `.All` and `.Refuse` pick or refuse as `find` does.
//	- No re-validating: a strict source with whole values swapped for whole canonical values is still
//	  valid, and the depth guard covers the one thing the grammar does not.
//	- Every allocation, scratch included, is `allocator`'s, as in `insert` and `remove`.
//	- A path that finds nothing is `.Not_Found`, or `.Type_Mismatch` when every answer was a step meeting
//	  a value of another kind (a name on an array).
//	- `.Jsonc` reads the source as JSONC. A member it adds goes after the last entry's comments.
//	- Every path edit takes the path as text or as a parsed `Path` (`Path_Spec`). Text that does not parse
//	  is `.Bad_Path` at the byte the parser stopped on.
@(require_results)
set :: proc(src: []byte, path: Path_Spec, value: any, opts := Read_Opts{}, allocator := context.allocator) -> (out: []byte, err: Maybe(Path_Error)) {
	return set_or_upsert(src, path, value, opts, allocator, false)
}

// `set`, and also add the member to each object the path's last name is missing from, as `insert` would. The
// path must end in a name, and everything before it must find objects.
@(require_results)
upsert :: proc(src: []byte, path: Path_Spec, value: any, opts := Read_Opts{}, allocator := context.allocator) -> (out: []byte, err: Maybe(Path_Error)) {
	return set_or_upsert(src, path, value, opts, allocator, true)
}

@(private = "file")
set_or_upsert :: proc(src: []byte, path: Path_Spec, value: any, opts: Read_Opts, allocator: runtime.Allocator, upsert: bool) -> (out: []byte, err: Maybe(Path_Error)) {
	edit_refused(opts.dialect) or_return
	watch := core_pkg.Refusal_Watch{backing = allocator}
	out, err = watched_set(src, path, value, core_pkg.watched(&watch), upsert, opts)
	return core_pkg.unless_refused(&watch, out, err, core_pkg.PATH_OUT_OF_MEMORY)
}

@(private = "file")
watched_set :: proc(src: []byte, path: Path_Spec, value: any, allocator: runtime.Allocator, upsert: bool, opts: Read_Opts) -> (out: []byte, err: Maybe(Path_Error)) {
	buf: core_pkg.Path_Buf
	p := core_pkg.path_resolve(path, &buf, allocator) or_return
	defer delete(buf.heap, allocator)
	// The target sits inside one container per step.
	repl := canonical(value, len(p.steps), allocator, opts.dialect) or_return
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
		return insert_at(src, {steps = p.steps[:n - 1]}, string(name), repl[:], allocator, opts, upsert = true)
	}
	paths := [1]Path{p}
	req: Request({.Path})
	defer request_destroy(&req)
	edit_scan(src, &req, paths[:], opts, allocator) or_return
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
	core_pkg.edit_found(len(edits), mismatched, len(req.answers)) or_return
	// Every answer sits at the path's depth, so answers never nest, and sorted they are disjoint.
	slice.sort_by(edits[:], proc(a, b: Edit) -> bool {
		return a.lo < b.lo
	})
	return core_pkg.edits_apply_checked(src, edits[:], allocator)
}

// Where `insert` puts its entry: a member name for an object, an element index for an array. An index
// counts from the end when negative, as `child`'s does: `-1` places the entry before the last element, and
// `APPEND` after it, whatever the length.
Insert_At :: core_pkg.Insert_At

// An `Insert_At` past an array's last element, whatever its length.
APPEND :: core_pkg.APPEND

// Add `value`, written canonically once, to every container the path finds: as member `at` of an object,
// after its last member, or as element `at` of an array.
//
//	- The entry copies the separator between its neighbours and a member's key-to-value bytes, so pretty
//	  input stays pretty. A lone entry's separator is a comma and the whitespace before that entry, and an
//	  empty container takes the entry compact, before its close.
//	- A member the object already has is `.Exists` (`upsert` replaces it).
//	- An index past either end, a name for an array, or neighbours with more than whitespace and a comma
//	  between them, is `.Unplaceable`.
//	- The source is read as `set` reads it: under `.First` or `.Last` the entry goes into the containers `set`
//	  finds.
//	- `.Jsonc` reads the source as JSONC and places the entry between its neighbours' extents, each entry's
//	  comments and comma included (`entry_at`). The result is validated as JSONC.
@(require_results)
insert :: proc(src: []byte, path: Path_Spec, at: Insert_At, value: any, opts := Read_Opts{}, allocator := context.allocator) -> (out: []byte, err: Maybe(Path_Error)) {
	edit_refused(opts.dialect) or_return
	watch := core_pkg.Refusal_Watch{backing = allocator}
	out, err = watched_insert(src, path, at, value, core_pkg.watched(&watch), opts)
	return core_pkg.unless_refused(&watch, out, err, core_pkg.PATH_OUT_OF_MEMORY)
}

@(private = "file")
watched_insert :: proc(src: []byte, path: Path_Spec, at: Insert_At, value: any, allocator: runtime.Allocator, opts: Read_Opts) -> (out: []byte, err: Maybe(Path_Error)) {
	buf: core_pkg.Path_Buf
	p := core_pkg.path_resolve(path, &buf, allocator) or_return
	defer delete(buf.heap, allocator)
	repl := canonical(value, len(p.steps) + 1, allocator, opts.dialect) or_return
	defer delete(repl)
	return insert_at(src, p, at, repl[:], allocator, opts)
}

// Remove every value the path finds, with its member key, and exactly one separator beside it: the one
// after it, or before it for a container's last entries.
//
//	- Removing every entry leaves the container empty, `{}` or `[]`.
//	- The source is read as `set` reads it: under `.First` or `.Last` it removes what `set` finds, under `.All`
//	  every occurrence of a repeated key.
//	- The root is `.Unplaceable`.
//	- `.Jsonc` reads the source as JSONC and removes each entry with the comments attached to it
//	  (`remove_in`). The result is validated as JSONC.
@(require_results)
remove :: proc(src: []byte, path: Path_Spec, opts := Read_Opts{}, allocator := context.allocator) -> (out: []byte, err: Maybe(Path_Error)) {
	edit_refused(opts.dialect) or_return
	watch := core_pkg.Refusal_Watch{backing = allocator}
	out, err = watched_remove(src, path, core_pkg.watched(&watch), opts)
	return core_pkg.unless_refused(&watch, out, err, core_pkg.PATH_OUT_OF_MEMORY)
}

@(private = "file")
watched_remove :: proc(src: []byte, path: Path_Spec, allocator: runtime.Allocator, opts: Read_Opts) -> (out: []byte, err: Maybe(Path_Error)) {
	buf: core_pkg.Path_Buf
	p := core_pkg.path_resolve(path, &buf, allocator) or_return
	defer delete(buf.heap, allocator)
	n := len(p.steps)
	if n == 0 {
		return nil, Path_Error{kind = .Unplaceable}
	}
	switch opts.dialect {
	case .Json:
		return remove_in(src, p, allocator, opts, .Json)
	case .Jsonc:
		return remove_in(src, p, allocator, opts, .Jsonc)
	case .Json5: // `edits_read` refuses it before any edit
	}
	return nil, Path_Error{kind = .Bad_Option}
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
	if e, bad := validate(repl[:], {dialect = dialect, limits = {max_depth = u64(max(MAX_DEPTH - depth, 0))}}).?; bad {
		delete(repl)
		if e.kind == .Too_Deep {
			return nil, Path_Error{kind = .Too_Deep}
		}
		return nil, core_pkg.path_error_of(e, .Bad_Result)
	}
	return repl, nil
}

// The `.Strict` scan for `paths` every path edit starts from, under `opts` with a repeated target refused,
// its refusals and faults as edit errors.
@(private)
edit_scan :: proc(src: []byte, req: ^Request($KINDS), paths: []Path, opts: Read_Opts, allocator: runtime.Allocator) -> Maybe(Path_Error) {
	req.read = opts
	req.paths = paths
	req.strictness = .Strict
	targeted := req.duplicates == .Default
	// A limit is cut after the scan, which reads every occurrence. Edits ask at most three paths.
	unlimited: [3]Path
	if targeted {
		req.duplicates = .All
		for p, i in paths {
			unlimited[i] = {steps = p.steps, per_element = p.per_element}
			req.state.route.walk_repeats ||= named_inside(p.steps)
		}
		req.paths = unlimited[:len(paths)]
	}
	req.allocator = allocator
	e, bad := scan(src, req).?
	if !bad {
		if !targeted {
			return nil
		}
		repeat := repeated_on_path(req.answers[:], req.paths, allocator)
		if repeat != nil && req.state.route.repeat_at == 0 {
			// Only the automaton's walk knows where the repeated key starts.
			req.state.route.walk_repeats = true
			req.paths = unlimited[:len(paths)]
			_ = scan(src, req)
		}
		if key_lo := req.state.route.repeat_at; key_lo > 0 {
			if r, has := repeat.?; !has || key_lo < r.offset {
				repeat = Path_Error{kind = .Bad_Source, syntax = .Duplicate_Key, offset = key_lo}
			}
		}
		req.paths = paths
		finish_answers(&req.answers, nil, &req.state.route, paths, false)
		found_one := false
		for a in req.answers {
			found_one ||= a.outcome == .Found
		}
		if repeat != nil || found_one {
			return repeat
		}
		// `.All` answers a step on the wrong kind as missing; `.Last` tells the two apart.
		req.duplicates = .Last
		if e, bad = scan(src, req).?; !bad {
			return nil
		}
	}
	#partial switch e.kind {
	case .Over_Capacity:
		return Path_Error{kind = .Over_Capacity}
	case .Bad_Option, .Bad_Path, .Source_Too_Wide:
		// Unreachable, as the edits build their own requests. An error beats a panic in the caller.
		return Path_Error{kind = .Internal}
	}
	return core_pkg.path_error_of(e)
}

// Whether `steps` pass a `Name` before their last step: a key there may repeat in its object with only one copy
// holding the rest of the path, which only the automaton's walk sees.
@(private = "file")
named_inside :: proc(steps: []Step) -> bool {
	for s in steps[:max(len(steps) - 1, 0)] {
		if _, named := s.(Name); named {
			return true
		}
	}
	return false
}

// A key repeated at a path's end, which `.Default` refuses: two values one object holds under the last name of a
// `Name`-ending path, at the later value. A repeat no path passes is kept.
@(private = "file")
repeated_on_path :: proc(answers: []Answer, paths: []Path, allocator: runtime.Allocator) -> Maybe(Path_Error) {
	for p, q in paths {
		n := len(p.steps)
		if n == 0 {
			continue
		}
		if _, named := p.steps[n - 1].(Name); !named {
			continue
		}
		hits := found(answers, u32(q), allocator)
		defer delete(hits)
		for k in 1 ..< len(hits) {
			if hits[k].owner == hits[k - 1].owner {
				return Path_Error{kind = .Bad_Source, syntax = .Duplicate_Key, offset = hits[k].lo}
			}
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
found :: proc(answers: []Answer, q: u32, allocator: runtime.Allocator) -> [dynamic]Answer {
	out := make([dynamic]Answer, allocator)
	for a in answers {
		if a.query == q && a.outcome == .Found {
			append(&out, a)
		}
	}
	slice.sort_by(out[:], proc(a, b: Answer) -> bool {
		return a.lo < b.lo
	})
	return out
}

// The answers in `rows` held by the container starting at `owner`, from cursor `at` on. Containers come in
// document order and never nest.
@(private)
held_by :: proc(rows: []Answer, at: ^int, owner: u64) -> []Answer {
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
	core_pkg.edit_found(len(places)) or_return
	edits, aerr := make([]Edit, len(places), allocator)
	if aerr != nil {
		return nil, core_pkg.PATH_OUT_OF_MEMORY
	}
	defer delete(edits, allocator)
	for p, i in places {
		edits[i] = {lo = p.at, hi = p.cut, bytes = text[p.from:p.to]}
	}
	return core_pkg.edits_apply_checked(src, edits, allocator)
}
