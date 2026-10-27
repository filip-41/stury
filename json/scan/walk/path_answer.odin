package walk

import core_pkg "../../../core"

// How a path query landed: core's `Answer_Outcome`, shared with every format's answer.
Path_Outcome :: core_pkg.Answer_Outcome

// "No container": `Answer.owner` of an answer no single container holds.
NO_OWNER :: core_pkg.NO_OWNER

// The `query` of a retracted answer (`path_supersede`, a gated `.Last` repeat), which the caller drops.
RETRACTED_TAG :: max(u32)

// One path query's answer: core's `Answer`. Queries may share a sink, so the answers are every query's, in walk
// order. A miss owed to the document as a whole has `NO_OWNER` (`.All` reports its miss once the walk has ended).
Answer :: core_pkg.Answer

// The most runs the path automaton may carry in one scan (a fixed array, since the walk allocates
// nothing). More are refused before the walk (`Over_Capacity`, `Path_Runs`). Paths the demand matcher
// serves take no run.
MAX_PATH_QUERIES :: 16

// How many member starts each level remembers (`Query_Ctx.member_starts`): one per group of a stride's
// members (`Path_Auto.ring_shift`), the group's latest, for the last `MEMBER_RING` groups. The level's
// deepest negative `Index` sizes the stride, so its re-read resumes within one stride of the member it
// names. A power of two.
MEMBER_RING :: 8
#assert(MEMBER_RING & (MEMBER_RING - 1) == 0)

// One step index's state (the level is the step index). Armed for one container at
// a time (`frames[d]`) and cleared when it closes, so no stack is needed.
Auto_Level :: struct {
	// Runs whose step `d` applies to `frames[d]`'s members. The early-out: one
	// u16 test per member.
	armed: u16,
	// Runs the member being read matched, by name or ordinal. Consumed by
	// `auto_member_closed`, where the value's extent is known.
	matched: u16,
	// Runs that matched some member of this container instance. A close's miss is
	// `armed & ~(hit | first)`.
	hit: u16,
	// Runs whose step `d` is `Any`: set when the path is bound, never cleared. Such a run matches every
	// member and owes no miss.
	wild: u16,
	// This container's member ordinal, bumped in `auto_member_open` (also by the
	// fused `[` loop). Nonzero at level 0 when a walk starts, it is the re-entry's
	// resume point: the walk begins inside its root array, that many members in
	// (`path_reenter_from_end`).
	idx: u64,
}

#assert(size_of(Auto_Level) == 16)

// The automaton: one level per step index, plus `.First`'s per-level memory.
//
// `first` outlives `Auto_Level.hit`: it is the walk-long memory that a `.First`
// run already took its occurrence at step `d`, even for a later container at that level.
//
// `ends[d]` holds the runs whose last step is `d`: set when the path is bound, never cleared.
//
// `owners[d]` is the `{` or `[` offset of the container `levels[d]` is armed for: set when that container
// opens, read when an answer names its holder.
//
// `ring_shift[d]` is log2 of the stride by which level `d` groups member starts (`MEMBER_RING`): set when
// the path is bound, from the deepest negative `Index` at `d`, so `-K` keeps a start within `K / 6` members.
//
// `reread_end` is, in a negative `Index`'s re-read, one past the last ordinal it names: its walk stops when
// that member closes, as nothing after it can answer (`path_reenter_from_end`). Zero in every other walk.
Path_Auto :: struct {
	levels:     [MAX_PATH_STEPS]Auto_Level,
	first:      [MAX_PATH_STEPS]u16,
	ends:       [MAX_PATH_STEPS]u16,
	owners:     [MAX_PATH_STEPS]u64,
	reread_end: u64,
	ring_shift: [MAX_PATH_STEPS]u8,
}

// Fixed size, independent of document depth and path length.
#assert(size_of(Path_Auto) == 936)

