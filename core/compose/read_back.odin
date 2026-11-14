package compose

import "base:runtime"
import "core:slice"
import core ".."

// Whether `out`, the text a commit of `list` made, read as `target`, holds the values the edits wrote, compared as
// values are: a number by the decimal it spells, and a cell or a markup text read as the kind of the value it stands
// for. A format with a scan reads the regions the edits make by their paths, at most `core.MAX_PATHS` runs of them,
// see `region_runs`. A format with none, and regions no read of paths answers alone, read `out` whole and compare the
// values the edits wrote and the shape of the rest, see `core.reads_as_edited`. A list whose edits hold no value to
// compare is judged by the format's read alone.
// `judged`, when given, is the options `out` is judged under here: by the build or the row read, which read `out`
// whole and refuse what the validate refuses, by the read of the regions when the scan reads `out` whole or when
// `read_judges` and the regions are many, and else by the validate. Without it the commit has judged `out` already.
@(private)
reads_back :: proc(list: ^core.Edit_List, out: []u8, target: core.As, judged: Maybe(core.As), read_judges: bool, allocator: runtime.Allocator) -> core.Document_Error {
	// The list's own services read its own spec. Another spec of the format is read by the target's handle.
	build, scan := list.edit.build, list.edit.scan
	if build != nil && target.spec != list.doc.as.spec {
		services := core.services_of(target)
		if services == nil || services.build == nil {
			return {kind = .Bad_Spec}
		}
		build, scan = services.build, services.scan
	}
	if build == nil {
		return judge(list, out, judged)
	}
	arena := runtime.Arena{backing_allocator = allocator, minimum_block_size = 64 * 1024}
	defer runtime.arena_destroy(&arena)
	context.allocator = runtime.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	if scan != nil {
		regions, known, fits := core.edited_regions(list)
		if !known {
			return judge(list, out, judged)
		}
		if runs, few := region_runs(regions); fits && few {
			// A scan that reads `out` whole judges it. A read of many regions reads every byte in place of the validate,
			// and a read of few stops at its last answer, after the validate has judged `out`.
			if as, judging := judged.?; judging && list.edit.whole_scan {
				return regions_read_back(regions, runs, out, as, true, scan)
			} else if judging && read_judges && len(regions) > core.MAX_PATHS {
				return regions_read_back(regions, runs, out, as, false, scan)
			}
			if e := judge(list, out, judged); e.kind != .None {
				return e
			}
			return regions_read_back(regions, runs, out, target, true, scan)
		}
	}
	if list.edit.walk_rows != nil {
		if e, known := core.reads_rows(list, out, judged.? or_else target, list.edit.walk_rows); known {
			return e
		}
	}
	built, err := build(out, judged.? or_else target, false, context.allocator)
	if err.kind != .None {
		return {kind = .No_Memory} if err.kind == .No_Memory else {kind = .Bad_Result, inner = err.inner}
	}
	if reads, known := core.reads_as_edited(list, core.Node_Ref{&built, core.ROOT}); known && !reads {
		return {kind = .Bad_Result, reason = .Reads_Back_Other}
	}
	return {}
}

// Whether `out` reads under `judged` by the format's validate, when a format's own commit gives the options.
@(private = "file")
judge :: proc(list: ^core.Edit_List, out: []u8, judged: Maybe(core.As)) -> core.Document_Error {
	as, own := judged.?
	if !own || list.edit.validate == nil {
		return {}
	}
	if fault, bad := list.edit.validate(out, as).?; bad {
		return {kind = .Bad_Result, inner = fault}
	}
	return {}
}

// Whether each of `regions` reads from `out` as it wants, its path answered once: by the value it wants, or as missing
// when it wants none. Each of `runs` is one path of the read, whose answers are its regions in their order.
@(private = "file")
regions_read_back :: proc(regions: []core.Edited_Region, runs: []Region_Run, out: []u8, target: core.As, stop_early: bool, scan: type_of(core.Edit_Services{}.scan)) -> core.Document_Error {
	paths := make([]core.Path, len(runs))
	for u, i in runs {
		paths[i] = {steps = u.steps}
		if u.varies >= 0 {
			paths[i].steps = slice.clone(u.steps)
			lo := int(u.steps[u.varies].(core.Index))
			paths[i].steps[u.varies] = core.Slice{lo, lo + len(u.members)}
		}
	}
	// No object on a region's path repeats a key, so the first key answers as the last would.
	doc, err := scan(out, target, paths, {dups = .First, stop_early = stop_early}, nil, nil, context.allocator)
	if err.kind != .None {
		return {kind = .No_Memory} if err.kind == .No_Memory else {kind = .Bad_Result, inner = err.inner}
	}
	read := make([]int, len(runs))
	for a in doc.answers {
		u := &runs[a.path]
		if read[a.path] == len(u.members) {
			return {kind = .Bad_Result, reason = .Reads_Back_Other}
		}
		r := regions[u.members[read[a.path]]]
		if !(a.outcome == .Missing if r.gone else a.outcome == .Found && core.reads_back_as(r.want, core.Node_Ref{&doc, a.node})) {
			return {kind = .Bad_Result, reason = .Reads_Back_Other}
		}
		read[a.path] += 1
	}
	for u, i in runs {
		if read[i] != len(u.members) {
			return {kind = .Bad_Result, reason = .Reads_Back_Other}
		}
	}
	return {}
}

// The regions one path of a read answers in their order: one region, or regions whose paths differ only at one `Index`,
// which counts up by one from each to the next, read as a `Slice`.
@(private = "file")
Region_Run :: struct {
	steps:   []core.Step, // the first region's path
	varies:  int, // the step whose index counts up, -1 while the run holds one region
	next:    int, // the index the run's next region holds there
	members: [dynamic]int,
	// The region wants no element at an `Index` it ends in, which a `Slice` leaves unanswered, so it runs alone.
	alone:   bool,
}

// The runs `regions` make, in the order each starts, or false past `core.MAX_PATHS` of them, which no read holds.
@(private = "file")
region_runs :: proc(regions: []core.Edited_Region) -> ([]Region_Run, bool) {
	runs := make([dynamic]Region_Run)
	next: for r, i in regions {
		alone := false
		if n := len(r.path.steps); r.gone && n > 0 {
			_, alone = r.path.steps[n - 1].(core.Index)
		}
		#reverse for &u in runs {
			if !alone && !u.alone && joins(&u, r.path.steps) {
				append(&u.members, i)
				continue next
			}
		}
		if len(runs) == core.MAX_PATHS {
			return nil, false
		}
		append(&runs, Region_Run{steps = r.path.steps, varies = -1, alone = alone})
		append(&runs[len(runs) - 1].members, i)
	}
	return runs[:], true
}

// Whether a region at `steps` is the next of run `u`, which then holds it.
@(private = "file")
joins :: proc(u: ^Region_Run, steps: []core.Step) -> bool {
	if len(steps) != len(u.steps) {
		return false
	}
	varies := u.varies
	for s, k in steps {
		if k != varies && s == u.steps[k] {
			continue
		}
		x, is := s.(core.Index)
		y, was := u.steps[k].(core.Index)
		if !is || !was || (k != varies && (varies >= 0 || int(x) != int(y) + 1)) || (k == varies && int(x) != u.next) {
			return false
		}
		varies = k
	}
	if varies < 0 {
		return false
	}
	u.varies, u.next = varies, int(steps[varies].(core.Index)) + 1
	return true
}
