package json

// The router's answer for one path of a request, without a scan: `route_of` plans the paths as `scan` does
// (`tape_fits`, `route_paths`), and reads why the automaton has a path from the router's own decision
// (`path_shape`, `route_choice`).

import "core:slice"

// The engine that answers a path of a request, or why the automaton does.
Path_Route :: enum u8 {
	Matcher, // the demand matcher: a column, a root object's names, or a gated column
	Tape, // the rows of the text, walked: two or more gated columns under one gate on `.Strict` JSON.
	      // A text it cannot settle (a fault, an escaped key, a source past `MAX_ROW_SOURCE`) goes to the matcher
	// The automaton answers, which owes `Missing` and `Type_Mismatch` and binds a fixed number of paths:
	Forced, // a `.Jsonc` or `.Refuse` walk, or the `FORCE_AUTOMATON` test build: the automaton is the only engine
	Per_Element, // `Path.per_element`: one answer per element, which only the automaton gives
	Index, // an `Index` step: the matcher reads names
	Ends_Any, // the path ends in `[]`: the matcher's match ends on a name
	Deep_Name, // two or more named steps and no `[]` (`.a.b`): the matcher reads one key of the root
	Other_Shape, // the matcher serves another shape of the request (a column of another depth, a column beside plain names), or the path has no steps
	Other_Gate, // the paths of the request are not all gated columns under one gate
	Root_Not_Object, // a plain name over a root that is not an object: the automaton owes the mismatch
}

// The engine that answers `paths[which]` when `paths` are scanned together over `src` with `opts`, and, for the
// automaton, why it is not the matcher.
//
//	- `src` is read to its root's first value, past a byte order mark and whitespace, to see whether it is an
//	  object. Nothing else of it is read.
//	- Of `opts` the dialect, strictness, duplicates and `limits.max_depth` are read.
//	- Allocates only for a request of more than `MAX_PATH_QUERIES` names for the matcher, with
//	  `context.allocator`, and gives it back.
//	- `Bad_Option` when `which` is not one of `paths`. `Over_Capacity` when `scan` would refuse the paths for it:
//	  a path of more than `MAX_PATH_STEPS` steps, more paths for the automaton than it binds, or a name wanted
//	  more often than the matcher holds. `Out_Of_Memory` when the plan's storage could not be had. The refusals
//	  that depend on the request's other fields or outputs (`Request`) are `scan`'s alone.
@(require_results)
route_of :: proc(src: []byte, paths: []Path, which: int, opts := Read_Opts{}) -> (route: Path_Route, err: Maybe(Error)) {
	if which < 0 || which >= len(paths) {
		return {}, Error{kind = .Bad_Option}
	}
	if tape_fits(paths, opts) {
		return .Tape, nil
	}
	forced := automaton_forced(opts.dialect, opts.duplicates)
	plan: Route
	defer route_destroy(&plan)
	if e, refused := route_paths(&plan, src, paths, opts.duplicates, context.allocator, forced).?; refused {
		return {}, e
	}
	if !slice.contains(plan.auto[:plan.n_auto], u32(which)) {
		return .Matcher, nil
	}
	shape, _, own := path_shape(paths[which])
	if shape == .Automaton && !forced {
		return own, nil
	}
	tally, _ := route_tally(paths, forced)
	_, _, lost := route_choice(src, paths, forced, tally)
	return lost[shape], nil
}