// One path query's resolution state while the walk runs.
Path_Run :: struct {
	sink:  ^[dynamic]Answer,
	query: u32,
	steps: []Step,
	mode:  Resolution,

	settled: bool, // no further matching is needed, so the answer is final
	// The run produced an answer of any kind (`answered`) / a `Found` (`found`).
	// `finish_paths` retires `.First`/`.Last` by `answered` (a mismatch is its
	// answer) and `.All` by `found`.
	answered: bool,
	found:    bool,

	// `.Last` on a `Name` step: one candidate slot, overwritten by each later
	// occurrence, so `.Last` emits exactly one answer.
	stage:      Answer,
	has_stage:  bool,
	// True for the runs the root walk owns. A re-entry's sub-runs are `false`, and
	// their owner copies them back (see `path_reenter_from_end`).
	root_run:   bool,

	// The path has an `Any` step: it answers once per match and never owes a `Missing` or a
	// `Type_Mismatch` (a branch that does not match yields nothing), unless `each`. `limit` is the
	// `Path.limit`. `emitted` counts the answers written, which a wildcard run settles on at its limit.
	wild:    bool,
	// `Path.per_element`, on a path with an `Any` step: every element answers, a miss or mismatch too
	// (`path_fail`), and each answer counts toward `limit`.
	each:    bool,
	limit:   int,
	emitted: int,

	// A negative `Index` resolves only once the array has closed. The re-entry
	// carries the absolute position here. It is consumed by the step it was made
	// for (the re-read's step 0, in `auto_member_open`): a stale carry would
	// shadow every negative `Index` below it, so `[-1][-1]` would answer Missing.
	head_pos: Maybe(u64),
	// A re-entry's sub-run starts at the step it was made for: whether a `Name` came before it, which
	// a `.Last` answer must wait out as if the steps were still there.
	named_prefix: bool,
}

// Which arm a step names. `Step` is `#no_nil` with `Name` first, so a zero
// step is `Name("")` and not a nil to test.
step_name :: #force_inline proc(st: Step) -> (name: string, ok: bool) {
	if n, is := st.(Name); is {
		return string(n), true
	}
	return "", false
}

step_index :: #force_inline proc(st: Step) -> (idx: i64, ok: bool) {
	if x, is := st.(Index); is {
		return i64(x), true
	}
	return 0, false
}

// The answer a run reports. A `Found` carries the kind its emitter read at `lo`. `node` is the request
// layer's to stamp, as the walk does not know the node rows.
path_answer_of :: #force_inline proc(run: ^Path_Run, outcome: Path_Outcome, lo, hi, owner: u64, kind := Kind.Null) -> Answer {
	return Answer{lo = lo, hi = hi, owner = owner, query = run.query, node = NO_NODE, outcome = outcome, kind = kind}
}

// One answer, appended to the run's own sink: one store while it has room. Returns the refusal for the
// caller to record, rather than taking `^Query_Ctx`.
emit_path :: #force_inline proc(run: ^Path_Run, answer: Answer) -> (refused: bool) {
	return !row_append(run.sink, answer)
}

// The one answer site. A `.Last` answer a later occurrence could supersede is
// parked in `Path_Run.stage` until the root closes. Every other answer goes
// straight to the sink. Returns whether the answer was final, so the caller may settle the run: a
// wildcard run is never settled by an answer (see `path_answer_wild`).
path_answer :: proc(
	q: ^Query_Ctx,
	run: ^Path_Run,
	d: int,
	outcome: Path_Outcome,
	lo, hi, owner: u64,
	kind := Kind.Null,
) -> (final: bool) {
	if run.wild {
		path_answer_wild(q, run, outcome, lo, hi, owner, kind)
		return false
	}
	answer := path_answer_of(run, outcome, lo, hi, owner, kind)
	run.answered = true
	if outcome == .Found {
		run.found = true
	}
	if run.mode == .Last && !path_prefix_is_deterministic(run, d) {
		run.stage = answer
		run.has_stage = true
		return false
	}
	if emit_path(run, answer) {
		note_oom(q, .Path)
	}
	return true
}

// A wildcard run's answer. A `Found` goes straight to the sink, in document order. A repeated key's
// supersession is `path_supersede`'s. Any other outcome yields nothing, but for a `per_element` run, whose
// answer it is (`path_fail`, at the root, where step 0 does not apply, always `.Type_Mismatch`, as the path
// holds an `Any`). The run settles only at its limit, and only when no later key could supersede what it wrote.
@(private)
path_answer_wild :: #force_inline proc(
	q: ^Query_Ctx,
	run: ^Path_Run,
	outcome: Path_Outcome,
	lo, hi, owner: u64,
	kind: Kind,
) {
	if outcome != .Found && !run.each {
		return
	}
	if emit_path(run, path_answer_of(run, outcome, lo, hi, owner, kind)) {
		note_oom(q, .Path)
	}
	run.emitted += 1
	if run.limit > 0 && run.emitted >= run.limit && path_run_may_settle_early(run) {
		run.settled = true
	}
}

// Step `fail` of `run` does not apply: it names no member or element of its container (`.Missing`), or it met
// a value of another kind, `met` (`.Type_Mismatch`). `d` and `owner` are as for `path_answer`. Returns whether the
// answer was final. A wildcard run yields nothing here, unless `per_element`, where the answer is what jq
// outputs for the element (`per_element_outcome`).
@(private)
path_fail :: proc(q: ^Query_Ctx, run: ^Path_Run, d, fail: int, outcome: Path_Outcome, owner: u64, met: Kind) -> (final: bool) {
	if !run.wild {
		return path_answer(q, run, d, outcome, 0, 0, owner)
	}
	if run.each {
		path_answer_wild(q, run, per_element_outcome(run.steps[fail:], outcome == .Missing, met), 0, 0, owner, .Null)
	}
	return false
}

