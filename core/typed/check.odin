package typed

import "base:runtime"
import "core:mem"
import "core:strconv"
import "core:strings"
import regex "../regex"
import spell "../spell"
import core ".."
import rules "../rules"

// A read that reports every refusal to its sink as a `core.Error_Entry` with the full path, a `Reader` with the hook the
// checks of a model add to. `check_start` starts one.
Check :: struct {
	using reader: Reader,
	// The keyword steps a failure's path takes after its value's use site, before the rule's keyword.
	after:        []core.Step,
	// The run of an arm this check is, nil for the outermost check, the held value open in it, and the runs it shares.
	run:          ^Run,
	fork:         ^Fork,
	pool:         ^Pool,
	// The held containers a run took over, innermost first.
	taken:        ^Fork,
	// The held values this check's value is judged by one inside the other, which `MAX_HELD` bounds, and where the
	// outermost check's held value opened on the machine stack, which `STACK_BUDGET` bounds the runs below.
	nest:         int,
	stack:        uintptr,
	// What stopped the check past its sink, which stops the checks it is an arm of.
	fatal:        core.Typed_Error_Kind,
	// What the path and the keyword path of the outermost check's entries start with, nil for none.
	outer:        ^Outer,
	// How a key that repeats in its object is met.
	repeats:      Repeats,
	// The sink's entries below this are an earlier record's, which a repeat never takes back.
	floor:        int,
	// The keys of the open objects that track them, outermost first: the first `tracked` of `trackers` are in use. The
	// trackers and what they hold are in the temp allocator and are reused, so a long text does not grow them.
	trackers:     [dynamic]Tracker,
	tracked:      int,
	// Where the check keeps the reading of each `Plain` value, nil for a check that keeps none.
	readings:     ^Readings,
	// The open containers of judged types, outermost first, in the temp allocator.
	opens:        [dynamic]Judged_Open,
}

// A judged type's container open at frame `sp`, whose text starts at `lo` and whose record's `Meta` is `m`.
@(private)
Judged_Open :: struct {
	sp: int,
	lo: u64,
	m:  ^Meta,
}

// The kinds a check read its `Plain` values as, each by the value's first byte: where arms read a value apart, the reading
// of the arm the check decides. A later reading of a byte replaces an earlier one. `short` says one could not be kept.
Readings :: struct {
	read:  [dynamic]Reading,
	short: bool,
}

@(private)
Reading :: struct {
	lo:   u64,
	kind: core.Kind,
}

// The keys an open object has met, for a check that meets repeats. `sp` is the object's frame.
@(private)
Tracker :: struct {
	sp:      int,
	// Each key's text in the order met, and past `SEEN_SCAN` keys the index of each by its text.
	names:   [dynamic]string,
	keys:    map[string]int,
	// The source span of each key's latest member, from its key to the next key, whose end is `open`'s until the next key.
	spans:   [dynamic][2]u64,
	open:    int,
	// How many of the object's members repeat an earlier key.
	repeats: u64,
}

// The path to a value inside a larger one and the keyword steps to the subschema it is judged by, which a check of that
// value starts its entries' paths with.
Outer :: struct {
	path, words: []core.Step,
}

@(private)
@(rodata)
KEYS := [1]core.Step{core.Name("propertyNames")}

// A format's read of a whole text into `target`, a value of `plan`'s type `T`, under the handle `as`.
Text_Read :: #type proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^Plan, read: Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal

// A format's read of a node of a built document into `target`.
Node_Read :: #type proc(doc: ^core.Document, node: core.Node_Index, T: typeid, target: rawptr, plan: ^Plan, read: Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal

// What a format reads typed values with, where its `Services.reads` points. A plan copies the procedures. `check` and
// `node_check` are the reads that report to a `Sink`'s `entries`, nil for a format that has none. `plan` builds the plan
// of a type that reads with these reads and writes the format, nil for reads that build none.
Format_Reads :: struct {
	read, check:           Text_Read,
	node_read, node_check: Node_Read,
	build:                 Text_Build,
	plan:                  proc(T: typeid, opts: Plan_Options, allocator: runtime.Allocator) -> (Plan, core.Typed_Refusal),
	// The read of a replacement a member's `before` answered, nil for a format that reads none.
	replace:               Replacement_Read,
	// The format's `^records.Record_Docs` holding the checks of records, which a model's read of records and a check of
	// records take. Nil for reads that give none.
	docs:                  proc "contextless" () -> rawptr,
}

// A format's typed reads with the checks of a model and of a description, and the layout their plans read and write by,
// as `json.checks(.Json)` and `dsv.checks(.Csv, opts)` give them. A layout with no readers is the plan's own.
Format_Checks :: struct {
	reads:  ^Format_Reads,
	layout: core.As,
}

// Builds `src` as a document of the format `as` names, as a format's `Format_Reads` does for `write.marshal_value`.
Text_Build :: #type proc(src: []u8, as: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error)

// Starts a `Check` read, as `read_start` starts a read of the plan's own type. Its sink takes `core.Error_Entry`s.
check_start :: proc(c: ^Check, src: []u8, plan: ^Plan, as: core.As, T: typeid, target: rawptr, read: Read_Options, frames: []Frame, allocator: runtime.Allocator) -> (regs: core.Hook_Regs, err: core.Typed_Refusal) {
	regs, err = read_start(&c.reader, src, plan, as, T, target, read, frames, allocator)
	c.wide, c.outer, c.readings = true, read.outer, read.readings
	// A text read under `.Refuse` was refused whole for any repeat, so the check meets none.
	c.repeats, c.tracked, c.floor = .Ignore if read.dups == .Refuse else read.repeats, 0, len(read.sink.entries) if read.sink != nil else 0
	if k := read.checker; k != nil {
		// A check of records gives back what each record took from the temp allocator, and the checker's runs and
		// forks serve every record, so they are never made with the temp allocator.
		if k.pool.allocator.procedure == nil {
			k.pool.allocator = context.allocator if context.allocator.procedure != context.temp_allocator.procedure else runtime.heap_allocator()
		}
		// `pool_begin` gives back every run and fork, so the held value an earlier record stopped in, whose arms that
		// record's temp memory held, is not read.
		pool_begin(&k.pool)
		// The checker outlives the check and its pool holds only the runs and forks it made, never the check's own
		// memory. The cast keeps the compiler's escape check from taking a store into the pool for an escape.
		c.pool, c.fork, c.taken = (^Pool)(rawptr(&k.pool)), nil, nil
	} else if c.fork != nil && c.fork.open {
		// A check started again over its own pool gives back the held value it stopped in.
		fork_release(c, c.fork)
	}
	if c.pool != nil {
		c.pool.repeating, c.pool.leads, c.pool.begun, c.pool.verdicts = nil, nil, c.pool.opened, {}
	}
	return
}

