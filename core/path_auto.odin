package core

// "Auto" is the path automaton: the walk's hooks (`auto_*`) advance every requested path one step per value
// or member as the walk goes, so one pass answers all the paths.

// Arm level 0 for every unsettled run: step 0 applies to the members of the root value. `root_run` is stamped
// here because only this site knows which walk owns a run: a re-entry's sub-run below a `Name` must not have
// its `.Last` slot flushed, as a later occurrence of that name may still supersede it. A run's `Any` steps
// and its last step are marked here too: only `.Path` walks read them, and binding stays out of the
// demand-only walks' code.
auto_arm_root :: proc(q: ^Query_Ctx, $Q: bit_set[Walk_Kind]) {
	when .Path in Q {
		for i in 0 ..< q.n_paths {
			run := &q.path_runs[i]
			run.root_run = !run.named_prefix
			for st, d in run.steps {
				if _, is_any := st.(Any); is_any {
					run.wild = true
					q.auto.levels[d].wild |= run_bit(i)
				} else if step_i, is_index := step_index(st); is_index && step_i < 0 {
					// The ring holds `MEMBER_RING` groups of `S` members, the current one partly read, so a
					// stride with `(MEMBER_RING - 2) * S >= K - 1` still holds the group before `-K`'s.
					back := u64(-(step_i + 1))
					for u64(MEMBER_RING - 2) << q.auto.ring_shift[d] < back {
						q.auto.ring_shift[d] += 1
					}
				}
			}
			if n := len(run.steps); n > 0 {
				q.auto.ends[n - 1] |= run_bit(i)
			}
			if run.settled || len(run.steps) == 0 {
				continue
			}
			q.auto.levels[0].armed |= run_bit(i)
		}
		q.auto.owners[0] = q.root_lo
		q.path_top = 1
	}
}

// Arm one level from a match: step `d` applies to the members of the value that just matched at step `d - 1`.
// The other fields are cleared because they describe the previous container at this frame index. So is the
// run's `.First` memory, which is per container once a wildcard above this level can open many of them.
arm_level :: #force_inline proc(q: ^Query_Ctx, d: int, bit: u16) {
	q.auto.first[d] &= ~bit
	next := &q.auto.levels[d]
	next.armed |= bit
	next.matched = 0
	next.hit = 0
	next.idx = 0
	q.path_top = max(q.path_top, u8(d + 1))
}

// The root value is a scalar: every non-empty path is a mismatch. The `.Last` slots those answers parked are
// flushed here, as no container close will.
auto_root_scalar :: proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	$may_stop: bool,
	stopped: ^bool,
) {
	when .Path in Q {
		for i in 0 ..< q.n_paths {
			run := &q.path_runs[i]
			if run.settled || len(run.steps) == 0 {
				continue
			}
			path_answer(q, run, 0, .Type_Mismatch, 0, 0, NO_OWNER)
			run.settled = true
		}
		if q.n_paths > 0 {
			auto_flush_last(q, Q)
			path_stop_now(q, Q, may_stop, stopped)
		}
	}
}

// A container's kind, at its open: a `Name` step on an array and an `Index` step on an object are mismatches.
// Decided here rather than at the first member so that `{"a":{}}` under `a[0]` is a mismatch, not a miss. `d
// == 0` is the root.
//
// Inlined into the walk up to the level's arming test: a container no run reads into decides nothing, and its
// owner is read only while its level is armed.
auto_frame_open :: #force_inline proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	$may_stop: bool,
	stopped: ^bool,
	d: int,
	vc: u8,
	lo: u64,
) -> (check_stop: bool) {
	when .Path in Q {
		if u32(d) >= u32(q.path_top) || q.auto.levels[d].armed == 0 {
			return false
		}
		return auto_frame_kinds(q, Q, may_stop, stopped, d, vc, lo)
	}
	return false
}

