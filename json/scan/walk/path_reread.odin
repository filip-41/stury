package walk

// The negative-`Index` re-read: the sub-walk that answers an array's last members once its length is known.

// The one re-entry: a negative `Index`. The member it names has already been walked by the time the array's
// length is known, so the answer is one bounded re-read, all runs that need it in a single sub-walk. Nesting
// is capped by `MAX_PATH_STEPS`.
//
// The re-read starts at the last recorded start at or before the earliest member named
// (`Query_Ctx.member_starts`), or the `[`, so `[-1]` reads one member, not the array, and `[-K]` passes at
// most a stride of members first. It resumes inside the array with the ordinal counted so far, so it answers
// exactly as a read from the `[` would, and stops once the last member named has closed. The members passed
// are skipped unread, as a forward index skips them: the walk that counted them validated them, or, under
// `.Lazy`, skipped them too.
//
// The answer is validated as the forward walk validates it, though a walk that skips (`.Lazy`) left it unread: the
// re-read walks at the owner's check level (`walk_judged`), and its fault is the owner's.
//
// `lo` is the container's own `[`, and `count` its member tally (`Auto_Level.idx`).
path_reenter_from_end :: proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	d: int,
	lo: u64,
	count: u64,
	want: u16,
) -> (refused: bool, fault: Maybe(Error)) {
	// Words rather than a `Query_Ctx` local, as in `scan_queries`: a re-entry per array under a wildcard
	// would otherwise zero the never-zeroed tail each time.
	sub_words: [size_of(Query_Ctx) / 8]u64 = ---
	sub := (^Query_Ctx)(&sub_words)
	query_ctx_zero(sub, {.Path})
	sub.max_depth = q.max_depth
	sub.path_sink = q.path_sink
	sub.path_src = q.path_src
	sub.hooks = q.hooks
	sub.walk_judged = q.walk_judged
	sub.root_lo = lo
	slots: [MAX_PATH_QUERIES]int
	n := 0
	first := count
	last: u64 = 0
	for i in 0 ..< q.n_paths {
		bit := run_bit(i)
		if want & bit == 0 {
			continue
		}
		run := &q.path_runs[i]
		step_i, _ := step_index(run.steps[d])
		first = min(first, u64(i64(count) + step_i))
		last = max(last, u64(i64(count) + step_i))
		slots[n] = i
		sub.path_runs[n] = Path_Run{
			sink         = run.sink,
			query        = run.query,
			steps        = run.steps[d:],
			mode         = run.mode,
			head_pos     = u64(i64(count) + step_i),
			// Under a wildcard the re-read answers once per match too, toward the same limit.
			wild         = run.wild,
			each         = run.each,
			limit        = run.limit,
			emitted      = run.emitted,
			named_prefix = run.named_prefix || steps_have_name(run.steps[:d]),
		}
		n += 1
	}
	sub.n_paths = n
	sub.auto.reread_end = last + 1

	// The re-read's root is the container's own `[`, so its members are step 0. `s.pos` is restored for the
	// walk that owns the cursor.
	saved := s.pos
	s.pos = lo
	if first > 0 {
		// The latest recorded start at or before `first`: the last member of the group before the one
		// past `first`, if the ring still holds that group.
		shift := q.auto.ring_shift[d]
		group := (first + 1) >> shift
		if group > 0 && ((count - 1) >> shift) - (group - 1) < MEMBER_RING {
			sub.auto.levels[0].idx = group << shift - 1
			s.pos = q.member_starts[d][(group - 1) & (MEMBER_RING - 1)]
		}
	}
	halted := false
	fault = reread_verdict(sub, {.Path}, sub.hooks.path_subwalk(s, sub, sub.max_depth, &halted))
	s.pos = saved
	if fault != nil {
		// Only a walk that skipped the answer can fault here, a locating one included: its forward walk left
		// these bytes unframed, so the re-read's fault is the walk's result, never a miss.
		return
	}

	// Refused appends count, as they concern the answer.
	refused = sub.oom
	for k in 0 ..< n {
		run := &q.path_runs[slots[k]]
		run.answered = run.answered || sub.path_runs[k].answered
		run.found = run.found || sub.path_runs[k].found
		run.emitted = sub.path_runs[k].emitted
		if sub.path_runs[k].has_stage {
			// A candidate the nested walk parked. The owner flushes it, and it supersedes whatever this run
			// parked at a shallower step.
			run.stage = sub.path_runs[k].stage
			run.has_stage = true
		}
		if sub.path_runs[k].settled {
			// A wildcard run settles only at its limit, in every mode.
			if run.wild {
				run.settled = true
			} else {
				path_settle(run)
			}
		}
	}
	return
}

// A walk's result `err`, given a negative `Index`'s re-read that found its answer malformed: that fault
// is the walk's. Applied by the walk's caller, so the walk's own code is untouched.
reread_verdict :: #force_inline proc(q: ^Query_Ctx, $Q: bit_set[Walk_Kind], err: Maybe(Error)) -> Maybe(Error) {
	when .Path in Q {
		if q.reread_faulted {
			return q.reread_fault
		}
	}
	return err
}