// Reads `src` into `target` as the plan's format does, `.Plan_Mismatch` when the plan has no read.
unmarshal_text :: proc(src: []u8, target: rawptr, T: typeid, plan: ^Plan, read: Read_Options, allocator := context.allocator) -> core.Error {
	if plan == nil || plan.read == nil {
		return core.error_of(plan_mismatch(plan, nil, T))
	}
	return core.error_of(plan.read(src, plan.as, target, T, plan, read, allocator))
}

// Reads `src` into `target` as `unmarshal_text` does, with every refusal in `read.sink.entries`. Returns the first.
check_text :: proc(src: []u8, target: rawptr, T: typeid, plan: ^Plan, read: Read_Options, allocator := context.allocator) -> core.Error {
	return check_by(src, handle_of(plan), target, T, plan, read, allocator, plan.check if plan != nil else nil)
}

// Reads `src` into `target` by `plan` through `check`, a format's check of the handle `as`, with the entries it adds in
// the order `check_text` gives them. A nil plan or check is `.Plan_Mismatch`.
check_by :: proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^Plan, read: Read_Options, allocator: runtime.Allocator, check: proc(src: []u8, as: core.As, target: rawptr, T: typeid, plan: ^Plan, read: Read_Options, allocator: runtime.Allocator) -> core.Typed_Refusal) -> core.Error {
	if plan == nil || check == nil {
		return core.error_of(plan_mismatch(plan, nil, T))
	}
	from := len(read.sink.entries) if read.sink != nil else 0
	refused := check(src, as, target, T, plan, read, allocator)
	order_entries(read.sink, from)
	return core.error_of(refused)
}

// The handle `plan` reads by, or the zero handle for a nil plan, which a read refuses before it reads.
handle_of :: proc "contextless" (plan: ^Plan) -> core.As {
	return plan.as if plan != nil else {}
}

// Whether the keys of an object at record `owner`'s use reach `check_key` whatever the cursor predicts: the object's names are
// judged, or a check that judges repeats needs every key, on a block that ends in the `Never` record.
@(private)
keyed :: #force_inline proc "contextless" (h: ^Check, m: ^Meta, u: ^Use) -> bool #no_bounds_check {
	return u.keys != 0 || h.repeats == .Judge && h.plan.fields[m.block + m.members].kind == .Never
}

// Whether the frame `f` is the open object whose keys the innermost tracker holds.
@(private)
tracks :: #force_inline proc "contextless" (h: ^Check, f: ^Frame) -> bool {
	return h.tracked > 0 && h.trackers[h.tracked - 1].sp == int((uintptr(f) - uintptr(h.frames)) / size_of(Frame))
}

// Starts tracking the keys of the object just opened at frame `h.sp - 1`. A check that notices tracks only an object
// whose verdict a repeat of an unnamed key can change: a count, a rule for the members no record names, or names to judge.
// A pattern's member needs it only with a sink, as with none its failure ends the read, which then reads again judging.
@(cold)
@(private)
track_open :: #force_no_inline proc "contextless" (h: ^Check, m: ^Meta, u: ^Use, l: ^rules.Leaf) {
	if h.repeats == .Judge {
		if !keyed(h, m, u) {
			return
		}
	} else if u.additional == 0 && (u.pattern == 0 || h.sink == nil) && u.keys == 0 && !(l != nil && (l.min_members > 0 || l.max_members < max(u64))) {
		return
	} else if h.sp == 2 && h.run != nil && h.run.step == nil {
		// A run of a whole held object leaves its keys to the fork, which notices a repeat among them.
		return
	}
	context = h.ctx
	context.allocator = context.temp_allocator
	if h.tracked == len(h.trackers) {
		if _, grown := append(&h.trackers, Tracker{}); grown != nil {
			return
		}
	}
	t := &h.trackers[h.tracked]
	h.tracked += 1
	clear(&t.names)
	if len(t.keys) > 0 {
		clear(&t.keys)
	}
	clear(&t.spans)
	t.sp, t.open, t.repeats = h.sp - 1, -1, 0
}

// What a key met by a tracker leaves to do.
@(private)
Key_Met :: enum {
	New,
	Skip,
	Stop,
}

// Notes the key `t`, whose text is `key`, in the object `tr` tracks. A repeat ends the read when it is to notice one. It
// takes back the errors of the earlier value under `.Last`, and under `.First` is skipped. Either is one member fewer.
@(cold)
@(private)
track_key :: #force_no_inline proc "contextless" (h: ^Check, tr: ^Tracker, t: core.Token, key: string) -> Key_Met {
	context = h.ctx
	context.allocator = context.temp_allocator
	lo, _ := check_ends(h, t)
	if tr.open >= 0 {
		tr.spans[tr.open][1] = lo
	}
	at := names_find(tr.names[:], &tr.keys, key)
	if at < 0 {
		text := key
		// A key decoded into the caller's buffer outlives it here, one read from the source stays a view of it.
		if !within(h.src, key) {
			cloned: runtime.Allocator_Error
			if text, cloned = strings.clone(key); cloned != nil {
				return .Stop
			}
		}
		_, named := append(&tr.names, text)
		_, grown := append(&tr.spans, [2]u64{lo, 0})
		if named != nil || grown != nil {
			return .Stop
		}
		names_index(tr.names[:], &tr.keys)
		tr.open = len(tr.spans) - 1
		return .New
	}
	if h.repeats == .Notice {
		noticed(h, t)
		return .Stop
	}
	tr.repeats += 1
	if h.first_key {
		tr.open = -1
		return .Skip
	}
	take_back(h, tr.spans[at])
	tr.spans[at] = {lo, 0}
	tr.open = at
	return .New
}

