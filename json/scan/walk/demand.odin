package walk

// The demand read: locate the caller's named members in the same walk that validates the document. The answer
// is a span, and `found = false` is a miss, not Null.

import "base:intrinsics"
import "base:runtime"

// One located member value. `lo`/`hi` bound the value's authored bytes in `src`.
Field_Value :: struct {
	found: bool,
	kind:  Kind,
	lo:    u64,
	hi:    u64,
}

#assert(size_of(Field_Value) == 24)

// One wanted key's row bookkeeping in row mode.
Demand_Row_Key :: struct {
	// The query index the key's rows carry.
	tag:   u32,
	// The rows after which `.First` has nothing left to read for the key, and 0 asks for every one.
	limit: u32,
	// Rows written for the key so far (`.First` only).
	count: u32,
	// The object the key last wrote a row for (`NO_OWNER` before any), and that row's index in `rows`: a
	// repeated key in the same object supersedes it (`.Last`) or is dropped (`.First`).
	owner: u64,
	row:   int,
}

// What a demand asks for and where the answers go. In slot mode (`rows == nil`) `out` must have
// `len(out) == len(keys)`: `out[i]` answers `keys[i]`, and a key named twice is answered twice.
Demand_Spec :: struct {
	keys: []string,
	out:  []Field_Value,
	// Which object depth the members are read from, counted in containers from the root: 0 and 1 both mean
	// the root object, 2 one level in, and so on. Exact depth only: matching every depth in one walk would
	// let a deeper pending overwrite a shallower one.
	depth: u64,
	// Row mode: one row per matched member, in document order, appended here and `out` left alone. A key
	// repeated within one object resolves by the call's resolution (`.Last`, `.First`, `.All`). The
	// objects of the depth each answer for themselves. Rows borrow `src`.
	rows: ^[dynamic]Path_Answer,
	// Row mode only, `len(keys)`: each key's tag and limit. The walk keeps the rest.
	row_keys: []Demand_Row_Key,
	// Row mode, read only by a walk carrying `.Gate`: the names the members above `depth` must carry, a
	// column under named members such as `.logs[].id`. Nil reads every member, as `Any` does. The caller's,
	// borrowed: the walk keeps its state there.
	gate: ^Demand_Gate,
}

// A gated demand: which depths are gated and by what name, set by the caller, and the walk's state,
// reset by `demand_gate_prepare`.
Demand_Gate :: struct {
	// Bit `d`: a member of an object at depth `d` (in `Demand_Spec.depth`'s counting) is read into only
	// when named `names[d]`. A depth without its bit reads every member.
	gated: u64,
	names: [MAX_PATH_STEPS]string,
	// Set when a `.Last` repeat of a gate's name retracted rows (`RETRACTED_TAG`), which the caller drops.
	retracted: bool,
	// Bit `d` while the walk is inside the value of a member at depth `d` that passed its gate. Clear at
	// every key of that depth: the member before it has closed, and its close clears the bit.
	open:  u64,
	// `.First`/`.Last`, per gated depth: the object whose member last passed, and the row count then,
	// where a `.Last` repeat's retraction starts.
	owner: [MAX_PATH_STEPS]u64,
	mark:  [MAX_PATH_STEPS]int,
}

// One member's pending key, held by the walk (registers) rather than by the run. `frame` is kept because it
// is not always the current frame: a container member's key is bound while its parent's frame is current, and
// the value closes one frame deeper.
Demand_Pend :: struct {
	// A matched member's value is open, and its `n_latch` is then non-zero.
	live:  bool,
	vlo:   u64,
	frame: u64,
	// The offset of the object whose member this is: the `owner` an appended `Path_Answer` names. Latched at
	// key time, not at the object's open: by the time the value closes a nested container may be open above
	// it, and "the last container that opened" would name that one.
	owner_lo: u64,
	// Which wanted keys this member's key decoded to, decided at key-read time. A key list may name the same
	// key twice, so a member can match several indices. `int`, not narrower: `keys` is not length-capped, and
	// a narrower index would wrap and answer under another key's name.
	n_latch: int,
	latch:   [LATCH_MAX]int,
}

