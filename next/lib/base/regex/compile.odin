package regex

// Compiles a pattern's tree into a program for the backtracking matcher (match.odin), with what the search can skip by:
// the choice of Oniguruma's optimizer (optimize.odin), a literal that every match starts with, and the bytes that a
// match starts with.

import "core:mem"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"
import "stury:lib/base/kernel"

@(private)
Compiler :: struct {
	insts:      [dynamic]Inst,
	bytes:      [dynamic]byte,
	classes:    [dynamic]^Class,
	refs:       [dynamic][]int,
	groups:     []^Node, // the group nodes, indexed by group number
	referenced: []bool, // by group number: true when a backreference or condition reads it
	undone:     []bool, // by group number: the match undoes its bounds as it backs past them (`mark_undone`)
	open:       [dynamic]int, // the groups being emitted, innermost last
	ecma:       bool, // set under ECMA: no counter loops, no Rep in a look-ahead, an empty iteration fails
	looking:    int, // the number of look-arounds being emitted, nested
	leftwards:  bool, // emitting an ECMA look-behind's body, which matches leftwards from where the look-behind is
	loops:      [dynamic][2]i32, // `Regex.loops`
	loop_of:    [dynamic]i32, // under ECMA, per instruction: the index into `loops` of its loop, -1 for none
	loop:       int, // the index into `loops` of the loop being emitted, -1 for none
	counters:   [dynamic]Counter, // `Visited.counters`
	counter_of: [dynamic]i32, // under ECMA, per instruction: the index into `counters` of its counter loop, -1 for none
	counter:    int, // the counter loop being emitted, -1 for none
	looped:     [dynamic]^Node, // the ECMA repeats that run as counter loops, which a repeat around them emits again
	// a repeat of more than one iteration, which an ECMA search that reads no bounds counts (`counting_of`)
	counted:    bool,
	tuned:      int, // the highest group number Oniguruma's tune_tree has reached by now, as `fixed_length` reads it
	slots:      int,
	err:        string,
	called:     []bool, // by group number: a call reaches it, so it is a subroutine
	recursive:  []bool, // by group number: its body calls itself
	addr:       []int, // by group number: a called group's first instruction, -1 until emitted
}

// The bytes of a compile's own stack that serve its allocations once the caller's allocator has failed.
@(private)
SPARE_BYTES :: 8192

// Compiles `pattern` under `syntax` and `flags`, or returns why not: `.Syntax` with Oniguruma's message for a pattern
// it refuses, `.Memory` where an allocator failed or a program passed its capacity. The program, what it was built from
// and any message are allocated from `allocator`, which is meant to be an arena that the caller frees whole. With
// `automaton` the automaton that answers whether there is a match is built too, which is worth it for a regex that
// searches more than a few short texts. With `spans` the two automata that find where a match ends and starts are built
// too, which is worth it for a regex whose searches read bounds. Building them takes working memory from `scratch` and
// frees it before returning.
compile :: proc(
	pattern: string,
	syntax: Syntax,
	flags: Flags,
	allocator, scratch: mem.Allocator,
	automaton := true,
	spans := false,
) -> (
	re: Regex,
	err: Error,
) {
	spare, spare_scratch: [SPARE_BYTES]byte = ---, ---
	out := Gate{inner = allocator, spare = spare[:]}
	tmp := Gate{inner = scratch, spare = spare_scratch[:]}
	message: string
	if re, message = program(pattern, syntax, flags, gate_allocator(&out)); message == "" && automaton {
		re.dfa = build_dfa(&re, spans, &out, &tmp)
	}
	switch {
	case out.failed || tmp.failed:
		return {}, MEMORY_OUT
	case message == MEMORY_ERROR:
		return {}, MEMORY_OUT
	case message != "":
		return {}, {.Syntax, message}
	}
	return re, {}
}

// What `compile` returns for `pattern`, with no automaton, the program freed. A message is allocated from `allocator`.
// The program is built in `scratch`.
refusal :: proc(pattern: string, syntax: Syntax, flags: Flags, allocator, scratch: mem.Allocator) -> (err: Error) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, scratch, scratch, block_size = 4096, out_band_size = 1024)
	defer mem.dynamic_arena_destroy(&arena)
	_, err = compile(pattern, syntax, flags, mem.dynamic_arena_allocator(&arena), scratch, automaton = false)
	if err.message != "" {
		message, cloned := strings.clone(err.message, allocator)
		if cloned != nil {
			return MEMORY_OUT
		}
		err.message = message
	}
	return
}