// Whether a check that notices repeats must see one of a member read before that a later key of the object at `m` could
// bring by its bytes, which the cursor matches without a call: the object's count, or a sink's entries, which a repeat under
// `.First` skips and one under `.Last` takes back from those already there. The value of a repeat failing in a read with no
// sink ends it with the object open, which reads again judging repeats, and a check judging them sees every key.
@(private)
repeat_may_count :: #force_inline proc "contextless" (h: ^Check, m: ^Meta) -> bool {
	return m.counted || h.sink != nil && (h.first_key || len(h.sink.entries) > h.floor)
}

// Ends the read at the repeated key `t` with the refusal a caller that reads again with `.Judge` looks for.
@(cold)
@(private)
noticed :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token) -> core.Action {
	h.first = {kind = .Duplicate_Key, at = t.lo}
	return .Stop
}

// Takes back the entries of this read that start inside `span`, or with `member` those whose path starts with it, the
// member a later value of its key replaces.
@(cold)
@(private)
take_back :: proc "contextless" (h: ^Check, span: [2]u64, member: []core.Step = nil) {
	c := h.sink
	if c == nil {
		return
	}
	context = h.ctx
	kept := h.floor
	for i in h.floor ..< len(c.entries) {
		e := &c.entries[i]
		if member == nil && e.start >= span[0] && e.start < span[1] || member != nil && path_within(e.path, member, h.outer) {
			entry_destroy(e, c.entries.allocator)
		} else {
			c.entries[kept] = e^
			kept += 1
		}
	}
	taken := kept < len(c.entries)
	resize(&c.entries, kept)
	// A check whose run reports to its sink holds the run's first refusal as its own, which goes back with the run's.
	for x := h; ; x = x.run.parent {
		first_taken_back(x, c, span, taken)
		if x.run == nil || x.run.parent.sink != c {
			break
		}
	}
}

// Whether `path`, an entry's, is of the value at `member`, a path below the check's outer one.
@(private)
path_within :: proc "contextless" (path, member: []core.Step, outer: ^Outer) -> bool {
	from := len(outer.path) if outer != nil else 0
	if len(path) < from + len(member) {
		return false
	}
	for s, i in member {
		if path[from + i] != s {
			return false
		}
	}
	return true
}

// A key that repeats in the open struct of a check that minds repeats, the struct of record `owner` at frame `f`, whose
// member `i` it names. Noticing, it ends the read for the caller to read again judging. Judging, a repeat under `.First`
// is skipped, and one under `.Last` takes back the entries of the earlier value and replaces it. Past it the cursor
// matches no key by its bytes, so each later key of the struct comes here.
@(cold)
@(private)
repeat_member :: #force_no_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token, f: ^Frame, owner: ^Field, i: int) -> (core.Hook_Regs, core.Action) {
	if h.repeats == .Notice {
		return regs, noticed(h, t)
	}
	regs := regs
	at := ([^]Field)(owner.first)
	regs.b = u64(uintptr(&h.plan.solo[2 * (int(uintptr(&at[i]) - uintptr(raw_data(h.plan.fields))) / size_of(Field)) + 1]))
	if h.first_key {
		return regs, .Skip
	}
	context = h.ctx
	take_back(h, {}, member_steps(h, {regs.a, u64(uintptr(&at[i + 1])), regs.c}))
	dest := uintptr(regs.c) + uintptr(at[i].offset)
	if at[i].kind == .String {
		release_text(h, dest)
	} else {
		mem.zero(rawptr(dest), int(h.plan.meta[at[i].meta].size))
	}
	return regs, .Next
}

// Settles the first refusal of the check `x`, which reads into `c`, after `take_back` took back the entries inside `span`,
// `taken` saying whether there were any. A read that shares its sink finds the entries another took back gone, and its
// first refusal with them.
@(private)
first_taken_back :: proc "contextless" (x: ^Check, c: ^Sink, span: [2]u64, taken: bool) {
	if !taken && (x.first.kind == .None || x.first.at < span[0] || x.first.at >= span[1]) {
		return
	}
	// What the read first refused is taken back with it, unless a limit left an entry out.
	if len(c.entries) == x.floor && !c.truncated {
		x.first = {}
	} else if len(c.entries) > x.floor {
		x.first = {kind = c.entries[x.floor].kind, at = c.entries[x.floor].start}
	}
}

// The value `t` at a `Checked` record: judges a scalar by the record's leaf, and opens a container a rule reads inside,
// which its close judges, so a container's failure spans it. A container's frame keeps its open byte in `data` and its
// kind, and an object's frame its last key's span and spelling in `owner` and `target`. `c` counts the values of the
// open container.
@(private)
check_value :: #force_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	fld := field_at(regs.b)
	m, u := &h.plan.meta[fld.meta], &h.plan.uses[fld.meta]
	next := core.Hook_Regs{regs.a, regs.b + (size_of(Field) if u.step else 0), regs.c + 1}
	l: ^rules.Leaf
	if m.rule_set > 0 {
		l = &h.plan.leaves[m.rule_set - 1]
	}
	first: ^Field
	#partial switch t.kind {
	case .Object:
		if m.members > 0 || u.additional != 0 || u.pattern != 0 || u.keys != 0 || l != nil && (l.min_members > 0 || l.max_members < max(u64) || container_fails(l, .Object) != {}) {
			// The block's `Never` record predicts no key, so each key reaches `check_key` and its name rules.
			first = &h.plan.fields[m.block + m.members] if keyed(h, m, u) else fld.first
		}
	case .Array:
		if u.inside || l != nil && (l.min_items > 0 || l.max_items < max(u64) || container_fails(l, .Array) != {}) {
			first = &h.plan.fields[u.items]
		}
	case:
		if l != nil {
			value := t
			if t.kind == .Plain {
				value = plain_token(h, t, l)
				if h.readings != nil {
					reading_keep(h, t.lo, value.kind)
				}
			}
			if judge_value(h, regs, value, l) == .Stop {
				return next, .Stop
			}
		} else if len(u.applies) > 0 {
			return fork_value(h, regs, next, u, t)
		}
		return next, .Next
	}
	if first == nil {
		if len(u.applies) > 0 {
			return fork_value(h, regs, next, u, t)
		}
		return next, .Skip
	}
	f := frame_push(h, regs, t)
	if t.kind == .Object {
		if keyed(h, m, u) {
			// The cursor starts past every member, which it passed unread, so the members are tracked from here by their keys.
			f.seen, f.run = SEEN_ON, first
		}
		if h.repeats != .Ignore && len(u.applies) == 0 {
			track_open(h, m, u, l)
		}
	}
	return {NO_LIMIT, u64(uintptr(first)), 0}, .Next
}