// How many wanted-key indices one member's key can latch: the most byte-identical wanted names a demand
// holds (`names_over_capacity`).
LATCH_MAX :: 16

// Whether some wanted name occurs more than `LATCH_MAX` times, so one member's key could match more
// indices than the latch holds. Distinct names cannot decode to one member key, so repeats are the only
// way to get there. A list no longer than the latch cannot, which settles the common call by its length.
names_over_capacity :: #force_inline proc(keys: []string) -> bool {
	return len(keys) > LATCH_MAX && name_repeats_past_latch(keys)
}

@(private = "file")
name_repeats_past_latch :: #force_no_inline proc(keys: []string) -> bool {
	seen := make(map[string]int, len(keys))
	defer delete(seen)
	for k in keys {
		seen[k] += 1
		if seen[k] > LATCH_MAX {
			return true
		}
	}
	return false
}

// One demand, resolved. `keys`, `out` and the sinks are the caller's and only borrowed.
Demand_Run :: struct {
	keys: []string,
	out:  []Field_Value,

	allocator: runtime.Allocator,

	// `.First` is the only mode whose answers can be final before the item ends, so only it lets a
	// `.Lazy` walk stop. Slot mode has no `.All`: a key has one extent there.
	mode:    Resolution,
	// The depth whose object members answer (see `Demand_Spec.depth`).
	depth: u64,
	// Row mode's sink and per-key state (see `Demand_Spec`). Nil `rows` is slot mode, which writes `out`.
	rows:     ^[dynamic]Path_Answer,
	row_keys: []Demand_Row_Key,
	// Keys with nothing left to read, counted only under `.First`, where "every key is final" is the
	// condition that lets the walk stop. Under `.Last` an answer is never final until the document is,
	// so there is nothing to count.
	n_final: int,
	// Whether every key can become final, so the run can settle before the item ends: only under `.First`,
	// and only when every key has a count to reach (a slot's one extent, or a row key's limit).
	can_settle: bool,
	settled: bool,
	// The frame depths of the objects the demand reads past by an `Any` step, when `.First` or `.Last` row
	// mode must resolve their repeated keys (`demand_wild_open`): bit `sp` for each depth below `depth` that
	// a gate does not read by name. A depth past 31 is never flagged, since no demand reads that deep.
	wild_depths: u32,
	// The document the demand is reading, so the key-time match can compare without the walk threading `src`
	// through every hook. A borrow.
	src: []byte,
	// A 256-bit bitmap of the first byte of every wanted key: one load and one bit test reject most members
	// before any length or byte work.
	first_byte_bits: [4]u64,
	// With exactly one wanted key: its first `min(len, 8)` bytes as a little-endian word, and the mask that
	// keeps just those bytes of a word loaded from a member's key, so a member of the same first byte is
	// rejected without the generic compare (`demand_head_may_match`). Zero, which passes every key, for any
	// other number of keys: a test per wanted key costs a member that is wanted what it saves the rest.
	head_word: u64,
	head_mask: u64,
}