// `auto_frame_open` for an armed level.
@(private = "file")
auto_frame_kinds :: #force_no_inline proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	$may_stop: bool,
	stopped: ^bool,
	d: int,
	vc: u8,
	lo: u64,
) -> (check_stop: bool) {
	when .Path in Q {
		lv := &q.auto.levels[d]
		decided := false
		is_obj := vc == VC_OBJECT
		// `Any` reads either kind.
		kinded := lv.armed &~ lv.wild
		// The root's owner is `q.root_lo` (`auto_arm_root`), and no `.First` answer precedes its open.
		if d > 0 {
			q.auto.owners[d] = lo
			kinded &~= q.auto.first[d]
		}
		for i in 0 ..< q.n_paths {
			bit := run_bit(i)
			if kinded & bit == 0 {
				continue
			}
			run := &q.path_runs[i]
			if run.settled || d >= len(run.steps) {
				continue
			}
			_, is_index := step_index(run.steps[d])
			if is_index == is_obj {
				lv.armed &= ~bit
				if d == 0 {
					// There is one root, so its mismatch is final for every mode, `.All` included.
					path_answer(q, run, 0, .Type_Mismatch, 0, 0, NO_OWNER)
					run.settled = true
				} else {
					path_mismatch(q, run, d, d, q.auto.owners[d - 1], .Object if is_obj else .Array)
				}
				decided = true
			}
		}
		if decided && path_stop_now(q, Q, may_stop, stopped) {
			return true
		}
	}
	return false
}

// A value begins as a direct member of `frames[d]`'s container, whether a container or scalar, descended into
// or fused. The ordinal, arming and kind decision live here.
//
// `vc` is the value class the walk already loaded (`VC_OBJECT`, `VC_ARRAY`, or `VC_STRING` to `VC_NUMBER` for
// a scalar), and `lo` its first byte. A `Name` match was decided by `auto_key`, and an `Index` match is decided
// here, where the ordinal is known. An `Index` step does not check `vc`: an element may be any kind, so
// `[1,2]` under `[Index(0)]` is `Found`.
//
// Inlined into the walk up to the run loop, which runs out of line.
auto_member_open :: #force_inline proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	$may_stop: bool,
	stopped: ^bool,
	d: int,
	vc: u8,
	lo: u64,
) -> (check_stop: bool) {
	when .Path in Q {
		if u32(d) >= u32(q.path_top) {
			return false
		}
		lv := &q.auto.levels[d]
		armed := lv.armed
		if armed == 0 {
			return false
		}
		lv.idx += 1
		// Every armed run ends on an `Any` step: the member is each one's answer, emitted at its close. With
		// no stop test, a settled run's bits are inert (every reader skips it first).
		when !may_stop {
			if armed & ~(lv.wild & q.auto.ends[d]) == 0 {
				lv.matched |= armed
				lv.hit |= armed
				return false
			}
		}
		return auto_member_runs(q, Q, may_stop, stopped, d, vc, lo, armed)
	}
	return false
}

// `auto_member_open` for the `armed` runs of level `d`, its ordinal already counted.
@(private = "file")
auto_member_runs :: #force_no_inline proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	$may_stop: bool,
	stopped: ^bool,
	d: int,
	vc: u8,
	lo: u64,
	armed: u16,
) -> (check_stop: bool) {
	when .Path in Q {
		lv := &q.auto.levels[d]
		ord := lv.idx - 1
		decided := false
		// An `Any` step matches every member.
		if wild := armed & lv.wild; wild != 0 {
			lv.matched |= wild
		}
		// Two disjoint sets: `Name` and `Any` steps want the runs matched, `Index` steps every other armed
		// run. `first[d]` rules out a `.First` run that already took its occurrence at this level.
		by_name := armed & lv.matched
		by_index := armed & ~(lv.matched | q.auto.first[d])
		for i in 0 ..< q.n_paths {
			bit := run_bit(i)
			run := &q.path_runs[i]
			if run.settled {
				// Nothing reads a settled run, so its bit only kept this level armed.
				lv.armed &= ~bit
				continue
			}
			if d >= len(run.steps) {
				continue
			}
			terminal := d + 1 == len(run.steps)
			if step_i, is_index := step_index(run.steps[d]); is_index {
				if by_index & bit == 0 {
					continue
				}
				target := step_i
				carried := false
				// The re-entry's carry applies only at the re-read's step 0. At every level, `[0,[[7],8],9]`
				// under `[-2][0]` would answer the `8`.
				if hp, has := run.head_pos.?; has && d == 0 {
					target = i64(hp)
					carried = true
				} else if step_i < 0 {
					// Needs the array's length: `auto_frame_closed` owns it. Where this member
					// begins is kept, as its group's latest (`Path_Auto.ring_shift`), so the re-entry can
					// start near the member it names.
					q.member_starts[d][(ord >> q.auto.ring_shift[d]) & (MEMBER_RING - 1)] = lo
					continue
				}
				if target < 0 || u64(target) != ord {
					continue
				}
				// Spent by the one member it names: left set, `auto_frame_closed` would answer Missing for
				// `[[1,2,3],[4,5,6]]` under `[-1][-1]`.
				if carried {
					run.head_pos = nil
				}
				lv.matched |= bit
				lv.hit |= bit
				// The one member an index names is read: no other member of this container is.
				lv.armed &= ~bit
				if run.mode == .First {
					q.auto.first[d] |= bit
				}
				if !terminal {
					if vc >= VC_STRING {
						// A step that would read inside a scalar is a mismatch, not a miss.
						path_mismatch(q, run, d, d + 1, q.auto.owners[d], kind_at(q.path_src, lo))
					} else {
						arm_level(q, d + 1, bit)
					}
				}
				decided = true
			} else {
				if by_name & bit == 0 {
					continue
				}
				lv.hit |= bit
				wildcard := lv.wild & bit != 0
				if run.mode == .First && !wildcard {
					q.auto.first[d] |= bit
				}
				if vc >= VC_STRING {
					// A scalar with steps still to run: nothing to descend into, and under
					// `Any` nothing to say about it but for a `per_element` run.
					if !terminal && (!wildcard || run.each) {
						path_mismatch(q, run, d, d + 1, q.auto.owners[d], kind_at(q.path_src, lo))
					}
				} else if !terminal {
					arm_level(q, d + 1, bit)
				}
				decided = true
			}
		}
		if decided && path_stop_now(q, Q, may_stop, stopped) {
			return true
		}
	}
	return false
}