// Opens the frame of the container `t` opens, which the value at the registers `regs` holds.
@(private)
frame_push :: #force_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token) -> ^Frame {
	f := &h.frames[h.sp]
	h.sp += 1
	f.a, f.b, f.c, f.seen, f.run, f.extra = regs.a, regs.b, regs.c, 0, nil, nil
	lo, _ := value_ends(h, t)
	f.data, f.kind, f.owner, f.target = rawptr(uintptr(lo)), t.kind, nil, 0
	return f
}

// A `Plain` token, text a format gives no kind, as the kind `l` allows reads it. A leaf that allows numbers alone reads the
// text, quotes cut, with the loose number grammar, and one that allows booleans alone reads `true` and `false`, a null
// beside them changing neither. Any other leaf reads an unquoted text by the strict grammar: a null only when the leaf
// allows one, a boolean or a number only when it allows one, else a string. A leaf that allows a string beside that reading
// takes the string when the other reading fails its enum or its rules and the string passes, unless it allows every kind.
@(cold)
@(private)
plain_token :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, l: ^rules.Leaf) -> core.Token {
	context = h.ctx
	lo, hi := t.lo, t.lo + u64(t.n)
	exact := t.spelling & (core.SPELLING_QUOTED | core.SPELLING_DECODE) == 0
	if t.spelling & core.SPELLING_QUOTED != 0 && hi - lo >= 2 {
		lo, hi = lo + 1, hi - 1
	}
	text := string(raw_data(h.src)[lo:hi])
	value, numbers, loose := t, l.plain & {.Integer, .Number}, l.plain - {.Null}
	value.kind = .String
	switch {
	case exact && text == "null" && .Null in l.plain:
		value.kind = .Null
	case loose != {} && loose <= {.Integer, .Number}:
		if _, integer, _, ok := spell.number_loose(h.src, lo, hi); ok {
			value.kind, value.spelling = .Number, core.number_spelling(core.NUMBER_DECIMAL, 1, 0 if integer else 1)
		}
	case loose == {.Bool}:
		value.kind = .True if text == "true" else .False if text == "false" else .String
	case exact:
		kind, integer := core.plain_kind(h.src, lo, hi, .Bool in l.plain, numbers != {})
		value.kind = kind
		if kind == .Number {
			value.spelling = core.number_spelling(core.NUMBER_DECIMAL, 1, 0 if integer else 1)
		}
		if value.kind != .String && .String in l.plain && (l.has_enum || l.kinds != rules.EVERY_KIND) {
			if value.kind == .Number {
				value.lo, value.n = lo, u32(hi - lo)
			}
			if !reading_passes(h, value, l) && judge_string(h, t, l, nil) == {} {
				value.kind = .String
			}
		}
	}
	if value.kind == .Number {
		value.lo, value.n = lo, u32(hi - lo)
	}
	return value
}

// Keeps `kind` as the reading of the `Plain` value at byte `lo`.
@(cold)
@(private)
reading_keep :: #force_no_inline proc "contextless" (h: ^Check, lo: u64, kind: core.Kind) {
	context = h.ctx
	if _, failed := append(&h.readings.read, Reading{lo, kind}); failed != nil {
		h.readings.short = true
	}
}

// Whether `value`, one reading of a text, passes the enum and the rules of its kind.
@(cold)
@(private)
reading_passes :: proc "contextless" (h: ^Check, value: core.Token, l: ^rules.Leaf) -> bool {
	if value.kind != .Number {
		return !l.has_enum || judge_operand(h, value, l) == {}
	}
	kind_ok := .Number in l.kinds
	return judge_number(h, value, l, &kind_ok) == {} && kind_ok
}

// Judges the scalar `t` by `l`: its kind, its enum and the rules of its kind. A plain integer an i64 holds is judged here
// when `l.fast` says its bounds are whole, and the other rules are cold.
@(private)
judge_value :: #force_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token, l: ^rules.Leaf) -> core.Action {
	fails := scalar_fails(h, t, l)
	if fails == {} {
		return .Next
	}
	lo, hi := check_ends(h, t)
	return check_report(h, regs, l, t.kind, fails, lo, hi)
}

// What the scalar `t` fails of `l`: its kind, its enum and the rules of its kind.
@(private)
scalar_fails :: #force_inline proc "contextless" (h: ^Check, t: core.Token, l: ^rules.Leaf) -> (fails: rules.Failures) {
	ok: bool
	#partial switch t.kind {
	case .Null:
		ok = .Null in l.kinds
	case .True, .False:
		ok = .Bool in l.kinds
	case .Bytes:
		// A byte string is a string to a description, and no rule of a text judges its payload.
		ok = .String in l.kinds
	case .String:
		ok = .String in l.kinds
		if l.has_enum || l.min_length > 0 || l.max_length < max(u64) || l.pattern != nil || l.formats != {} {
			fails = judge_string(h, t, l, nil)
		}
	case .Number:
		if l.fast && t.spelling & core.NUMBER_KIND_MASK == 0 && core.number_shape(t.spelling) <= 19 && h.mant >> 63 == 0 {
			v := -i64(h.mant) if raw_data(h.src)[t.lo] == '-' else i64(h.mant)
			ok = l.kinds & {.Integer, .Number} != {}
			if l.minimum.set && (v < l.minimum.int || v == l.minimum.int && l.minimum.exclusive) {
				fails += {.Below_Minimum}
			}
			if l.maximum.set && (v > l.maximum.int || v == l.maximum.int && l.maximum.exclusive) {
				fails += {.Above_Maximum}
			}
		} else {
			ok = .Number in l.kinds
			if !ok && .Integer in l.kinds || l.has_enum || l.minimum.set || l.maximum.set || l.multiple_of != nil {
				fails = judge_number(h, t, l, &ok)
			}
		}
	}
	if !ok {
		fails += {.Not_Allowed} if l.kinds == {} else {.Wrong_Kind}
	}
	if l.has_enum && t.kind != .String && t.kind != .Number {
		fails += judge_operand(h, t, l)
	}
	return
}