// Resolve a spec into the walk's plumbing. Zeroes `out` first: an absent key must read `found = false`,
// not whatever the caller's buffer held. `resolution` is the call's: `.First` keeps the first
// occurrence, anything else the last.
demand_prepare :: proc(
	ctx: ^Query_Ctx,
	spec: Demand_Spec,
	resolution: Resolution,
	allocator: runtime.Allocator,
) {
	r := &ctx.demand
	r.keys = spec.keys
	r.out = spec.out
	r.mode = resolution
	// `depth` 0 and 1 both mean the root object: 0 is what an omitted field gives, and the walk's `sp` for
	// the root object's members is 1.
	r.depth = spec.depth == 0 ? 1 : spec.depth
	r.rows = spec.rows
	r.row_keys = spec.row_keys
	if spec.rows != nil && resolution != .All && r.depth < 32 {
		r.wild_depths = u32(1 << r.depth) - 2
	}
	r.allocator = allocator
	if spec.rows == nil {
		assert(len(spec.out) == len(spec.keys), "a demand answers every key")
		r.can_settle = r.mode == .First
	} else {
		assert(len(spec.row_keys) == len(spec.keys), "a row demand tags every key")
		adopt_allocator(spec.rows, allocator)
		r.can_settle = r.mode == .First && len(spec.keys) > 0
		for k in spec.row_keys {
			r.can_settle &&= k.limit > 0
		}
	}
	demand_reset(r)

	n := len(spec.keys)
	if n == 0 {
		// Nothing to match, so nothing to index. `demand_key` checks the key count first.
		return
	}
	r.head_word, r.head_mask = 0, 0
	if n == 1 {
		k := spec.keys[0]
		m := min(len(k), 8)
		r.head_mask = m == 8 ? ~u64(0) : (u64(1) << (8 * uint(m))) - 1
		for j in 0 ..< m {
			r.head_word |= u64(k[j]) << (8 * uint(j))
		}
	}
	// The rest is the first-byte bitmap: no allocation.
	for i in 0 ..< n {
		if len(spec.keys[i]) > 0 {
			c := spec.keys[i][0]
			r.first_byte_bits[c >> 6] |= u64(1) << (c & 63)
		}
	}
}

// Empty a resolved demand's answers for a walk: the caller's `out` and each row key's state, which the walk
// writes.
demand_reset :: proc(r: ^Demand_Run) {
	if r.rows == nil {
		for i in 0 ..< len(r.out) {
			r.out[i] = Field_Value{}
		}
		return
	}
	for &k in r.row_keys {
		k.count = 0
		k.owner = NO_OWNER
		k.row = 0
	}
}

// Bind a gated demand's gate (`Demand_Spec.gate`) and reset its walk state, for a walk carrying `.Gate`.
demand_gate_prepare :: proc(ctx: ^Query_Ctx, spec: Demand_Spec) {
	g := spec.gate
	assert(g != nil && spec.rows != nil && g.gated >> MAX_PATH_STEPS == 0, "a gate names depths below MAX_PATH_STEPS in row mode")
	ctx.gate = g
	ctx.demand.wild_depths &~= u32(g.gated)
	demand_gate_reset(g)
}

// Empty a gate's walk state.
demand_gate_reset :: proc(g: ^Demand_Gate) {
	g.open = 0
	g.retracted = false
	for &o in g.owner {
		o = NO_OWNER
	}
}

// The kind of a value from its first authored byte.
kind_at :: #force_inline proc(src: []byte, lo: u64) -> Kind {
	if lo >= u64(len(src)) {
		return .Null
	}
	switch src[lo] {
	case 'n':
		return .Null
	case 't':
		return .True
	case 'f':
		return .False
	case '"':
		return .String
	case '[':
		return .Array
	case '{':
		return .Object
	case:
		return .Number
	}
}

// A member's key was just read and its value starts at `vlo`. `sp` is the depth of the owning object (the
// root object's members are at `sp == 1`). Identity is decided here, at key time, and latched into `pend`.
// `demand_value_closed` only records extents. Matching is decoded-text, as in `name_equals`: a key written
// `"\u006b0"` matches the wanted `k0`.
demand_key :: #force_inline proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	key_lo, key_hi, vlo, sp: u64,
	owner_lo: u64,
	pend: ^Demand_Pend,
) {
	when .Demand in Q {
		if sp == q.demand.depth && len(q.demand.keys) > 0 {
			when .Gate in Q {
				if !demand_gates_open(q) {
					return
				}
			}
			// The key's own parse already knows whether it saw a backslash.
			esc := q.key_saw_escape
			demand_key_at_depth(q, Q, key_lo, key_hi, vlo, sp, owner_lo, pend, esc, demand_key_filtered(q, key_lo, key_hi, esc))
			return
		}
		when .Gate in Q {
			// A scalar value opens its gate too: its close shuts it, and nothing below it is read.
			if demand_gated_at(q, sp) && demand_gate_passes(q, key_lo, key_hi, q.key_saw_escape, sp, owner_lo) {
				demand_gate_open(q, sp)
			}
		}
	}
}