// A `per_element` path's answer where step `rest[0]` does not apply, having `missed` its member or element or
// met a `met`: `.Missing`, jq's null, when no `Any` step is still to come and it missed or met null, else
// `.Type_Mismatch`, jq's error.
per_element_outcome :: proc(rest: []Step, missed: bool, met: Kind) -> Path_Outcome {
	return .Missing if (missed || met == .Null) && !steps_have_any(rest) else .Type_Mismatch
}

// Retract the answers `run` wrote from sink row `from` on: a key repeated within one object resolves to its
// last occurrence, which supersedes whatever the earlier ones produced. The rows stay where they are, as
// `RETRACTED_TAG` rows the json layer drops: the sink is shared, and the demand matcher holds indices into it.
@(private)
path_supersede :: proc(run: ^Path_Run, from: int) {
	for &a in run.sink^[from:] {
		if a.query == run.query {
			a.query = RETRACTED_TAG
		}
	}
}

// Settle the run after a final answer. Every mode but `.All` is final once it
// has an answer. `.All` is still owed the later occurrences.
@(private)
path_settle :: #force_inline proc(run: ^Path_Run) {
	if run.mode != .All {
		run.settled = true
	}
}

// A `Type_Mismatch` at depth `d`, step `fail` meeting a `met`, owned by the container at `owner`, settling the
// run if it was final.
@(private)
path_mismatch :: #force_inline proc(q: ^Query_Ctx, run: ^Path_Run, d, fail: int, owner: u64, met: Kind) {
	if path_fail(q, run, d, fail, .Type_Mismatch, owner, met) {
		path_settle(run)
	}
}

// Whether a `.Last` answer at step `d` is final, or could be superseded and so
// must be parked. A `Name` step's winner is known only when its container closes,
// so the answer is final only when steps 0 through `d` are all `Index`, because otherwise
// `{"results":[10,20,30],"results":{"results":[1]}}` under `results[1]` + `.Last`
// would settle on the first occurrence's `20`.
@(private = "file")
path_prefix_is_deterministic :: #force_inline proc(run: ^Path_Run, d: int) -> bool {
	if run.named_prefix {
		return false
	}
	for i in 0 ..= d {
		if i >= len(run.steps) {
			return false
		}
		if _, is_index := step_index(run.steps[i]); !is_index {
			return false
		}
	}
	return true
}

// Whether some step of the run is a `Name`, whose repeats a `.Last` run must wait out.
@(private = "file")
path_has_name :: proc(run: ^Path_Run) -> bool {
	return run.named_prefix || steps_have_name(run.steps)
}

@(private)
steps_have_name :: proc(steps: []Step) -> bool {
	for st in steps {
		if _, is_name := step_name(st); is_name {
			return true
		}
	}
	return false
}

steps_have_any :: proc(steps: []Step) -> bool {
	for st in steps {
		if _, is_any := st.(Any); is_any {
			return true
		}
	}
	return false
}

// Whether this run can settle before the item ends. It must agree with how a
// match binds, or the stop test fires on a promise the run cannot keep.
//
// `.First` settles at its first match. `.Last` with a `Name` step anywhere cannot (the last
// occurrence wins, `path_prefix_is_deterministic`). On `Index` steps alone it can, since one
// position has one candidate. `.All` never can. An empty path settles with the walk.
path_run_may_settle_early :: #force_inline proc(run: ^Path_Run) -> bool {
	if len(run.steps) == 0 {
		return false
	}
	// A wildcard run is owed every match, so only its limit settles it: and then only if each answer it
	// wrote is final, which a `.Last` run with a `Name` step cannot promise.
	if run.wild {
		return run.limit > 0 && (run.mode != .Last || !path_has_name(run))
	}
	if run.mode == .First {
		return true
	}
	return run.mode == .Last && !path_has_name(run)
}

// Stop once every query in this call has settled (`call_settled`). `$may_stop` is
// false for every termination but `.First_Wins_May_Stop`. The offset a stop reports
// is `s.pos` where the answer was decided: the matched value's own close.
path_stop_now :: #force_inline proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	$may_stop: bool,
	stopped: ^bool,
) -> bool {
	when may_stop {
		if stopped == nil {
			return false
		}
		if !call_settled(q, Q) {
			return false
		}
		stopped^ = true
		return true
	}
	return false
}

@(private)
run_bit :: #force_inline proc(i: int) -> u16 {
	return u16(1) << u16(i)
}