// Whether a value that is no string and no number fails `l`'s enum index.
@(cold)
@(private)
judge_operand :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, l: ^rules.Leaf) -> rules.Failures {
	context = h.ctx
	return {} if rules.enum_has(l, t.kind, "") else {.Not_A_Member}
}

// The rules of `l` a string fails, from its decoded text: `key` when it is read already, else `t`'s.
@(cold)
@(private)
judge_string :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, l: ^rules.Leaf, key: Maybe(string)) -> (fails: rules.Failures) {
	context = h.ctx
	context.allocator = context.temp_allocator
	buf: [TEXT_ROOM]u8 = ---
	text, read := key.?
	if !read {
		if text, read = decoded_text(h, t, buf[:]); !read {
			return {.No_Memory}
		}
	}
	if l.has_enum && !rules.enum_has(l, .String, text) {
		fails += {.Not_A_Member}
	}
	if l.pattern == nil {
		return fails + rules.judge_string(l, text, nil)
	}
	// A search's scratch starts on the stack, and a block that outgrows it moves to the temp allocator.
	room: [SCRATCH_ROOM]u8 = ---
	stack: mem.Arena
	scratch := stack_scratch(&stack, room[:])
	fails += rules.judge_string(l, text, &scratch)
	if .Pattern_Undecided in fails {
		h.fatal = .Pattern_Undecided
	}
	return fails
}

// Whether the compiled `^regex.Regex` at `re` matches in the member name `name`, and whether the search is undecided.
@(private)
key_matches :: #force_no_inline proc "contextless" (h: ^Check, re: rawptr, name: string) -> (found, undecided: bool) {
	context = h.ctx
	room: [SCRATCH_ROOM]u8 = ---
	stack: mem.Arena
	scratch := stack_scratch(&stack, room[:])
	return matches(re, name, &scratch)
}

// A search's scratch that starts in `room` and moves to the temp allocator when it outgrows it.
@(private)
stack_scratch :: proc(stack: ^mem.Arena, room: []u8) -> (scratch: regex.Scratch) {
	mem.arena_init(stack, room)
	spill := runtime.Allocator{spill_proc, stack}
	scratch.stack.allocator, scratch.slots.allocator, scratch.counts.allocator = spill, spill, spill
	scratch.seen.allocator, scratch.good.allocator, scratch.log.allocator = spill, spill, spill
	return
}

// The bytes a pattern's search takes on the stack before it moves to the temp allocator.
@(private)
SCRATCH_ROOM :: 2048

// Allocates from the arena at `data` while it has room and from the temp allocator past it, copying a block that grows
// out of the arena. A block in the arena is freed with it.
@(private)
spill_proc :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old: rawptr, old_size: int, loc := #caller_location) -> ([]byte, runtime.Allocator_Error) {
	stack := (^mem.Arena)(data)
	base := uintptr(raw_data(stack.data))
	inside := uintptr(old) >= base && uintptr(old) < base + uintptr(len(stack.data))
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
		if old != nil && !inside {
			break
		}
		if got, err := mem.arena_allocator_proc(data, mode, size, alignment, old, old_size, loc); err != .Out_Of_Memory {
			return got, err
		}
		got, err := runtime.mem_alloc_bytes(size, alignment, context.temp_allocator, loc)
		if err == nil && old != nil {
			copy(got, mem.byte_slice(old, min(old_size, size)))
		}
		return got, err
	case .Free:
		if inside || old == nil {
			return nil, nil
		}
	case .Free_All:
		return nil, .Mode_Not_Implemented
	}
	return context.temp_allocator.procedure(context.temp_allocator.data, mode, size, alignment, old, old_size, loc)
}

// The first byte and the byte past the scalar `t` as written. A flat format's quoted cell holds its quotes in its span,
// where a JSON string's leaves them out.
@(private)
check_ends :: #force_inline proc "contextless" (h: ^Check, t: core.Token) -> (lo, hi: u64) {
	if h.plan.readers.flat {
		return t.lo, t.lo + u64(t.n)
	}
	return value_ends(h, t)
}

// The text a decoded string up to this long is decoded into on the stack. A longer one goes to the temp allocator.
@(private)
TEXT_ROOM :: 256

// `t`'s decoded text, into `buf` when it fits there.
@(private)
decoded_text :: proc "contextless" (h: ^Reader, t: core.Token, buf: []u8) -> (string, bool) {
	if t.spelling & core.SPELLING_DECODE == 0 {
		return string(raw_data(h.src)[t.lo:][:t.n]), true
	}
	context = h.ctx
	// A format with a `room` may decode a span to more than its spelling bits bound, which `token_text` sizes.
	if 3 * int(t.n) + core.DECODE_SLACK <= len(buf) && h.plan.readers.room == nil {
		return h.plan.readers.text(&h.view, t, buf)
	}
	return core.token_text(h.plan.readers, &h.view, t, context.temp_allocator)
}