// Builds the program of `compile`, without the automaton.
@(private = "file")
program :: proc(pattern: string, syntax: Syntax, flags: Flags, allocator: mem.Allocator) -> (re: Regex, err: string) {
	context.allocator = allocator
	if syntax == .Ecma && flags != {} {
		return {}, "ecma takes no other flag"
	}
	options := Options{flags = flags, ecma = syntax == .Ecma}
	pat: Pattern
	if pat, err = parse(pattern, options); err != "" {
		return
	}
	names := pat.names
	root := expand_folds(pat.root)
	c := Compiler{
		slots = 2 * len(names),
		groups = pat.groups,
		referenced = pat.referenced,
		ecma = options.ecma,
		loop = -1,
		counter = -1,
	}
	c.called = make([]bool, len(names))
	c.recursive = make([]bool, len(names))
	c.undone = slice.clone(c.referenced)
	if pat.has_calls {
		if err = check_calls(root, c.groups, c.called, c.recursive); err != "" {
			return
		}
		c.addr = make([]int, len(names))
		slice.fill(c.addr, -1)
		slice.fill(c.undone, true)
	} else if options.ecma {
		slice.fill(c.undone, true) // a failed try leaves no bounds behind
	} else {
		mark_undone(root, c.undone, false)
	}
	for g in 1 ..< len(names) {
		c.groups[g].used = c.referenced[g] || c.called[g]
	}
	emit(&c, root)
	add(&c, .Match)
	if pat.has_calls {
		emit_subroutines(&c)
	}
	if c.err != "" {
		return {}, c.err
	}
	re.program = Program {
		insts    = c.insts[:],
		bytes    = string(c.bytes[:]),
		classes  = c.classes[:],
		refs     = c.refs[:],
		callouts = pat.callouts,
		names    = names,
		slots    = c.slots,
		opt      = new_clone(search_opt(root)),
		head     = new(Search_Opt),
	}
	// A callout that ends the search or counts the starts sees which starts are tried, so only the skip that
	// Oniguruma's optimizer makes is used and no head is set.
	like_onig := false
	for co in pat.callouts {
		like_onig ||= co.kind == .Error || co.kind == .Total_Count
	}
	h := re.head
	if !like_onig {
		prefix := make([dynamic]byte)
		if literal_prefix(root, &prefix); len(prefix) > 0 {
			h.kind, h.exact = .Exact, string(prefix[:])
		} else if empty, known := first_bytes(root, &h.set); known && !empty {
			h.kind = .Map
		}
	}
	// A string or map that the optimizer finds at the start of every match is merged into the head. The head skips
	// without windows, so the optimizer's kind and threshold are cleared.
	o := re.opt
	if o.dist_max == 0 {
		#partial switch o.kind {
		case .Exact:
			if h.kind != .Exact || len(o.exact) > len(h.exact) {
				h.kind, h.exact = .Exact, o.exact
			}
		case .Map:
			if h.kind != .Exact {
				h.set = h.set & o.set if h.kind == .Map else o.set
				h.kind = .Map
			}
		}
		o.kind, o.threshold = .None, 0
	}
	if h.kind == .Map {
		h.lead = kernel.byte_set([4]u64{h.set[0], h.set[1], max(u64), max(u64)})
	}
	re.narrowed = o.kind != .None || o.anchored || o.end != .None || o.threshold > 0
	for ins in re.insts {
		re.calls_or_limits ||= ins.op >= .Call
	}
	re.ecma, re.linear = options.ecma, linear_ops(re.insts, options.ecma, re.opt.anchored)
	re.longest, re.not_empty = flags.longest, flags.not_empty
	if options.ecma && c.counted {
		re.counting = counting_of(re.insts)
	}
	if re.linear {
		v := new(Visited)
		re.visited = v
		if options.ecma {
			v.owner = look_owners(re.insts)
		}
		if len(c.loops) > 0 || len(c.counters) > 0 {
			v.loops, v.loop_of = c.loops[:], c.loop_of[:]
			v.block = make([]int, len(re.insts))
			for l, pc in v.loop_of {
				v.block[pc] = 1
				for k := l; k >= 0; k = v.loops[k][1] {
					v.block[pc] += 1
				}
			}
			if len(c.counters) > 0 {
				v.counters, v.counter_of = c.counters[:], c.counter_of[:]
			} else {
				v.rows = make([]int, len(re.insts) + 1)
				lay_out_rows(v, v.rows, nil)
			}
		}
	}
	return re, ""
}

