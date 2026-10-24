package walk

// What the walk routes on, decided by a `Strictness` and the call's duplicate resolution: how much of
// each visited token is validated, and whether the walk may stop early. Nothing else about a preset reaches
// the walk.

// A `Strictness` is a preset of the scan axis and termination (`axes_for`). The walk is chosen by the scan
// axis alone, which has two levels:
//
//	 .Strict      .Values   every visited token gets a grammar + UTF-8 check
//	 .Structural  .Locate   framing, wire UTF-8 and the depth cap only
//	 .Lazy        .Values   `.Strict` on every visited token, plus the ability to stop at a first-wins
//	                        answer; a value no query reads may be skipped unchecked
//
// Every visited token's UTF-8 is checked, escape operands included; a skipped unread value is not checked
// at all. Only grammar laxity (escape contents, number grammar, literal bodies, control admission,
// truncated scalars) is strictness-gated.

// How a query resolves duplicate keys (the public name is `Duplicates`). Not a document rule: a walk
// preserves every occurrence, and this matters only when a query asks for a member by name.
//
//	.All    every matching occurrence answers, so it never settles early: the last match is known only at
//	        the item's end.
//	.First  the first match is final, so a `.Lazy` walk can stop at it.
//	.Last   the last match answers. No prefix settles it, so a forward walk reads the whole item.
Resolution :: enum {
	All,
	First,
	Last,
}

// How much of one region a walk validates. This, not `Strictness`, is the axis a demand moves on: a demand
// does not change what the walk reads, only how much of each region it has to validate.
Check_Level :: enum {
	Locate, // the region's end is located, and its values are not validated
	Values, // every byte of the region is validated at full strictness
}

// The scan axis, in grammar terms. Does every visited token get a grammar and UTF-8 check, or only framing?
Scan_Axis :: enum {
	// The zero value, and the sound one: framing, wire UTF-8, escape grammar, number grammar, literal bodies,
	// control admission, truncated scalars, and the scalar caps.
	Full,
	// Framing, wire UTF-8 and the depth cap: what a caller needs to walk the bytes safely. Contents are
	// located, not validated.
	Locate,
}

// The termination capability, split from `Resolution` because "which occurrence answers" and "may the walk
// stop once it has" are different questions. `.Complete` is the zero value: a caller who says nothing gets a
// whole-item answer.
Termination :: enum {
	Complete, // the whole item is walked
	// The walk may stop at a value-close boundary once the declared first-wins answer is complete in hand.
	// `axes_for` turns it on for `.Lazy` under `.First`.
	First_Wins_May_Stop,
}

// How much of the item a result covers. `.Partial` comes first so the zero value refuses: a caller that never
// established coverage cannot claim `.Full` by accident, and only `validate_remaining` upgrades it. Produced
// by a `First_Wins_May_Stop` stop, a fault (nothing past the faulting byte was reached), or a region skipped
// without checks.
//
// The skip is an explicit parameter because a walk that skipped its middle still reaches the item's end. The
// level stays the scan axis's business (`Check_Level`): a `.Structural` whole-item result is not a `.Strict`
// one.
Validity :: enum {
	// The walk ended before the item did. The result covers the bytes before the end and says nothing about
	// any byte after it.
	Partial,
	// The walk reached the end of the item, so its result (`nil`, `Truncated` or `Trailing` alike) is about
	// the whole document. A complete `.Strict` walk is here, and so is a `.Structural` one that skipped
	// nothing: it validated framing only, but over every byte.
	Full,
}

// One reading of one scan: `axes_for`'s answer.
Strictness_Axes :: struct {
	scan:        Scan_Axis,
	termination: Termination,
}

// The preset table. A stop is legal only where the first occurrence is final, so `.Lazy` may stop only
// under `.First`. Under `.All` and `.Last` it reads the whole item, like `.Strict`.
axes_for :: #force_inline proc(strictness: Strictness, resolution: Resolution) -> Strictness_Axes {
	axes: Strictness_Axes
	switch strictness {
	case .Strict:
		axes = Strictness_Axes{scan = .Full, termination = .Complete}
	case .Structural:
		axes = Strictness_Axes{scan = .Locate, termination = .Complete}
	case .Lazy:
		axes = Strictness_Axes{scan = .Full, termination = .First_Wins_May_Stop if resolution == .First else .Complete}
	}
	return axes
}

// The check level the walk runs at, decided by the scan axis alone. Termination does not enter:
// `.Lazy` scans `.Full`, so it walks at `.Values` and stops where its answer ends.
axes_check_level :: #force_inline proc(axes: Strictness_Axes) -> Check_Level {
	return axes.scan == .Full ? .Values : .Locate
}

// Whether every run in this call has settled under its own effective resolution: the stop test, a conjunction
// over runs. Each run's settlement is computed where it is resolved (`path_settle`, `demand_record`). `$Q`
// gates each kind, so a call without a demand or paths pays nothing for them.
call_settled :: #force_inline proc(q: ^Query_Ctx, $Q: bit_set[Walk_Kind]) -> bool {
	when .Path in Q {
		for i in 0 ..< q.n_paths {
			if !q.path_runs[i].settled {
				return false
			}
		}
	}
	when .Demand in Q {
		if !q.demand.settled {
			return false
		}
	}
	return true
}

// Whether this call's queries can settle before the item ends, so whether the walk needs a stop test at all:
// one run that cannot settle early makes every early stop unsound. The answer is no for a path run whose
// resolution must see every occurrence (`.All`, or `.Last` on a `Name` step), an empty path, a `.Nodes` tape,
// and a demand that is not first-wins or writes a row per hit.
//
// Each kind in `$Q` is its own specialization, so an arm for a kind the set does not name folds away.
stop_capable :: #force_inline proc(ctx: ^Query_Ctx, $Q: bit_set[Walk_Kind]) -> bool {
	may_stop := false
	when .Nodes in Q {
		// A tape claims to be a tree, and a container's row is patched only at its close. The root closes
		// last, so a stop leaves a row open. `.Dom` rides these rows.
		return false
	}
	when .Path in Q {
		for i in 0 ..< ctx.n_paths {
			if !path_run_may_settle_early(&ctx.path_runs[i]) {
				return false
			}
		}
		may_stop = ctx.n_paths > 0
	}
	when .Demand in Q {
		if !(ctx.demand_asked && ctx.demand.can_settle) {
			return false
		}
		may_stop = true
	}
	return may_stop
}