// The rules of `l` a number fails, and in `kind_ok` whether it passes `l`'s integer kind. A plain decimal is judged by
// its text, and a number a format spells otherwise by the decimal its value writes as. NaN and the infinities fail
// every bound.
@(cold)
@(private)
judge_number :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, l: ^rules.Leaf, kind_ok: ^bool) -> (fails: rules.Failures) {
	context = h.ctx
	text := string(raw_data(h.src)[t.lo:][:t.n])
	small: Maybe(i64)
	plain := core.number_shape(t.spelling) < 32
	buf: [max(spell.F64_ROOM, 24)]u8 = ---
	if t.spelling & core.NUMBER_KIND_MASK > core.NUMBER_DECIMAL {
		n, read := h.plan.readers.number(&h.view, t)
		switch {
		case !read:
			return {.Wrong_Kind}
		case n.kind == .Int:
			text, small = strconv.write_int(buf[:], i64(n.bits), 10), i64(n.bits)
		case n.kind == .Uint:
			text = strconv.write_uint(buf[:], n.bits, 10)
		case n.kind == .Float && abs(transmute(f64)n.bits) <= max(f64):
			text = string(buf[:spell.f64_text(&buf[0], transmute(f64)n.bits)])
			plain = false
		case:
			kind_ok^ ||= .Number in l.kinds
			if l.minimum.set {
				fails += {.Below_Minimum}
			}
			if l.maximum.set {
				fails += {.Above_Maximum}
			}
			if l.multiple_of != nil {
				fails += {.Not_Multiple}
			}
			if l.has_enum {
				fails += {.Not_A_Member}
			}
			return
		}
		plain ||= n.kind != .Float
	} else if t.spelling & core.NUMBER_KIND_MASK == 0 && core.number_shape(t.spelling) <= 19 && h.mant >> 63 == 0 {
		small = -i64(h.mant) if text[0] == '-' else i64(h.mant)
	}
	if !kind_ok^ && .Integer in l.kinds {
		kind_ok^ = plain || !l.integer_spelled && rules.integral(spell.decimal_of(text))
	}
	if l.has_enum && !rules.enum_has(l, .Number, text) {
		fails += {.Not_A_Member}
	}
	return fails + rules.judge_number(l, text, small)
}

// Reports each of `fails`, the rules a value of kind `of` at `regs` fails by `l`, spanning `lo` to `hi`, under the
// keyword `keyword_of` names, or `keyword`. Returns `.Stop` for a read with no sink.
@(cold)
@(private)
check_report :: #force_no_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, l: ^rules.Leaf, of: core.Kind, fails: rules.Failures, lo, hi: u64, keyword := "") -> core.Action {
	context = h.ctx
	for kind in fails {
		note(h, regs, {kind = kind, at = lo, found = of if kind == .Wrong_Kind else .Null}, hi, keyword if keyword != "" else keyword_of(l, kind, of), rule_operand(h, l, kind, of))
		if h.sink == nil {
			return .Stop
		}
	}
	return .Next
}

// What an entry for the rule `l` holds that a value of kind `of` failed as `kind` says the value should have met, "" for
// a schema's entries, whose messages name keywords, and for a read with no sink.
@(private)
rule_operand :: proc "contextless" (h: ^Check, l: ^rules.Leaf, kind: core.Typed_Error_Kind, of: core.Kind) -> string {
	context = h.ctx
	// A model names the type it wanted, which the refusal holds.
	if h.sink == nil || kind == .Wrong_Kind && !h.plan.checking {
		return ""
	}
	return rules.operand_text(l, kind, of == .Object, context.temp_allocator)
}

// The keyword of `l` that holds the rule a value of kind `of` fails as `kind`, none for a value its use takes nowhere,
// whose keyword path ends at the use.
@(private)
keyword_of :: proc "contextless" (l: ^rules.Leaf, kind: core.Typed_Error_Kind, of: core.Kind) -> string {
	#partial switch kind {
	case .Not_A_Member:
		return "const" if l.constant else "enum"
	case .Below_Minimum:
		return "exclusiveMinimum" if l.minimum.exclusive else "minimum"
	case .Above_Maximum:
		return "exclusiveMaximum" if l.maximum.exclusive else "maximum"
	case .Too_Few:
		return "minProperties" if of == .Object else "minItems"
	case .Too_Many:
		return "maxProperties" if of == .Object else "maxItems"
	}
	return KEYWORDS[kind]
}

@(private)
@(rodata)
KEYWORDS := #partial [core.Typed_Error_Kind]string {
	.Wrong_Kind    = "type",
	.Not_Multiple  = "multipleOf",
	.Too_Short     = "minLength",
	.Too_Long      = "maxLength",
	.No_Match      = "pattern",
	.Pattern_Undecided = "pattern",
	.Bad_Format    = "format",
	.Missing_Field = "required",
}

// The rules of `l` a container of kind `kind` fails before its count: its kind, and an enum, which holds no container.
@(private)
container_fails :: #force_inline proc "contextless" (l: ^rules.Leaf, kind: core.Kind) -> (fails: rules.Failures) {
	if (rules.Kind.Object if kind == .Object else rules.Kind.Array) not_in l.kinds {
		fails += {.Not_Allowed} if l.kinds == {} else {.Wrong_Kind}
	}
	if l.has_enum {
		fails += {.Not_A_Member}
	}
	return
}