// Emits each called group that no call has emitted in place (as a group under `{0}` is) after the program, then sets
// each call's address.
@(private = "file")
emit_subroutines :: proc(c: ^Compiler) {
	// By index, because emitting a group grows c.insts and the loop must reach the calls that group emits.
	for i := 0; i < len(c.insts); i += 1 {
		if c.insts[i].op != .Call {
			continue
		}
		g := c.insts[i].b
		if c.addr[g] < 0 {
			c.addr[g] = len(c.insts)
			emit_group(c, c.groups[g])
			add(c, .Return)
		}
		c.insts[i].a = i32(c.addr[g])
	}
}

@(private = "file")
add :: proc(c: ^Compiler, op: Op, a: int = 0, b: int = 0) -> int {
	if len(c.insts) * size_of(Inst) >= MAX_BYTES || gate_failed(context.allocator) {
		c.err = MEMORY_ERROR
		return len(c.insts)
	}
	append(&c.insts, Inst{op, i32(a), i32(b)})
	if c.ecma {
		append(&c.loop_of, i32(c.loop))
		append(&c.counter_of, i32(c.counter))
	}
	return len(c.insts) - 1
}

@(private = "file")
emit_str :: proc(c: ^Compiler, run: []^Node) {
	at := len(c.bytes)
	for n in run {
		buf: [4]byte
		append(&c.bytes, literal_text(n, &buf))
	}
	add(c, .Str, at, len(c.bytes) - at)
}

@(private = "file")
emit :: proc(c: ^Compiler, n: ^Node) {
	if c.err != "" {
		return
	}
	if c.leftwards && (n.kind == .Char || n.kind == .Str || n.kind == .Any || n.kind == .Class) {
		// Steps back over as many characters as it reads, reads them, and steps back to before them again.
		back := utf8.rune_count_in_string(n.text) if n.kind == .Str else 1
		add(c, .Back, back)
		c.leftwards = false
		emit(c, n)
		c.leftwards = true
		add(c, .Back, back)
		return
	}
	switch n.kind {
	case .Empty:
	case .Char, .Str:
		if literal(n) {
			emit_str(c, {n})
		} else {
			add(c, .Char_Fold, int(fold(n.r)))
		}
	case .Any:
		add(c, .Any_All if n.dotall else .Any)
	case .Class:
		cls := n.class
		if k := cls.slot - 1; 0 <= k && k < len(c.classes) && c.classes[k] == cls { // a repeat's copies share the class
			add(c, .Class, k)
			return
		}
		cls.ascii = ascii_bits(cls)
		cls.slot = len(c.classes) + 1
		append(&c.classes, cls)
		add(c, .Class, len(c.classes) - 1)
	case .Cat:
		if c.leftwards {
			#reverse for k in n.kids {
				emit(c, k)
			}
			break
		}
		for i := 0; i < len(n.kids); {
			if j := literal_run_end(n.kids[:], i); j > i {
				emit_str(c, n.kids[i:j])
				i = j
			} else {
				emit(c, n.kids[i])
				i += 1
			}
		}
	case .Alt:
		jumps := make([dynamic]int)
		for kid, k in n.kids {
			if k == len(n.kids) - 1 {
				emit(c, kid)
				break
			}
			split := add(c, .Split)
			emit(c, kid)
			append(&jumps, add(c, .Jmp))
			patch(c, split, split + 1, len(c.insts))
		}
		for j in jumps {
			patch(c, j, len(c.insts))
		}
	case .Group:
		g := n.group
		c.tuned = max(c.tuned, g)
		if !c.called[g] {
			emit_group(c, n)
			break
		}
		// A called group is emitted as a subroutine, and the group at its own position calls it too. A later copy of
		// it, from a counted repeat, calls the first.
		if c.addr[g] >= 0 {
			add(c, .Call, c.addr[g], g)
			break
		}
		call := add(c, .Call, 0, g)
		jump := add(c, .Jmp)
		c.addr[g] = len(c.insts)
		emit_group(c, n)
		add(c, .Return)
		patch(c, call, c.addr[g], g)
		patch(c, jump, len(c.insts))
	case .Call:
		add(c, .Call, -1, n.target.group) // the address is set by `emit_subroutines` once every group is emitted
	case .Absent:
		emit_absent(c, n)
	case .Repeat:
		emit_repeat(c, n)
	case .Assert:
		add(c, .Assert, int(n.assert), n.callout.index if n.callout != nil else 0)
	case .Look:
		emit_look(c, n)
	case .Backref:
		append(&c.refs, n.refs[:])
		add(c, .Backref, len(c.refs) - 1, int(n.fold || c.leftwards))
	case .Keep:
		add(c, .Save, 0)
	case .Cond:
		test := add(c, .Cond, n.group)
		emit(c, n.kids[0])
		jump := add(c, .Jmp)
		patch(c, test, n.group, len(c.insts))
		emit(c, n.kids[1])
		patch(c, jump, len(c.insts))
	case .Linebreak:
		add(c, .Linebreak)
	case .Grapheme:
		add(c, .Grapheme)
	}
}

