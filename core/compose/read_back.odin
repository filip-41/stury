package compose

import "base:runtime"
import "core:slice"
import core ".."

// The text a commit made and the format's reads of it: those of the list's own spec, or of the target's handle for
// another spec of the format.
@(private)
Output :: struct {
	list:     ^core.Edit_List,
	text:     []u8,
	target:   core.As,
	validate: type_of(core.Edit_Services{}.validate),
	build:    type_of(core.Edit_Services{}.build),
	scan:     type_of(core.Edit_Services{}.scan),
}

// The reads of `text` as `target`, false when the format has none for that spec.
@(private)
output_of :: proc(list: ^core.Edit_List, text: []u8, target: core.As) -> (o: Output, reads: bool) {
	o = {list = list, text = text, target = target}
	if target.spec == list.doc.as.spec {
		o.validate, o.build, o.scan = list.edit.validate, list.edit.build, list.edit.scan
		return o, true
	}
	services := core.services_of(target)
	if services == nil || services.validate == nil {
		return o, false
	}
	o.validate, o.build, o.scan = services.validate, services.build, services.scan
	return o, true
}

// Judges and reads back the output of a commit that composed the edits. The output must read as strictly as the source,
// and as the edits wrote, see `reads_back`. An output the strict read refuses is accepted only if it keeps the document's
// spec, the format's tolerant read takes it and the source needed a tolerance too, and is then read back for its values
// under the target's options. `written`, when given, are the pieces the edits wrote, which one walk of the output judges
// whole and reads back, see `core.reads_written`. Works in the context allocator.
@(private)
judge_output :: proc(o: ^Output, written: Maybe([]core.Written), allocator: runtime.Allocator) -> core.Document_Error {
	doc := o.list.doc
	strict := doc.as
	strict.tolerate = {}
	if o.target.spec != doc.as.spec {
		strict.readers, strict.spec = o.target.readers, o.target.spec
	}
	e, known := core.Document_Error{}, false
	if pieces, placed := written.?; placed {
		e, known = core.reads_written(o.list, o.text, strict, pieces, o.list.edit.walk_written)
	}
	if !known {
		e = reads_back(o, strict, true, allocator)
	}
	// A read that refuses the bytes is a `.Bad_Result` that names no reason, a read of other values names one.
	if e.kind != .Bad_Result || e.reason != .None {
		return e
	}
	tolerant := strict
	tolerant.tolerate = ~bit_set[core.Tolerance; u8]{}
	if fault, still := o.validate(o.text, tolerant).?; still {
		return {kind = .Bad_Result, inner = fault}
	}
	if o.target.spec != doc.as.spec {
		return e
	}
	if _, src_bad := o.validate(doc.src, strict).?; !src_bad {
		return e
	}
	return reads_back(o, o.target, false, allocator)
}

// Whether the text of `o`, a commit of its list, read as `as`, holds the values the edits wrote, compared as values are:
// a number by the decimal it spells, and a cell or a markup text read as the kind of the value it stands for. A format
// with a scan reads the regions the edits make by their paths, at most `core.MAX_PATHS` runs of them, see
// `region_runs`. A format with none, and regions no read of paths answers alone, read the text whole and compare the
// values the edits wrote and the shape of the rest, see `core.reads_as_edited`. A list whose edits hold no value to
// compare is judged by the format's read alone.
// `judging` is whether the text is not yet judged. It is judged by the build or the row read, which read it whole and
// refuse what the validate refuses, by the read of the regions when the scan reads it whole or when the regions are
// many, and else by the validate.
@(private)
reads_back :: proc(o: ^Output, as: core.As, judging: bool, allocator: runtime.Allocator) -> core.Document_Error {
	list, out := o.list, o.text
	if o.build == nil {
		return judge(o, as, judging)
	}
	arena := runtime.Arena{backing_allocator = allocator, minimum_block_size = 64 * 1024}
	defer runtime.arena_destroy(&arena)
	context.allocator = runtime.arena_allocator(&arena)
	context.temp_allocator = context.allocator
	if o.scan != nil {
		regions, known, fits := core.edited_regions(list)
		if !known {
			return judge(o, as, judging)
		}
		if runs, few := region_runs(regions); fits && few {
			// A read of many regions reads every byte in place of the validate, and a read of few stops at its last
			// answer, after the validate has judged the text.
			whole := judging && (list.edit.whole_scan || len(regions) > core.MAX_PATHS)
			if !whole {
				if e := judge(o, as, judging); e.kind != .None {
					return e
				}
			}
			return regions_read_back(regions, runs, out, as, !whole, o.scan)
		}
	}
	if list.edit.walk_rows != nil {
		if e, known := core.reads_rows(list, out, as, list.edit.walk_rows); known {
			return e
		}
	}
	built, err := o.build(out, as, false, context.allocator)
	if err.kind != .None {
		return {kind = .No_Memory} if err.kind == .No_Memory else {kind = .Bad_Result, inner = err.inner}
	}
	if reads, known := core.reads_as_edited(list, core.Node_Ref{&built, core.ROOT}); known && !reads {
		return {kind = .Bad_Result, reason = .Reads_Back_Other}
	}
	return {}
}

// Whether the text of `o` reads as `as` by the format's validate, when it is not yet judged.
@(private = "file")
judge :: proc(o: ^Output, as: core.As, judging: bool) -> core.Document_Error {
	if !judging || o.validate == nil {
		return {}
	}
	if fault, bad := o.validate(o.text, as).?; bad {
		return {kind = .Bad_Result, inner = fault}
	}
	return {}
}

// Whether each of `regions` reads from `out` as it wants, its path answered once: by the value it wants, or as missing
// when it wants none. Each of `runs` is one path of the read, whose answers are its regions in their order.
@(private = "file")
regions_read_back :: proc(regions: []core.Edited_Region, runs: []Region_Run, out: []u8, as: core.As, stop_early: bool, scan: type_of(core.Edit_Services{}.scan)) -> core.Document_Error {
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
	doc, err := scan(out, as, paths, {dups = .First, stop_early = stop_early}, nil, nil, context.allocator)
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
