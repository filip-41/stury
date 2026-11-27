package regex

// Compiles a pattern's tree into a program for the backtracking matcher (match.odin), with what the search can skip by:
// the choice of Oniguruma's optimizer (optimize.odin), a literal that every match starts with, and the bytes that a
// match starts with.

import "core:mem"
import "core:slice"
import "core:strings"
import "stury:lib/base/kernel"

@(private)
Compiler :: struct {
	insts:      [dynamic]Inst,
	bytes:      [dynamic]byte,
	classes:    [dynamic]^Class,
	refs:       [dynamic][]int,
	groups:     []^Node, // the group nodes, indexed by group number
	referenced: []bool, // by group number: true when a backreference or condition reads it
	undone:     []bool, // by group number: the match undoes its bounds as it backs past them (`mark_undone`), nil for all
	open:       [dynamic]int, // the groups being emitted, innermost last
	ecma:       bool, // set under ECMA: no Rep in a look-ahead, an empty iteration fails
	looking:    int, // the number of look-arounds being emitted, nested
	leftwards:  bool, // emitting an ECMA look-behind's body, which matches leftwards from where the look-behind is
	loops:      [dynamic][2]i32, // `Visited.loops`
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
	called:     []bool, // by group number: a call reaches it, so it is a subroutine (nil when no calls)
	recursive:  []bool, // by group number: its body calls itself (nil when no calls)
	addr:       []int, // by group number: a called group's first instruction, -1 until emitted (nil when no calls)
}

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
	if pat.has_calls {
		c.called = make([]bool, len(names))
		c.recursive = make([]bool, len(names))
		if gate_failed(context.allocator) {
			return {}, MEMORY_ERROR
		}
		if err = check_calls(root, c.groups, c.called, c.recursive); err != "" {
			return
		}
		c.addr = make([]int, len(names))
		if gate_failed(context.allocator) {
			return {}, MEMORY_ERROR
		}
		slice.fill(c.addr, -1)
	} else if !options.ecma {
		c.undone = slice.clone(c.referenced)
		if gate_failed(context.allocator) {
			return {}, MEMORY_ERROR
		}
		mark_undone(root, c.undone, false)
	}
	for g in 1 ..< len(names) {
		c.groups[g].used = c.referenced[g] || (c.called != nil && c.called[g])
	}
	emit(&c, root)
	add(&c, .Match)
	if pat.has_calls && c.err == "" && !gate_failed(context.allocator) {
		emit_subroutines(&c)
	}
	if c.err != "" {
		return {}, c.err
	}
	if gate_failed(context.allocator) {
		return {}, MEMORY_ERROR
	}
	re = {
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
	if gate_failed(context.allocator) {
		return {}, MEMORY_ERROR
	}
	// A callout that ends the search or counts the starts sees which starts are tried, so no head beyond Oniguruma's
	// optimizer is built.
	like_onig := false
	for co in pat.callouts {
		like_onig ||= co.kind == .Error || co.kind == .Total_Count
	}
	h := re.head
	if !like_onig {
		prefix: [dynamic]byte
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
		// Upper 128 bytes stay set so SIMD head skipping stops at UTF-8 lead bytes (optimize.odin).
		h.lead = kernel.byte_set([4]u64{h.set[0], h.set[1], max(u64), max(u64)})
	}
	if o.kind == .Map {
		// Upper 128 bytes stay set so SIMD window skipping stops at UTF-8 lead bytes (skip.odin).
		o.lead = kernel.byte_set([4]u64{o.set[0], o.set[1], max(u64), max(u64)})
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
		if gate_failed(context.allocator) {
			return {}, MEMORY_ERROR
		}
		re.visited = v
		if options.ecma {
			v.owner = look_owners(re.insts)
		}
		if len(c.loops) > 0 || len(c.counters) > 0 {
			v.loops, v.loop_of = c.loops[:], c.loop_of[:]
			v.block = make([]int, len(re.insts))
			if gate_failed(context.allocator) {
				return {}, MEMORY_ERROR
			}
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
				if gate_failed(context.allocator) {
					return {}, MEMORY_ERROR
				}
				lay_out_rows(v, v.rows, nil)
			}
		}
	}
	return re, ""
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