// The object that just opened at frame depth `sp` (the root is 1): when the demand reads past it by an `Any`
// step, each repeated key of its own is one member to jq, which a `.First` or `.Last` row demand does not
// resolve, so the walk counts it for the json layer (`Scan_Query_Sink.paths_unresolved`). Depths from the
// demand's own down read it by name.
demand_wild_open :: #force_inline proc(q: ^Query_Ctx, $Q: bit_set[Walk_Kind], sp: u64, vc: u8) {
	// Without a branch: an object past the demand's depth is the common case, and a branch here moves the
	// walk's other code.
	hit := int(vc == VC_OBJECT) & int(q.demand.wild_depths & (u32(1) << sp) != 0)
	// A member the gate shuts out is read by none.
	when .Gate in Q {
		hit &= int(q.gate.gated &~ q.gate.open & (u64(1) << sp - 1) == 0)
	}
	q.path_sink.paths_unresolved += hit
}

// Whether members at depth `sp` must pass a gate.
demand_gated_at :: #force_inline proc(q: ^Query_Ctx, sp: u64) -> bool {
	return sp < MAX_PATH_STEPS && q.gate.gated & (u64(1) << sp) != 0
}

// Whether every gate is open: the walk is inside a member each gated depth let through.
demand_gates_open :: #force_inline proc(q: ^Query_Ctx) -> bool {
	return q.gate.gated &~ q.gate.open == 0
}

demand_gate_open :: #force_inline proc(q: ^Query_Ctx, sp: u64) {
	q.gate.open |= u64(1) << sp
}

// The key [key_lo, key_hi) of a member at gated depth `sp`, in the object at `owner_lo`: whether the walk
// reads into its value. A repeat of the name in one object resolves as a path's does: `.First` keeps the
// first, `.Last` retracts what the earlier ones wrote, `.All` reads every one.
demand_gate_passes :: #force_inline proc(q: ^Query_Ctx, key_lo, key_hi: u64, esc: bool, sp: u64, owner_lo: u64) -> bool {
	if !key_equals_hooked(q.hooks, q.demand.src, key_lo, key_hi, esc, q.gate.names[sp]) {
		return false
	}
	return q.demand.mode == .All || demand_gate_occurrence(q, sp, owner_lo)
}

// `demand_gate_passes` past the name match, under `.First` or `.Last`. Out of line: a gated depth holds
// few members that name its gate.
@(private = "file")
demand_gate_occurrence :: #force_no_inline proc(q: ^Query_Ctx, sp: u64, owner_lo: u64) -> bool {
	g := q.gate
	r := &q.demand
	if g.owner[sp] != owner_lo {
		g.owner[sp] = owner_lo
		g.mark[sp] = len(r.rows)
		return true
	}
	if r.mode == .First {
		return false
	}
	// Every row since the first occurrence came from under this name: a gated walk serves one gate and
	// writes no other rows.
	from := g.mark[sp]
	if from < len(r.rows) {
		for &a in r.rows^[from:] {
			a.query = RETRACTED_TAG
		}
		g.retracted = true
	}
	return true
}

// A value at depth `idx` closed: a gate it opened shuts.
demand_gate_close :: #force_inline proc(q: ^Query_Ctx, idx: u64) {
	if idx < MAX_PATH_STEPS {
		q.gate.open &~= u64(1) << idx
	}
}

