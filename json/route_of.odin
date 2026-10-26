package json

import "core:slice"

// The engine that answers a path of a request, or why the automaton does.
Path_Route :: enum u8 {
	Matcher,
	Tape, // a text the tape cannot settle goes to the matcher
	// The rest name why the automaton answers.
	Forced, // a `.Jsonc` or `.Refuse` walk: the automaton is the only engine
	Per_Element,
	Index,
	Ends_Any,
	Deep_Name, // `.a.b`: the matcher reads one key of the root
	Other_Shape, // the matcher serves another shape of the request, or the path has no steps
	Other_Gate, // the request's gated columns do not share one gate
	Root_Not_Object,
}

// The engine that answers `paths[which]` when `paths` are scanned together over `src` with `opts`. `src` is read
// only to its root's first value. `Bad_Option` when `which` is not one of `paths`; `Over_Capacity` where `scan`
// would refuse the paths for the router's bounds.
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