// Emits a group's captures and body. A group that calls itself reads its start from the stack at its end, as
// Oniguruma's OP_MEM_END_REC does, so it captures where its own call began. The whole pattern called (group 0)
// captures nothing of its own.
@(private = "file")
emit_group :: proc(c: ^Compiler, n: ^Node) {
	g := n.group
	append(&c.open, g)
	defer pop(&c.open)
	switch {
	case g == 0:
		emit(c, n.kids[0])
	case c.recursive[g]:
		add(c, .Mem_Start, g)
		emit(c, n.kids[0])
		add(c, .Mem_End, g)
	case c.leftwards: // its end is reached first, while its start is still unset
		add(c, .Save, 2 * g + 1)
		emit(c, n.kids[0])
		add(c, .Save, 2 * g)
	case c.undone[g]:
		add(c, .Save, 2 * g, int(c.referenced[g]))
		emit(c, n.kids[0])
		add(c, .Save, 2 * g + 1)
	case:
		add(c, .Set, 2 * g)
		emit(c, n.kids[0])
		add(c, .Set, 2 * g + 1)
	}
}

// Marks the groups whose bounds Oniguruma pushes (its backtrack_mem), so that the match undoes them as it backs past:
// those within an alternative, a condition's branch, a negative look, an absent operator or a repeat of no fixed count.
// The MEM_START and MEM_END of every other group write its bounds in place, and the bounds a failed try wrote stay.
@(private = "file")
mark_undone :: proc(n: ^Node, undone: []bool, within: bool) {
	within := within
	#partial switch n.kind {
	case .Alt, .Cond, .Absent:
		within = true
	case .Look:
		within ||= n.look == .Not_Ahead || n.look == .Not_Behind
	case .Repeat:
		within ||= n.min != n.max
	case .Group:
		undone[n.group] ||= within
	}
	for k in n.kids {
		mark_undone(k, undone, within)
	}
}