// Whether some run answers with the member at step index `d`: one matched it at its last step.
path_answers_member :: #force_inline proc(q: ^Query_Ctx, d: int) -> bool {
	return u32(d) < MAX_PATH_STEPS && q.auto.levels[d].matched & q.auto.ends[d] != 0
}

// Whether some run reads the members of the member at step index `d`: a match there armed the level below it.
path_reaches_into :: #force_inline proc(q: ^Query_Ctx, d: int) -> bool {
	return u32(d + 1) < MAX_PATH_STEPS && q.auto.levels[d + 1].armed != 0
}

// An object member's key: the one site that decides which runs wanted it, at every depth. An empty arming
// mask exits first, and an `Any` step (`wild`) takes every member without its key. A key with no escape
// (`q.key_saw_escape`) is its own decoded text, so `key_equals_wired` rejects a length mismatch before
// comparing bytes.
auto_key :: #force_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	d: int,
	key_lo, key_hi: u64,
) -> (wild_key: bool) {
	when .Path in Q {
		if u32(d) >= u32(q.path_top) {
			return false
		}
		lv := &q.auto.levels[d]
		if mask := lv.armed & ~(lv.matched | lv.wild | q.auto.first[d]); mask != 0 {
			// The source, not the scanner: see `auto_frame_closed`.
			auto_key_match(s.src, q, Q, d, key_lo, key_hi, mask)
		}
		// A key of an object an `Any` step reads, for a run that resolves repeats (`Query_Ctx.wild_keys`). A
		// `.Unique` walk refuses them instead.
		when .Unique not_in Q {
			return lv.armed & lv.wild != 0 && q.wild_keys
		}
	}
	return false
}

// `auto_key` for the runs in `mask`, whose `Name` step at `d` may name this key.
@(private = "file")
auto_key_match :: #force_no_inline proc(
	src: []byte,
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	d: int,
	key_lo, key_hi: u64,
	mask: u16,
) {
	when .Path in Q {
		lv := &q.auto.levels[d]
		clean := !q.key_saw_escape
		for i in 0 ..< q.n_paths {
			bit := run_bit(i)
			if mask & bit == 0 {
				continue
			}
			run := &q.path_runs[i]
			if run.settled || d >= len(run.steps) {
				continue
			}
			name, is_name := step_name(run.steps[d])
			if !is_name {
				continue
			}
			if key_equals_hooked(q.hooks, src, key_lo, key_hi, !clean, name) {
				if run.wild && run.mode == .Last {
					wild_last_key(q, i, d, lv.hit & bit != 0)
				}
				lv.matched |= bit
				lv.hit |= bit
				if run.mode == .First {
					q.auto.first[d] |= bit
				}
			}
		}
	}
}

// A `.Last` wildcard run matched a key of step `d`. Its answers go straight to the sink, so the first
// occurrence in the container notes where they begin and a repeat drops what the earlier one produced:
// the last occurrence of a key wins per object.
wild_last_key :: proc(q: ^Query_Ctx, i, d: int, repeated: bool) {
	run := &q.path_runs[i]
	if repeated {
		path_supersede(run, q.wild_marks[i][d])
		q.path_sink.paths_retracted += 1
	} else {
		q.wild_marks[i][d] = len(run.sink^)
	}
}

