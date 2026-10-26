package json

// The router's answer for one path of a request, without a request or a scan: which engine serves it, and
// why not the matcher. `route_of` calls the router's own procs (`route_tally`, `route_choice`, `served_by`),
// the three a scan plans with, so its answer is the scan's.

// The engine that answers a path. `Unknown` is the answer of a call that refused.
Path_Engine :: enum u8 {
	Unknown,
	Matcher, // the demand matcher: a column, a root object's names, or a gated column
	Automaton, // the path automaton, which owes `Missing` and `Type_Mismatch` and binds a fixed number of paths
}

// Why the automaton answers a path. `None` exactly when the matcher does.
Path_Why :: enum u8 {
	None,
	Forced, // a `.Jsonc` or `.Refuse` walk, or the `FORCE_AUTOMATON` test build: the automaton is the only engine
	Per_Element, // `Path.per_element`: one answer per element, which only the automaton gives
	Index, // an `Index` step: the matcher reads names
	Ends_Any, // the path ends in `[]`: the matcher's match ends on a name
	Deep_Name, // two or more named steps and no `[]` (`.a.b`): the matcher reads one key of the root
	Other_Shape, // the request's matcher serves another shape (a column of another depth, a column beside plain names), or the path has no steps
	Other_Gate, // the request's gated columns do not all share one gate
	Root_Not_Object, // a plain name over a root that is not an object: the automaton owes the mismatch
}

// `route_of`'s answer.
Path_Route :: struct {
	engine: Path_Engine,
	why:    Path_Why,
}

// The engine that answers `paths[which]` when `paths` are scanned together over `src` with `opts`, and, for the
// automaton, why it is not the matcher.
//
//	- `src` is read to its root's first value, past a byte order mark and whitespace, to see whether it is an
//	  object. Nothing else of it is read, and nothing is allocated.
//	- Of `opts` only `dialect` and `duplicates` are read.
//	- `Bad_Option` when `which` is not one of `paths`, and `Over_Capacity` when a path has more than
//	  `MAX_PATH_STEPS` steps; `route` is then `.Unknown`. A request `scan` refuses for another reason (more
//	  paths for the automaton than it binds, a `.Refuse` walk in a build without one) is that call's: `route`
//	  says where its paths would go.
@(require_results)
route_of :: proc(src: []byte, paths: []Path, which: int, opts := Read_Opts{}) -> (route: Path_Route, err: Maybe(Error)) {
	if which < 0 || which >= len(paths) {
		return {}, Error{kind = .Bad_Option}
	}
	force := FORCE_AUTOMATON || opts.dialect == .Jsonc || opts.duplicates == .Refuse
	tally, refused := route_tally(paths, force)
	if e, bad := refused.?; bad {
		return {}, e
	}
	served, _ := route_choice(src, paths, force, tally)
	shape, wild, step_why := path_shape(paths[which])
	if served_by(shape, wild, served, tally.wild) {
		return {.Matcher, .None}, nil
	}
	return {.Automaton, why_not_matcher(shape, step_why, served, force)}, nil
}

// Why a path of `shape`, which `path_shape` refused with `step_why` when its steps are the reason, is not
// answered by the `served` shape's matcher.
@(private = "file")
why_not_matcher :: proc(shape: Path_Shape, step_why: Path_Why, served: Path_Shape, force: bool) -> Path_Why {
	switch {
	case force:
		return .Forced
	case shape == .Automaton:
		return step_why
	case shape == .Single_Name && served == .Automaton:
		// `route_choice` serves plain names over an object root, so this is a root of another kind.
		return .Root_Not_Object
	case shape == .Gated_Column && served == .Automaton:
		return .Other_Gate
	}
	return .Other_Shape
}
