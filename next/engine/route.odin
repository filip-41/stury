package engine

import "stury:lib/core/tape"
import "stury:lib/ops/build"
import "stury:lib/query"

// Query contract router: combines frontend `query.Plan` (source demand, serial flags, hints 1/2/3),
// format capabilities from the engine registry, input framing, and runtime options to choose
// the deterministic execution route and record exact reasons for `--explain`.

SPINE_PARALLEL_FROM :: build.PARALLEL_FROM
RECORDS_PARALLEL_FROM :: min(build.PARALLEL_FROM, 1 << 17)

Route_Kind :: enum u8 {
	Whole,
	Scan,
	Records_Serial,
	Records_Parallel,
	Spine_Parallel,
	Projection_Direct,
	Conditional_Whole,
	Files_Parallel,
}

Route_Why :: enum u8 {
	Edit_Needs_Layout,
	Format_No_Scan,
	All_Unbounded,
	Serial_Program,
	Eval_Ctx_Serial,
	Dups_Need_Build,
	Force_Whole,
	Facts_Need_Scan,
	Facts_Need_Whole,
	Slurp_Whole,
	Raw_Lines,
	Demand_Whole,
	Demand_None,
	Where_Needs_Evaluator,
	No_Runner,
	Input_Too_Small,
	Partial_Demand,
	Projection_Direct_Hit,
	Conditional_Whole_Hit,
	Spine_Split_Hit,
	Records_Framing,
	Parallel_Worker_Pool,
	Many_Files,
}

Route_Whys :: bit_set[Route_Why; u32]

Active_Hint :: enum u8 {
	None,
	Spine_Split,
	Projection_Direct,
	Conditional_Whole,
}

Route_Options :: struct {
	runner:            ^tape.Runner,
	where_mode:        bool,
	in_place:          bool,
	edit:              bool,
	fmt:               bool,
	comments_out:      bool,
	facts:             bool,
	force_whole:       bool,
	slurp:             bool,
	raw_input:         bool,
	null_input:        bool,
	serial_eval_ctx:   bool, // true when caller passes stateful `eval_ctx` without per-worker hooks
	dups:              tape.Duplicates,
	file_count:        int,
	input_bytes:       int,
	allow_rerun_whole: bool, // opt-in caller rerun if scan taints before any emit
}

Decision :: struct {
	kind:          Route_Kind,
	whys:          Route_Whys,
	primary_why:   Route_Why,
	spec:          Spec,
	entry:         Format_Entry,
	framing:       Framing,
	keep_facts:    bool,
	keep_origins:  bool,
	demand_mode:   query.Demand_Mode,
	active_hint:   Active_Hint,
	parallel:      bool,
	file_parallel: bool,
	rerun_safe:    bool,
}

// Reports whether `dups` requires full container builds instead of partial scan / path reads.
@(private)
dups_needs_build :: proc "contextless" (entry: Format_Entry, dups: tape.Duplicates) -> bool {
	if dups == .All {
		return true
	}
	if dups == .Refuse {
		return entry.format == nil || .Names_Ahead not_in entry.format.caps
	}
	return false
}