// A member closed over `[lo, hi)`. A `Found` is emitted here, as an extent is final only at the value's
// close. The matched member's level is consumed. The container's stays armed for its remaining members.
//
// Inlined into the walk up to the answers, which are written out of line.
auto_member_closed :: #force_inline proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	$may_stop: bool,
	stopped: ^bool,
	d: int,
	lo, hi: u64,
) -> (check_stop: bool) {
	when .Path in Q {
		if u32(d) >= u32(q.path_top) {
			return false
		}
		lv := &q.auto.levels[d]
		matched := lv.matched
		lv.matched = 0
		if matched == 0 {
			return false
		}
		// Every matched run ends on an `Any` step here: each owes this member as a `Found`, which never settles
		// it but at its limit.
		when !may_stop {
			if matched & ~(lv.wild & q.auto.ends[d]) == 0 {
				auto_wild_found(q, matched, d, lo, hi)
				return false
			}
		}
		return auto_member_answers(q, Q, may_stop, stopped, d, lo, hi, matched)
	}
	return false
}

// A `Found` over `[lo, hi)` for each unsettled run in `matched`, every one ending on an `Any` step at `d`.
@(private = "file")
auto_wild_found :: #force_no_inline proc(q: ^Query_Ctx, matched: u16, d: int, lo, hi: u64) {
	kind := kind_at(q.path_src, lo)
	for i in 0 ..< q.n_paths {
		run := &q.path_runs[i]
		if matched & run_bit(i) != 0 && !run.settled {
			path_answer_wild(q, run, .Found, lo, hi, q.auto.owners[d], kind)
		}
	}
}

// `auto_member_closed` for the runs in `matched`, the level's bits already consumed.
@(private = "file")
auto_member_answers :: #force_no_inline proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	$may_stop: bool,
	stopped: ^bool,
	d: int,
	lo, hi: u64,
	matched: u16,
) -> (check_stop: bool) {
	when .Path in Q {
		decided := false
		for i in 0 ..< q.n_paths {
			bit := run_bit(i)
			if matched & bit == 0 {
				continue
			}
			run := &q.path_runs[i]
			if run.settled || d >= len(run.steps) {
				continue
			}
			if d + 1 != len(run.steps) {
				// Not the answer: reported under level `d+1`, or already a mismatch.
				continue
			}
			if path_answer(q, run, d, .Found, lo, hi, q.auto.owners[d], kind_at(q.path_src, lo)) {
				path_settle(run)
			}
			decided = true
		}
		if decided && path_stop_now(q, Q, may_stop, stopped) {
			return true
		}
		// A re-read is done once the last member it names has closed.
		when may_stop {
			if d == 0 && q.auto.levels[0].idx == q.auto.reread_end && stopped != nil {
				stopped^ = true
				return true
			}
		}
	}
	return false
}

// A container closed, at frame index `d`, over `[lo, hi)`. Three things need its finished member list and are
// settled only here:
//
//   1. The miss: a run armed at this level that matched no member (and has not
//      taken its `.First` occurrence) is Missing, except under `.All`, which is
//      settled at the walk's end instead.
//   2. A negative `Index`, whose position depends on the length (see
//      `path_reenter_from_end`).
//   3. At `d == 0`, the `.Last` flush.
//
// Inlined into the walk up to the level's arming test: below the root, a level nothing was armed at has no
// question to settle and nothing to release (`hit`, `matched` and `idx` move only under an armed run). A
// level whose runs all took their member has no question left, but its `hit` is released here. The
// out-of-line part gets a copy of the scanner: handed the walk's own, it would keep the walk's `s.pos` out of
// a register for the whole loop.
auto_frame_closed :: #force_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	$may_stop: bool,
	stopped: ^bool,
	d: int,
	lo, hi: u64,
) -> (check_stop: bool) {
	when .Path in Q {
		if u32(d) >= u32(q.path_top) || (d > 0 && q.auto.levels[d].armed | q.auto.levels[d].hit == 0) {
			return false
		}
		sc := s^
		return auto_frame_settle(&sc, q, Q, may_stop, stopped, d, lo, hi)
	}
	return false
}