// Emits an absent operator as Oniguruma's make_absent_tree does. It saves the limit, the end the match reads to. Then,
// inside a negative look so that its captures and position are undone, it tries the absent at each position from here
// short of the limit, and where the absent first matches becomes the new limit. Then exp runs, and the saved limit is
// restored after it. A stopper keeps the new limit, and `(?~|)` sets the limit to the text's end.
@(private = "file")
emit_absent :: proc(c: ^Compiler, n: ^Node) {
	if len(n.kids) == 0 {
		add(c, .Limit_Clear)
		return
	}
	saved, at := new_slot(c), new_slot(c)
	add(c, .Limit_Save, saved)
	undo := add(c, .Look)
	first := add(c, .Look)
	loop := add(c, .Split)
	try := add(c, .Split)
	add(c, .Save, at)
	emit(c, n.kids[0])
	add(c, .Limit_Cut, at)
	found := add(c, .Jmp)
	patch(c, try, try + 1, len(c.insts))
	add(c, .Any_All)
	add(c, .Jmp, loop)
	patch(c, loop, loop + 1, len(c.insts))
	patch(c, found, len(c.insts))
	patch(c, first, int(Look_Kind.Atomic), add(c, .Look_End))
	add(c, .Assert, int(Assert_Kind.Fail))
	patch(c, undo, int(Look_Kind.Not_Ahead), add(c, .Look_End))
	if len(n.kids) == 2 {
		emit(c, n.kids[1])
		add(c, .Limit_Restore, saved)
	}
}

@(private = "file")
patch :: proc(c: ^Compiler, at: int, a: int, b: int = 0) {
	if at < len(c.insts) {
		c.insts[at].a, c.insts[at].b = i32(a), i32(b)
	}
}

@(private = "file")
emit_repeat :: proc(c: ^Compiler, n: ^Node) {
	x := n.kids[0]
	if n.possessive {
		inner := new(Node)
		inner^ = n^
		inner.possessive = false
		atomic := Node{kind = .Look, look = .Atomic}
		append(&atomic.kids, inner)
		emit_look(c, &atomic)
		return
	}
	if n.max == 0 {
		return
	}
	c.counted ||= n.min > 1 || n.max > 1
	// Under ECMA no Rep is used in a look-ahead's body, because the visited set's log does not follow its alternatives
	// (match.odin).
	single := x.kind == .Char || x.kind == .Any || x.kind == .Class
	if single && (n.max != n.min || c.ecma) && !(c.ecma && c.looking > 0) {
		add(c, .Rep if n.greedy else .Rep_Lazy, n.min, n.max)
		emit(c, x)
		return
	}
	if n.max >= 0 {
		emit_counted(c, n)
		return
	}
	// A body that can match empty ends the loop after an iteration that does match empty, as Oniguruma's empty check
	// does, so `(a*)*` terminates.
	empty := can_be_empty(x)
	// With a minimum of 1 and a body that cannot match empty, the first iteration is entered by a jump into the loop
	// past its Split, as Oniguruma's OP_JUMP does. A copy of the body would double nested repeats at every level.
	enter := add(c, .Jmp) if n.min == 1 && !empty else -1
	if enter < 0 && n.min > 1 && c.ecma && looped(c, n) {
		emit_counter_loop(c, x, n.min, n.min, true, -1)
	} else {
		for i in 0 ..< (n.min if enter < 0 else 0) {
			at := emitted(c)
			emit_body(c, x, -1)
			if c.err != "" {
				return
			}
			if i == 0 && n.min > 1 && c.ecma && (len(c.insts) - at.insts) * n.min > ECMA_WRITTEN_OUT {
				spill_to_counter_loop(c, at, n, n.min, n.min, true, -1)
				break
			}
		}
	}
	loop := add(c, .Split)
	if enter >= 0 {
		patch(c, enter, loop + 1)
	}
	mark := new_slot(c) if empty else -1
	check := emit_body(c, x, mark)
	add(c, .Jmp, loop)
	exit := len(c.insts)
	patch(c, loop, loop + 1 if n.greedy else exit, exit if n.greedy else loop + 1)
	if empty {
		patch(c, check, mark, -1 if c.ecma else exit)
	} else if h := head_literal(x);
	   h != nil &&
	   !c.leftwards &&
	   (h.kind == .Str || h.kind == .Char && !h.fold && utf8.valid_rune(h.r)) &&
	   n.greedy &&
	   n.min <= 1 {
		// Oniguruma's OP_PUSH_OR_JUMP_EXACT1: when the body starts with an exact character (no class, no case
		// folding), no alternative is pushed for an iteration that cannot start, and Oniguruma's retry limit counts
		// that.
		head, _ := utf8.encode_rune(h.r)
		c.insts[loop] = {op = .Split_Head, a = i32(head[0]), b = i32(exit)}
	}
}