// A key of an open object at a `Checked` record: judges it by the object's name rules, and moves the cursor to the
// member it names, to the record of the members no record names, or past the member.
@(private)
check_key :: proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	regs := regs
	f := &h.frames[h.sp - 1]
	owner := field_at(f.b)
	m, u := &h.plan.meta[owner.meta], &h.plan.uses[owner.meta]
	f.owner, f.target = (^Field)(uintptr(t.lo)), uintptr(t.n) | uintptr(t.spelling) << 32
	buf: [TEXT_ROOM]u8 = ---
	key, ok := member_text(h, owner, t, buf[:])
	if !ok {
		return regs, .Stop
	}
	if h.tracked > 0 && h.trackers[h.tracked - 1].sp == h.sp - 1 {
		switch track_key(h, &h.trackers[h.tracked - 1], t, key) {
		case .New:
		case .Skip:
			regs.c += 1
			return regs, .Skip
		case .Stop:
			return regs, .Stop
		}
	}
	if u.keys != 0 {
		l := &h.plan.leaves[u.keys - 1]
		fails := judge_string(h, t, l, key) if .String in l.kinds else ({.Not_Allowed} if l.kinds == {} else {.Wrong_Kind})
		if fails != {} {
			lo, hi := check_ends(h, t)
			// The name is judged as the object's, under the keyword path of the names' own node.
			h.sp -= 1
			h.after = KEYS[:]
			before := len(h.sink.entries) if h.sink != nil else 0
			action := check_report(h, {f.a, f.b, f.c}, l, .String, fails, lo, hi)
			context = h.ctx
			name_failed(h.sink, before, key)
			h.after = nil
			h.sp += 1
			if action == .Stop {
				return regs, .Stop
			}
		}
	}
	if m.members > 0 {
		at := ([^]Field)(owner.first)
		// The cursor leaves where it stood, so the members it passed are marked first.
		mark_run(h, f, owner, (^Field)(uintptr(regs.b)))
		f.seen |= SEEN_ON
		if len(key) == 0 || m.names & name_bit(key) != 0 {
			if i := member_index(h, owner, m, key); i >= 0 {
				if seen_set(h, f, owner, i) && h.repeats == .Notice {
					return regs, noticed(h, t)
				}
				next := &at[i + 1]
				if keyed(h, m, u) || h.repeats == .Notice && repeat_may_count(h, m) && seen_past(h, f, owner, i) {
					next = &h.plan.solo[2 * (int(uintptr(&at[i]) - uintptr(raw_data(h.plan.fields))) / size_of(Field)) + 1]
				}
				regs.b, f.run = u64(uintptr(next)), &at[i + 1]
				return regs, .Next
			}
		}
	}
	if u.pattern != 0 {
		found, undecided := key_matches(h, u.regex, key)
		if undecided {
			context = h.ctx
			lo, hi := check_ends(h, t)
			return regs, fork_fault(h, {f.a, f.b, f.c}, .Pattern_Undecided, lo, hi)
		}
		if found {
			regs.b = u64(uintptr(&h.plan.fields[u.pattern]))
			return regs, .Next
		}
	}
	if u.additional != 0 {
		regs.b = u64(uintptr(&h.plan.fields[u.additional]))
		return regs, .Next
	}
	if len(u.applies) > 0 {
		return regs, fork_token(h, t)
	}
	regs.c += 1
	return regs, .Skip
}

// The close of a container at a `Checked` record: judges an object's required members and its count, or an array's,
// then gives back the registers past the container.
@(cold)
@(private)
check_close :: #force_no_inline proc "contextless" (h: ^Check, f: ^Frame, owner: ^Field, regs: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action) #no_bounds_check {
	if h.taken != nil && h.sp == h.taken.below {
		return taken_close(h, f, owner, regs, t)
	}
	if len(h.plan.uses[owner.meta].applies) > 0 {
		return fork_close(h, f, regs, t)
	}
	m := &h.plan.meta[owner.meta]
	at := core.Hook_Regs{f.a, f.b, f.c}
	back := core.Hook_Regs{f.a, f.b + (size_of(Field) if h.plan.uses[owner.meta].step else 0), f.c + 1}
	lo, hi := u64(uintptr(f.data)), t.lo + u64(t.n)
	count := regs.c
	if tracks(h, f) {
		count -= h.trackers[h.tracked - 1].repeats
		h.tracked -= 1
	}
	if f.kind == .Object && m.required_end > 0 {
		context = h.ctx
		for i := missing_member(h, f, owner, regs, 0); i >= 0; i = missing_member(h, f, owner, regs, i + 1) {
			// The object's frame is reopened for the path, whose last step the name replaces.
			// The path is the object's, as a schema's output names it, and the entry's operand names the member.
			e := core.Typed_Refusal{kind = .Missing_Field, at = lo}
			e.want.text = h.plan.meta[m.block + i].name
			note(h, at, e, hi, "required")
			if h.sink == nil {
				return back, .Stop
			}
		}
	}
	if f.kind == .Object && len(h.plan.uses[owner.meta].requires) > 0 && dependent_missing(h, f, owner, regs, at, lo, hi) == .Stop {
		return back, .Stop
	}
	if m.rule_set == 0 {
		return back, .Next
	}
	l := &h.plan.leaves[m.rule_set - 1]
	fails := container_fails(l, f.kind)
	fails += rules.judge_count(count, l.min_members, l.max_members) if f.kind == .Object else rules.judge_count(count, l.min_items, l.max_items)
	if fails != {} && check_report(h, at, l, f.kind, fails, lo, hi) == .Stop {
		return back, .Stop
	}
	return back, .Next
}

// Reports each member the object's `dependentRequired` asks for and the object lacks. Returns `.Stop` for a read with no
// sink.
@(cold)
@(private)
dependent_missing :: #force_no_inline proc "contextless" (h: ^Check, f: ^Frame, owner: ^Field, regs, at: core.Hook_Regs, lo, hi: u64) -> core.Action {
	context = h.ctx
	m := &h.plan.meta[owner.meta]
	for r in h.plan.uses[owner.meta].requires {
		if !member_seen(h, f, owner, regs, r.trigger) {
			continue
		}
		for want in r.wants {
			if !member_seen(h, f, owner, regs, want) {
				e := core.Typed_Refusal{kind = .Missing_Field, at = lo}
				e.want.text = h.plan.meta[m.block + want].name
				note(h, at, e, hi, r.keyword)
				if h.sink == nil {
					return .Stop
				}
			}
		}
	}
	return .Next
}

// Stores into the integer record `fld` a number spelled with a fraction or an exponent that is an integer, `1.0` or
// `1e2`, which a check takes where a read refuses it.
@(cold)
store_integral :: #force_no_inline proc "contextless" (h: ^Check, t: core.Token, fld: ^Field, dest: uintptr) -> core.Typed_Error_Kind {
	if t.spelling & core.NUMBER_KIND_MASK != 0 {
		return .Wrong_Kind
	}
	context = h.ctx
	d := spell.decimal_of(string(raw_data(h.src)[t.lo:][:t.n]))
	if !rules.integral(d) {
		return .Wrong_Kind
	}
	v, fits := rules.decimal_i64(d)
	if !fits {
		return past_limit(raw_data(h.src)[t.lo] == '-')
	}
	return store_int(u64(v) if v >= 0 else u64(-(v + 1)) + 1, v < 0, fld.kind, dest)
}