// `auto_frame_closed` for the root or an armed or hit level.
@(private = "file")
auto_frame_settle :: #force_no_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	$may_stop: bool,
	stopped: ^bool,
	d: int,
	lo, hi: u64,
) -> (check_stop: bool) {
	when .Path in Q {
		lv := &q.auto.levels[d]
		armed := lv.armed
		hit := lv.hit
		count := lv.idx
		decided := false
		if armed != 0 {
			// A negative `Index` is a candidate for the re-entry, or a miss if out of range. The re-entry is
			// for every mode (an index names one position). The miss is not: under `.All` a later container
			// may still match, so `finish_paths` reports it.
			need: u16 = 0
			miss: u16 = 0
			for i in 0 ..< q.n_paths {
				bit := run_bit(i)
				// A run that matched a member owes its answer to that member's chain, and an `Any` step owes nothing
				// to an empty container.
				if armed & bit == 0 || q.auto.first[d] & bit != 0 || (hit | lv.wild) & bit != 0 {
					continue
				}
				run := &q.path_runs[i]
				if run.settled || d >= len(run.steps) {
					continue
				}
				step_i, is_index := step_index(run.steps[d])
				out_of_range := true
				if is_index {
					if _, carried := run.head_pos.?; !carried && step_i < 0 {
						target := i64(count) + step_i
						if target >= 0 && u64(target) < count {
							need |= bit
							out_of_range = false
						}
					}
				}
				// Out-of-range indices and unmatched names alike. A `per_element` run owes its miss to the
				// element at hand, in every mode.
				if out_of_range && (run.mode != .All || run.each) {
					miss |= bit
				}
			}
			if need != 0 {
				refused, fault := path_reenter_from_end(s, q, d, lo, count, need)
				if e, bad := fault.?; bad && !q.reread_faulted {
					// The walk's result (`reread_verdict`): only a walk that skipped the answer can fault
					// here. It stops the walk if it can, and one that cannot runs on, keeping the first.
					q.reread_faulted = true
					q.reread_fault = e
					if stopped != nil {
						stopped^ = true
					}
				}
				if refused {
					note_oom(q, .Path)
				}
				decided = true
			}
			for i in 0 ..< q.n_paths {
				bit := run_bit(i)
				if miss & bit == 0 {
					continue
				}
				run := &q.path_runs[i]
				if run.settled {
					continue
				}
				if path_fail(q, run, d, d, .Missing, lo, .Null) {
					path_settle(run)
				}
				decided = true
			}
		}
		// Release the level once every question above has read it.
		lv.armed = 0
		lv.hit = 0
		lv.matched = 0
		lv.idx = 0
		for q.path_top > 1 && q.auto.levels[q.path_top - 1].armed == 0 && q.auto.levels[q.path_top - 1].matched == 0 {
			q.path_top -= 1
		}
		if d == 0 {
			// No stop test at the root's close, the walk's own end: an absent key reports `stop_byte = nil`.
			auto_flush_last(q, Q)
			return false
		}
		if decided && path_stop_now(q, Q, may_stop, stopped) {
			return true
		}
	}
	return false
}

// The `.Last` flush, at the root's close or when the walk faults before it: every parked candidate owned by
// the root walk becomes an answer, in run order.
auto_flush_last :: proc(q: ^Query_Ctx, $Q: bit_set[Walk_Kind]) {
	when .Path in Q {
		for i in 0 ..< q.n_paths {
			run := &q.path_runs[i]
			if !run.has_stage || !run.root_run {
				continue
			}
			run.has_stage = false
			if emit_path(run, run.stage) {
				note_oom(q, .Path)
			}
			run.settled = true
		}
	}
}

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

// The walk reached the end of the document: every run that answered nothing is a settled miss. `.Last` needs
// nothing here (flushed at the root's close).
finish_paths :: proc(
	runs: ^[MAX_PATH_QUERIES]Path_Run,
	n: int,
	$Q: bit_set[Walk_Kind],
) -> (refused: bool) {
	when .Path in Q {
		for i in 0 ..< n {
			run := &runs[i]
			// A parked candidate is an answer. A `.First`/`.Last` run that answered owes nothing, and an `.All`
			// run is discharged only by a `Found`. A wildcard run owes no miss: it answers once per match,
			// and none is a valid answer set.
			if run.settled || run.has_stage || run.wild || len(run.steps) == 0 {
				continue
			}
			if run.mode == .All {
				if run.found {
					continue
				}
			} else if run.answered {
				continue
			}
			if emit_path(run, path_answer_of(run, .Missing, 0, 0, NO_OWNER)) {
				refused = true
			}
			run.settled = true
		}
	}
	return refused
}