// Emits a repeat with a maximum count. In Oniguruma's counted repeat, once an iteration of a body that can match empty
// does match empty, the loop ends even short of the least count: `(|a){2}b` matches "ab" with the group empty after the
// a. In ECMA's, an iteration short of the least count may match empty, and one past it fails when it does, `(a?)?`
// included.
@(private = "file")
emit_counted :: proc(c: ^Compiler, n: ^Node) {
	x := n.kids[0]
	mark := new_slot(c) if (n.max > n.min if c.ecma else n.max > 1) && can_be_empty(x) else -1
	if c.ecma && n.max > 1 && looped(c, n) {
		emit_counter_loop(c, x, n.min, n.max, n.greedy, mark)
		return
	}
	splits := make([dynamic]int)
	checks := make([dynamic]int)
	start := len(c.insts)
	at := emitted(c)
	for i in 0 ..< n.max {
		// Under ECMA a repeat written out past ECMA_WRITTEN_OUT runs as a counter loop instead, whose single body
		// applies the empty-iteration rule by its count.
		if i == 1 && c.ecma && (len(c.insts) - start) * n.max > ECMA_WRITTEN_OUT {
			spill_to_counter_loop(c, at, n, n.min, n.max, n.greedy, mark)
			return
		}
		// Calls enter groups again and reuse the slots, so this counter loop is used only in a pattern without calls.
		if i == 1 && c.addr == nil && !c.ecma && (len(c.insts) - start) * n.max > COUNTED_WRITTEN_OUT {
			// The remaining iterations run in a counter loop, whose Count can exit the loop as a Split does.
			slot := new_slot(c)
			add(c, .Count_Reset, slot)
			loop := add(c, .Count if n.greedy else .Count_Lazy, slot)
			add(c, .Count, max(n.min - 1, 0), n.max - 1)
			append(&splits, loop)
			append(&checks, emit_body(c, x, mark))
			add(c, .Count_Next, slot, loop)
			break
		}
		if i >= n.min {
			append(&splits, add(c, .Split))
		}
		append(&checks, emit_body(c, x, -1 if c.ecma && i < n.min else mark))
		if c.err != "" {
			return
		}
	}
	if c.err != "" {
		return
	}
	exit := len(c.insts)
	for s in splits {
		if c.insts[s].op == .Split {
			patch(c, s, s + 1 if n.greedy else exit, exit if n.greedy else s + 1)
		} else {
			c.insts[s].b = i32(exit)
		}
	}
	for k in checks {
		if k >= 0 {
			patch(c, k, mark, -1 if c.ecma else exit)
		}
	}
}

// Emits a loop's body. With `mark` set it saves the mark before the body and adds a check after it that leaves the loop
// once an iteration matched empty. With `mark` -1 it adds neither. Under ECMA an iteration starts with its groups
// unset. Returns the check's instruction index, or -1.
@(private = "file")
emit_body :: proc(c: ^Compiler, x: ^Node, mark: int) -> int {
	if last := last_group(x); c.ecma && last > 0 {
		add(c, .Unset, 2 * first_group(x), 2 * last + 2)
	}
	if mark < 0 {
		emit(c, x)
		return -1
	}
	add(c, .Save, mark)
	outer := c.loop
	if c.ecma {
		append(&c.loops, [2]i32{i32(mark), i32(outer)})
		c.loop = len(c.loops) - 1
	}
	emit(c, x)
	check := add(c, .Check, mark)
	c.loop = outer
	return check
}

@(private = "file")
new_slot :: proc(c: ^Compiler) -> int {
	c.slots += 1
	return c.slots - 1
}

// The most instructions a counted repeat is written out to. A longer one runs its body in a counter loop, as
// Oniguruma's OP_REPEAT does.
@(private = "file")
COUNTED_WRITTEN_OUT :: 1024

// The most instructions an ECMA counted repeat is written out to. Few programs larger than this fit the automaton's
// caps. A longer repeat runs its body once in a counter loop, so nested repeats add their sizes instead of multiplying
// them.
@(private = "file")
ECMA_WRITTEN_OUT :: 1 << 13

// Whether the ECMA repeat `n` already runs as a counter loop, as found when a repeat around it emits its body again.
@(private = "file")
looped :: proc(c: ^Compiler, n: ^Node) -> bool {
	return slice.contains(c.looped[:], n)
}