// `demand_key` for a member of an object at the demand's depth, whose key `demand_key_filtered` has already
// decided: `filtered` is its answer.
demand_key_at_depth :: #force_inline proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	key_lo, key_hi, vlo, sp: u64,
	owner_lo: u64,
	pend: ^Demand_Pend,
	esc: bool,
	filtered: bool,
) -> (answers: bool) {
	when .Demand in Q {
		r := &q.demand
		// A member at the demand's exact depth is read only after the previous one's value closed, so its
		// latch is spent. Checked in debug builds only: this is the per-member hot path.
		when ODIN_DEBUG {
			assert(!(pend.live && pend.n_latch > 0), "a demand member's latch outlived its value")
		}
		n := 0
		if !filtered {
			key_text_len := key_hi - key_lo - 2
			for k, i in r.keys {
				if u64(len(k)) > key_text_len {
					continue // decoded text cannot be longer than the source text
				}
				if key_equals_hooked(q.hooks, r.src, key_lo, key_hi, esc, k) {
					// At most `LATCH_MAX` wanted names are byte-identical (`names_over_capacity`), and a key
					// matches only identical ones.
					pend.latch[n] = i
					n += 1
				}
			}
		}
		// A member no wanted key names leaves an idle slot as it found it.
		if n == 0 {
			return false
		}
		pend.live = true
		pend.vlo = vlo
		pend.frame = sp
		// The owning object's identity for the row this member writes.
		pend.owner_lo = owner_lo
		pend.n_latch = n
		return true
	}
	return false
}

// Whether the key [key_lo, key_hi) is ruled out before any compare. A span shorter than the two quotes is not
// a key. First-byte filter only when the source text is the decoded text: an escaped key's first source byte is
// the backslash, not the character it stands for.
demand_key_filtered :: #force_inline proc(q: ^Query_Ctx, key_lo, key_hi: u64, esc: bool) -> bool {
	if key_hi < key_lo + 2 {
		return true
	}
	#no_bounds_check if key_hi > key_lo + 2 && !esc {
		c := q.demand.src[key_lo + 1]
		return q.demand.first_byte_bits[c >> 6] & (u64(1) << (c & 63)) == 0 || !demand_head_may_match(q, q.demand.src, key_lo)
	}
	return false
}

// False only when the unescaped key opening at the quote `key` in `src` cannot be the one wanted key: the
// bytes after the quote differ from the wanted key's first 8 (or all of them, when it is shorter). Length is
// the compare's: a key that ends inside those bytes holds its closing quote there, so it differs from a
// wanted key without a quote, and one with a quote is left to the compare. True whenever it cannot tell,
// among them a key whose 8-byte load would leave `src`, and a demand of any other number of keys.
demand_head_may_match :: #force_inline proc(q: ^Query_Ctx, src: []u8, key: u64) -> bool {
	r := &q.demand
	#no_bounds_check {
		if key + 9 > u64(len(src)) {
			return true
		}
		w := intrinsics.unaligned_load((^u64)(raw_data(src[key + 1:])))
		return w & r.head_mask == r.head_word
	}
}

// Whether an unescaped key whose byte after the opening quote is `c` passes `demand_key_filtered`'s
// first-byte test. An empty key's `c` is its closing quote, and the test lets it through, as that one does.
demand_first_byte_wanted :: #force_inline proc(q: ^Query_Ctx, c: u8) -> bool {
	#no_bounds_check {
		return c == '"' || q.demand.first_byte_bits[c >> 6] & (u64(1) << (c & 63)) != 0
	}
}

// Whether the value starting under `sp` open frames answers the demand: it is the value of a member whose key
// matched.
demand_answers_value :: #force_inline proc(sp: u64, pend: ^Demand_Pend) -> bool {
	return pend.live && pend.frame == sp
}

// Whether a container opening under `sp` open frames could hold members at the demand's depth.
demand_reaches_into :: #force_inline proc(q: ^Query_Ctx, $Q: bit_set[Walk_Kind], sp: u64) -> bool {
	when .Gate in Q {
		return sp < q.demand.depth && (!demand_gated_at(q, sp) || q.gate.open & (u64(1) << sp) != 0)
	} else {
		return sp < q.demand.depth
	}
}