// Stores into an enum read by number a number spelled with a fraction or an exponent that is an integer, as
// `store_integral` stores one into an integer.
@(private, cold)
store_integral_enum :: proc(h: ^Check, t: core.Token, info: ^runtime.Type_Info_Enum, dest: uintptr, size: u32) -> core.Typed_Error_Kind {
	if t.spelling & core.NUMBER_KIND_MASK != 0 {
		return .Wrong_Kind
	}
	d := spell.decimal_of(string(raw_data(h.src)[t.lo:][:t.n]))
	if !rules.integral(d) {
		return .Wrong_Kind
	}
	v, fits := rules.decimal_i64(d)
	return store_enum_value(info, {u64(v), .Int}, dest, size) if fits else .Not_A_Member
}

// Judges a scalar a type's plan stored by its record's rules, which the record's `Meta.rule_set` names. A string
// record's stored text is its decoded text. `.Skip` says the scalar failed and the sink took its failures.
@(cold)
check_rules :: #force_no_inline proc "contextless" (h: ^Check, regs: core.Hook_Regs, t: core.Token, fld: ^Field, dest: uintptr) -> core.Action {
	l := &h.plan.leaves[h.plan.meta[fld.meta].rule_set - 1]
	fails: rules.Failures
	#partial switch t.kind {
	case .String:
		stored: Maybe(string)
		if fld.kind == .String {
			stored = (^string)(dest)^
		}
		fails = judge_string(h, t, l, stored)
	case .Number:
		kind_ok := true
		fails = judge_number(h, t, l, &kind_ok)
	}
	if fails == {} {
		return .Next
	}
	context = h.ctx
	lo, hi := check_ends(h, t)
	for kind in fails {
		note(h, regs, {kind = kind, at = lo}, hi, nil, rule_operand(h, l, kind, t.kind))
		if h.sink == nil {
			return .Stop
		}
	}
	return .Skip
}

// The step of the value at `at` inside the container `f` of the `Checked` record `owner`: its index, the name of the
// member whose record reads it, or the text of the object's last key.
@(private)
checked_step :: proc(h: ^Reader, f: ^Frame, owner: ^Field, at: core.Hook_Regs) -> (core.Step, bool) {
	if f.kind == .Array {
		return core.Index(at.c), true
	}
	m := &h.plan.meta[owner.meta]
	if rec := i32(field_at(at.b).meta); rec >= m.block && rec < m.block + m.members {
		return core.Name(h.plan.meta[rec].name), true
	}
	key := core.Token{lo = u64(uintptr(f.owner)), n = u32(f.target), kind = .String, role = .Key, spelling = u16(f.target >> 32)}
	if key.spelling == TEXT_KEY {
		return core.Name(TEXT_NAME), true
	}
	// The text is the input's or the temp allocator's, never the reader's.
	text, ok := core.token_text(h.plan.readers, &h.view, key, context.temp_allocator)
	return core.Name(text), ok
}

// How many entries a read judged again for its repeats keeps when the caller gave no sink, which a failure past it
// reports as a failure with the entries it did keep.
@(private)
REJUDGE_ENTRIES :: 1 << 16

// Starts the second read of a check that ended on `.Duplicate_Key` while noticing repeats: takes back what the first
// read put in `read.sink` since `mark`, and returns the options of the read that judges them. A read with no sink gets
// `own` as its sink, for `rejudged` to settle.
rejudge :: proc(read: Read_Options, mark: Sink_Mark, own: ^Sink, allocator: runtime.Allocator) -> Read_Options {
	judged := read
	judged.repeats = .Judge
	if read.sink != nil {
		sink_restore(read.sink, mark)
	} else {
		own^ = {max_errors = REJUDGE_ENTRIES}
		own.entries.allocator = allocator
		judged.sink = own
	}
	return judged
}

// The refusal of a read `rejudge` gave `own` as its sink, `e` when it ended on a fault, else the first entry it kept, none
// for a text whose repeats left it nothing to fail. Frees `own`.
rejudged :: proc(own: ^Sink, e: core.Typed_Refusal) -> (first: core.Typed_Refusal) {
	defer sink_destroy(own)
	switch {
	case e.kind == .Walk || e.kind == .No_Memory:
		return e
	case len(own.entries) > 0:
		x := &own.entries[0]
		first = {kind = x.kind, at = x.start}
		for s in x.path {
			path_add(&first, s)
		}
		own_names(&first)
		return
	case own.truncated:
		return {kind = .Bad_Option}
	}
	return
}

// Whether a check with no sink that stopped on a refusal had an object open, whose later repeat of a key could take the
// refusal back, so the caller reads again judging repeats.
@(private)
repeat_may_retract :: proc(r: ^Reader) -> bool {
	if !object_open(r) {
		return false
	}
	known := repeating_containers(r)
	return known.every || len(known.at) > 0
}

// Whether `r` has an object open at frame `from` or past it, a struct's among them.
@(private)
object_open :: proc(r: ^Reader, from := 1) -> bool {
	for i in from ..< r.sp {
		if r.frames[i].kind == .Object || is_struct(frame_owner(&r.frames[i])) {
			return true
		}
	}
	return false
}

// The document of the text a check reads, keeping every member, in the temp allocator: built by the plan's own build,
// which a plan made with a format's reads or checks has, else by its handle's. False when neither builds it.
@(private)
text_built :: proc(r: ^Reader) -> (doc: core.Document, built: bool) {
	if build := plan_text_build(r.plan); build != nil {
		err: core.Document_Error
		doc, err = build(r.src, r.plan.as, context.temp_allocator)
		return doc, err.kind == .None && len(doc.nodes) > 0
	}
	err: core.Error
	doc, err = core.build(r.src, r.plan.as, .Last, context.temp_allocator)
	return doc, err == nil && len(doc.nodes) > 0
}