// The length of each of the compiler's lists at one point, for `take_back`.
@(private = "file")
Emitted :: struct {
	insts, bytes, classes, refs, loops, counters: int,
}

@(private = "file")
emitted :: proc(c: ^Compiler) -> Emitted {
	return {len(c.insts), len(c.bytes), len(c.classes), len(c.refs), len(c.loops), len(c.counters)}
}

// Drops what was emitted since `at`. Its slots stay allocated and unread.
@(private = "file")
take_back :: proc(c: ^Compiler, at: Emitted) {
	resize(&c.insts, at.insts)
	resize(&c.loop_of, at.insts)
	resize(&c.counter_of, at.insts)
	resize(&c.bytes, at.bytes)
	resize(&c.classes, at.classes)
	resize(&c.refs, at.refs)
	resize(&c.loops, at.loops)
	resize(&c.counters, at.counters)
}

// Drops what was emitted since `at` and emits the repeat `n` as a counter loop, which `looped` records.
@(private = "file")
spill_to_counter_loop :: proc(c: ^Compiler, at: Emitted, n: ^Node, least, most: int, greedy: bool, mark: int) {
	take_back(c, at)
	append(&c.looped, n)
	emit_counter_loop(c, n.kids[0], least, most, greedy, mark)
}

// Emits an ECMA repeat of `x` from `least` to `most` times as one body in a loop whose count is kept in a slot of its
// own. With a `mark`, an iteration past the least count that matches empty fails, and one short of it continues.
@(private = "file")
emit_counter_loop :: proc(c: ^Compiler, x: ^Node, least, most: int, greedy: bool, mark: int) {
	slot := new_slot(c)
	add(c, .Count_Reset, slot)
	outer := c.counter
	append(&c.counters, Counter{slot, least, most, outer})
	c.counter = len(c.counters) - 1
	loop := add(c, .Count if greedy else .Count_Lazy, slot)
	add(c, .Count, least, most)
	check := emit_body(c, x, mark)
	add(c, .Count_Next, slot, loop)
	c.counter = outer
	patch(c, loop, slot, len(c.insts))
	if check >= 0 && check < len(c.insts) {
		c.insts[check] = {.Count_Check, i32(mark), i32(loop)}
	}
}

@(private = "file")
emit_look :: proc(c: ^Compiler, n: ^Node) {
	body := n.kids[0]
	back := 0
	behind := n.look == .Behind || n.look == .Not_Behind
	if behind && !c.ecma {
		ok: bool
		body, c.err = tune_behind(body, n.look == .Not_Behind)
		if c.err != "" {
			return
		}
		c.tuned = max(c.tuned, last_group(body)) // tune_look_behind tunes its body before it measures it
		back, ok = fixed_length(c, body)
		if !ok {
			c.err = "invalid pattern in look-behind"
			return
		}
	}
	look := add(c, .Look, int(n.look))
	if back > 0 {
		add(c, .Back, back)
	}
	// The visited set may carry an ECMA look-around on at its end with its groups unset (match.odin), so the groups are
	// unset from its start too.
	if last := last_group(body); c.ecma && last > 0 && (n.look == .Ahead || n.look == .Behind) {
		add(c, .Unset, 2 * first_group(body), 2 * last + 2)
	}
	leftwards := c.leftwards
	c.leftwards = c.ecma && behind
	c.looking += 1
	emit(c, body)
	c.looking -= 1
	c.leftwards = leftwards
	end := add(c, .Look_End)
	patch(c, look, int(n.look), end)
}

// The least group number in `n`, 0 for none.
@(private)
first_group :: proc(n: ^Node) -> int {
	if n.kind == .Group && n.group > 0 {
		return n.group // a group's number is less than those inside it
	}
	for k in n.kids {
		if g := first_group(k); g > 0 {
			return g
		}
	}
	return 0
}

// The greatest group number in `n`, 0 for none.
@(private)
last_group :: proc(n: ^Node) -> int {
	last := n.group if n.kind == .Group else 0
	for k in n.kids {
		last = max(last, last_group(k))
	}
	return last
}