// The pending member's value closed at `s.pos`. One match per member, run here because the value's extent —
// half the answer — does not exist until now.
demand_value_closed :: #force_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	idx: u64,
	pend: ^Demand_Pend,
	$may_stop: bool,
	stopped: ^bool,
) {
	when .Demand in Q {
		when .Gate in Q {
			demand_gate_close(q, idx)
		}
		if !pend.live || pend.frame != idx {
			return
		}
		pend.live = false
		if q.demand.rows != nil {
			demand_rows_closed(s, q, Q, pend, may_stop, stopped)
			return
		}
		vlo := pend.vlo
		vhi := s.pos
		kind := kind_at(s.src, vlo)
		for i in 0 ..< pend.n_latch {
			demand_record(q, Q, int(pend.latch[i]), kind, vlo, vhi, may_stop, stopped)
		}
	}
}

// The row-mode answers of a matched member whose value just closed. Out of line: the slot reader is the
// hot one, and a row body inlined at every close site of the walk costs the loop it sits in.
@(private = "file")
demand_rows_closed :: #force_no_inline proc(
	s: ^Scanner,
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	pend: ^Demand_Pend,
	$may_stop: bool,
	stopped: ^bool,
) {
	vlo := pend.vlo
	vhi := s.pos
	kind := kind_at(s.src, vlo)
	for i in 0 ..< pend.n_latch {
		demand_record_row(q, Q, int(pend.latch[i]), kind, vlo, vhi, pend.owner_lo, may_stop, stopped)
	}
}

// One matched answer in row mode, appended instead of overwriting the K-sized `out`. `owner` is the owning
// object's offset (`Demand_Pend.owner_lo`). An object's members are read before any other object of the
// same depth opens, so a key repeated within an object meets its own earlier row through `Demand_Row_Key`.
@(private = "file")
demand_record_row :: #force_inline proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	i: int,
	kind: Kind,
	vlo, vhi: u64,
	owner: u64,
	$may_stop: bool,
	stopped: ^bool,
) {
	r := &q.demand
	k := &r.row_keys[i]
	answer := Path_Answer{lo = vlo, hi = vhi, owner = owner, query = k.tag, node = NO_NODE, outcome = .Found, kind = kind}
	if r.mode != .All {
		if k.owner == owner {
			if r.mode == .Last {
				r.rows[k.row] = answer
			}
			return
		}
		k.row = len(r.rows)
	}
	// Under `.All` too: a key still at `NO_OWNER` after the walk matched nothing (`route_missing`).
	k.owner = owner
	if !row_append(r.rows, answer) {
		// Refused: the row is lost, and the next repeat in this object must not supersede a stranger.
		note_oom(q, .Path)
		k.owner = NO_OWNER
		return
	}
	when may_stop {
		if stopped != nil && r.mode == .First {
			k.count += 1
			if k.count == k.limit {
				r.n_final += 1
				if r.n_final == len(r.keys) {
					r.settled = true
					path_stop_now(q, Q, true, stopped)
				}
			}
		}
	}
}

// One matched answer. This is the only place an answer is written. `.Last` and `.All` overwrite, since a slot holds
// one extent, and are never final early. `.First` keeps the first occurrence and settles the run once every
// key has an answer, so a `.Lazy` walk can stop. The walk stops only once every run in the call has settled
// (`call_settled`).
//
// Slot mode only. Row mode appends instead (`demand_record_row`).
demand_record :: #force_inline proc(
	q: ^Query_Ctx,
	$Q: bit_set[Walk_Kind],
	i: int,
	kind: Kind,
	vlo, vhi: u64,
	$may_stop: bool,
	stopped: ^bool,
) {
	r := &q.demand
	if r.mode == .First {
		if r.out[i].found {
			return
		}
		r.n_final += 1
	}
	r.out[i] = Field_Value{found = true, kind = kind, lo = vlo, hi = vhi}
	if r.mode == .First && r.n_final == len(r.keys) {
		r.settled = true
		r.depth = 0
		when may_stop {
			if stopped != nil {
				path_stop_now(q, Q, true, stopped)
			}
		}
	}
}