// Selects the optimal execution `Route_Kind` and records structured reasons for `--explain`.
decide :: proc(plan: ^query.Plan, spec: Spec, framing := Framing.Single, opts := Route_Options{}) -> Decision {
	entry, ok := entry_of_spec(spec)
	if !ok {
		entry, _ = entry_of_id(.Json)
	}
	main := plan.sources[.Main] if plan != nil else query.whole_demand(false, .Identity)
	keep_facts := opts.comments_out || opts.facts || main.facts
	has_runner := opts.runner != nil && opts.runner.threads > 0
	serial_blocked := plan != nil && plan.serial != {}
	parallel_eval_blocked := serial_blocked || opts.serial_eval_ctx
	dups_build := dups_needs_build(entry, opts.dups)

	d := Decision {
		spec         = entry.spec,
		entry        = entry,
		framing      = framing,
		keep_facts   = keep_facts,
		keep_origins = opts.where_mode,
		demand_mode  = main.mode,
		rerun_safe   = opts.allow_rerun_whole,
	}

	if keep_facts {
		if entry.supports_scan {
			d.whys += {.Facts_Need_Scan}
		} else {
			d.whys += {.Facts_Need_Whole}
		}
	}
	if !entry.supports_scan {
		d.whys += {.Format_No_Scan}
	}
	if opts.where_mode {
		d.whys += {.Where_Needs_Evaluator}
	}
	if serial_blocked {
		d.whys += {.Serial_Program}
	}
	if opts.serial_eval_ctx {
		d.whys += {.Eval_Ctx_Serial}
	}
	if dups_build {
		d.whys += {.Dups_Need_Build}
		d.demand_mode = .Whole
	}
	if !has_runner {
		d.whys += {.No_Runner}
	}
	if main.mode == .Whole {
		if main.reason == .All_Steps_Only {
			d.whys += {.All_Unbounded}
		} else {
			d.whys += {.Demand_Whole}
		}
	} else if main.mode == .Partial {
		d.whys += {.Partial_Demand}
	} else {
		d.whys += {.Demand_None}
	}

	// 1. In-place edits / fmt / edit always require full document layout.
	if opts.edit || opts.fmt || opts.in_place {
		d.kind = .Whole
		d.demand_mode = .Whole
		d.keep_facts = true
		d.whys += {.Edit_Needs_Layout}
		d.primary_why = .Edit_Needs_Layout
		return d
	}

	// 2. Explicit whole-document override: single docs become `.Whole`; framed records keep framing and build whole per record.
	if opts.force_whole {
		d.demand_mode = .Whole
		d.whys += {.Force_Whole}
		if framing == .Single && opts.file_count <= 1 {
			d.kind = .Whole
			d.primary_why = .Force_Whole
			return d
		}
	}

	// 3. Whole-input ingestion modes (`-s`, `-R`, `-n`).
	if opts.slurp {
		d.kind = .Whole
		d.demand_mode = .Whole
		d.whys += {.Slurp_Whole}
		d.primary_why = .Slurp_Whole
		return d
	}
	if opts.raw_input {
		d.kind = .Whole
		d.whys += {.Raw_Lines}
		d.primary_why = .Raw_Lines
		return d
	}
	if opts.null_input {
		d.kind = .Whole
		d.primary_why = .Demand_None
		return d
	}

	// 4. Multi-file fan-out across worker pool when program and eval context have no serial blockers.
	if opts.file_count > 1 {
		d.whys += {.Many_Files}
		if has_runner && !parallel_eval_blocked {
			d.kind = .Files_Parallel
			d.parallel = true
			d.file_parallel = true
			d.whys += {.Parallel_Worker_Pool}
			d.primary_why = .Many_Files
			return d
		}
	}

	// 5. Evaluate hints from `query.Plan` when available and whole builds are not forced.
	if plan != nil && !opts.force_whole && !dups_build {
		// Hint 2: Direct leaf/column projection with zero evaluator overhead.
		if can_use_projection_direct(plan, entry, opts) {
			d.kind = .Projection_Direct
			d.active_hint = .Projection_Direct
			d.whys += {.Projection_Direct_Hit}
			d.primary_why = .Projection_Direct_Hit
			return d
		}

		// Hint 3: Conditional whole — scan predicate demand first, build whole only on match.
		if can_use_conditional_whole(plan, entry, opts, serial_blocked) {
			d.kind = .Conditional_Whole
			d.active_hint = .Conditional_Whole
			d.whys += {.Conditional_Whole_Hit}
			d.primary_why = .Conditional_Whole_Hit
			return d
		}
	}

	// 6. Framed record streams (Lines / Seq / Elements / Members / Concatenated).
	// Note: DSV `records_scan` refuses `dups == .All`, so DSV + `.All` builds the whole table via `.Whole`.
	if framing != .Single {
		if entry.family == .Dsv && opts.dups == .All {
			d.kind = .Whole
			d.demand_mode = .Whole
			d.primary_why = .Force_Whole if opts.force_whole else .Dups_Need_Build
			return d
		}
		d.whys += {.Records_Framing}
		records_eligible := (framing == .Lines || framing == .Seq) &&
			(entry.family == .Json || entry.family == .Dsv) &&
			has_runner &&
			!serial_blocked &&
			(opts.input_bytes == 0 || opts.input_bytes >= RECORDS_PARALLEL_FROM)
		can_parallel_recs := records_eligible && !opts.serial_eval_ctx
		if can_parallel_recs {
			d.kind = .Records_Parallel
			d.parallel = true
			d.whys += {.Parallel_Worker_Pool}
			d.primary_why = .Force_Whole if opts.force_whole else .Parallel_Worker_Pool
		} else {
			if !has_runner || parallel_eval_blocked {
				// Reason already recorded in `whys`.
			} else if opts.input_bytes > 0 && opts.input_bytes < RECORDS_PARALLEL_FROM {
				d.whys += {.Input_Too_Small}
			}
			d.kind = .Records_Serial
			if opts.force_whole {
				d.primary_why = .Force_Whole
			} else if dups_build {
				d.primary_why = .Dups_Need_Build
			} else if records_eligible && opts.serial_eval_ctx {
				d.primary_why = .Eval_Ctx_Serial
			} else {
				d.primary_why = .Records_Framing
			}
		}
		if !entry.supports_scan || dups_build {
			d.demand_mode = .Whole
		}
		return d
	}

	// 7. Hint 1: Per-element spine split over array elements in a single JSON/CBOR document.
	if plan != nil && !opts.force_whole && !dups_build && can_use_spine_parallel(plan, entry, has_runner, parallel_eval_blocked, opts) {
		d.kind = .Spine_Parallel
		d.active_hint = .Spine_Split
		d.parallel = true
		d.whys += {.Spine_Split_Hit, .Parallel_Worker_Pool}
		d.primary_why = .Spine_Split_Hit
		return d
	}

	// 8. Single-document Scan vs Whole.
	if !entry.supports_scan {
		d.kind = .Whole
		d.demand_mode = .Whole
		d.primary_why = .Format_No_Scan
		return d
	}
	if dups_build {
		d.kind = .Whole
		d.demand_mode = .Whole
		d.primary_why = .Dups_Need_Build
		return d
	}
	if main.mode == .Partial {
		d.kind = .Scan
		d.primary_why = .Facts_Need_Scan if keep_facts else .Partial_Demand
		return d
	}
	if main.mode == .None {
		d.kind = .Scan
		d.primary_why = .Demand_None
		return d
	}
	d.kind = .Whole
	d.demand_mode = .Whole
	d.primary_why = .All_Unbounded if main.reason == .All_Steps_Only else .Demand_Whole
	return d
}

@(private = "file")
can_use_projection_direct :: proc "contextless" (plan: ^query.Plan, entry: Format_Entry, opts: Route_Options) -> bool {
	if plan.hints.projection.shape == .None || len(plan.hints.projection.fields) == 0 {
		return false
	}
	if !entry.supports_scan || entry.groups_dups || opts.where_mode || opts.comments_out || opts.facts || plan.serial != {} {
		return false
	}
	return true
}

@(private = "file")
can_use_conditional_whole :: proc "contextless" (plan: ^query.Plan, entry: Format_Entry, opts: Route_Options, serial_blocked: bool) -> bool {
	cw := &plan.hints.conditional
	if !cw.active || !entry.supports_scan || serial_blocked || opts.where_mode || opts.comments_out || opts.facts {
		return false
	}
	return cw.pred_demand.mode == .Partial
}

@(private = "file")
can_use_spine_parallel :: proc "contextless" (plan: ^query.Plan, entry: Format_Entry, has_runner, parallel_blocked: bool, opts: Route_Options) -> bool {
	sp := &plan.hints.split
	if sp.kind != .Stream && sp.kind != .Collect {
		return false
	}
	if !has_runner || parallel_blocked {
		return false
	}
	if opts.input_bytes > 0 && opts.input_bytes < SPINE_PARALLEL_FROM {
		return false
	}
	if entry.family != .Json && entry.family != .Cbor {
		return false
	}
	for s in sp.prefix {
		#partial switch _ in s {
		case tape.Name, tape.Index:
		case:
			return false
		}
	}
	return true
}
