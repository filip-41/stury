// Package regex is the Oniguruma-syntax engine behind jq's `test`, `match`, `sub` and the like.
// A pattern goes: parse.odin (`parse`: source to a tree of Nodes, with Oniguruma's error messages),
// call.odin (`check_calls`: \g<...> calls checked for endless recursion), compile.odin (`compile`:
// the tree to a Regex holding a program of Insts), analyze.odin (a look-behind tuned to a fixed length,
// and the literals a search can skip by), optimize.odin (Oniguruma's search optimizer), then match.odin (`search`: the backtracking matcher over that
// program). unicode.odin supplies character classes and case folds to all of them, from the generated
// unicode_tables.odin.
package regex

// A pattern's tree as a program for the backtracking matcher (match.odin), with what the search can skip
// by: Oniguruma's optimizer's choice (optimize.odin), a literal every match starts with, the bytes one starts with.

import "core:mem"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// The most memory, in bytes, that a program may take, and that a linear search's visited sets, backtrack stack and log
// take together. Short counted repeats are written out, so many of them would otherwise take unbounded memory.
// Oniguruma has no such limit.
@(private)
MAX_BYTES :: 1 << 28

@(private)
MEMORY_ERROR :: "fail to memory allocation"

// The pattern's options: jq's `i`, `x` and `s` flags, or `ecma` alone for a JSON Schema pattern (parse.odin). `longest`
// and `not_empty` change only the search: ONIG_OPTION_FIND_LONGEST takes the longest match of all, not the first, and
// ONIG_OPTION_FIND_NOT_EMPTY takes no empty match.
Flags :: struct {
	fold, extend, dotall, multiline, ecma, longest, not_empty: bool,
}

@(private)
Op :: enum u8 {
	Match,
	Str, // the literal bytes[a:][:b]
	Char_Fold, // a rune whose fold is a
	Any, // any rune but "\n"
	Any_All,
	Class, // classes[a]
	Split, // go on at a; on failure, at b
	Split_Head, // a greedy loop: go on at pc+1 when the byte at the position is a, on failure at b; otherwise at b
	Jmp, // to a
	Save, // slot a = the position (captures, loop marks, and \K as slot 0); b: a group's start, which unsets its end
	Set, // slot a = the position, kept as the match backs past it: a group's bound Oniguruma writes in place
	Assert, // Assert_Kind(a); a callout's data at callouts[b]
	Backref, // the text of one of refs[a]'s groups; b: folded
	Look, // a look-around or atomic group, Look_Kind(a), ending at the Look_End at b
	Look_End,
	Back, // a runes back, for a look-behind
	Check, // a loop's body matched empty when slot a is the position: leave the loop, for b, or fail for b -1
	Unset, // slots a up to b = -1: the groups of an ECMA loop's body, at each iteration
	Cond, // group a matched: go on; otherwise go to b
	Linebreak, // \R
	Grapheme, // \X
	Rep, // the one-rune instruction after this, a to b times (b -1: no bound), as many as can; then pc+2
	Rep_Lazy, // the same, as few as can
	Count_Reset, // slot a, a counted loop's iterations, = 0
	Count, // a counted loop at slot a: its body at pc+2 runs while slot a is short of insts[pc+1].a, may run while short of insts[pc+1].b, as many times as can; then on to b
	Count_Lazy, // the same, as few times as can
	Count_Next, // slot a += 1, then to the loop's Count at b
	Count_Check, // as Check under ECMA, failing only once the loop whose Count is at b has run its least count
	Seen, // a pair a linear search has been to: fails (match.odin)
	// Call and the ops after it are a call's or an absent operator's, which `Regex.calls_or_limits` tells of.
	Call, // the group at a, which returns to pc+1; b: its number
	Return,
	Mem_Start, // group a's start, in a group that calls itself, whose end finds the start of its own call
	Mem_End,
	Limit_Save, // slot a = the text's end as matched against (an absent's limit), restored when the match backs past
	Limit_Cut, // the limit = slot a, kept as the match backs within the absent
	Limit_Restore, // the limit = slot a
	Limit_Clear, // the limit = the text's end
}

@(private)
Inst :: struct {
	op:   Op,
	a, b: i32,
}

// A compiled pattern, which `search` runs.
Regex :: struct {
	using program: Program,
}

@(private)
Program :: struct {
	insts:    []Inst,
	bytes:    string,
	classes:  []^Class,
	refs:     [][]int,
	callouts: []^Callout, // those that keep data, each at its index
	names:    []string, // group n's name at n, "" for none; [0] is the whole match
	slots:    int, // two per group with the whole match, then a mark per loop that can match empty
	opt:      ^Search_Opt, // what Oniguruma's optimizer would have the search skip by, kept apart since a Regex is copied
	visited:  ^Visited, // under `linear`, what the visited set needs of the program
	dfa:      ^Dfa, // the automaton that answers a search that reads no bounds, or nil (dfa.odin)
	prefix:   string, // every match starts with these bytes
	first:     [4]u64, // with has_first, the bytes a match can start with
	longest:   bool, // Flags.longest
	not_empty: bool, // Flags.not_empty
	has_first: bool,
	calls_or_limits: bool, // holds a subexpression call or an absent operator, whose tracking the match then runs
	narrowed:  bool, // `opt` bounds the starts the search tries
	ecma:      bool, // compiled under `Flags.ecma`, whose search refuses a text too long for the visited set
	// A program with choices whose outcome at an instruction and a position does not depend on the way there: the search
	// keeps the pairs it has been to, so no pair runs twice. The ECMA programs `linear_ops` allows, and the jq ones.
	linear:    bool,
}

// The program's facts the visited set reads, kept behind a pointer since a Regex is copied.
@(private)
Visited :: struct {
	owner:   []i32, // the look-ahead each instruction lies in, -1 for none, or nil for no look-ahead
	// The ECMA loops whose body may match empty, each one's mark slot and the loop around it (-1 for none), the
	// innermost each instruction lies in (-1 for none), and each instruction's first row of the visited set, the row
	// count last. An instruction has a row and one more for each loop around it, since an iteration that has matched
	// nothing yet fails where one that has goes on (`row_of`). Nil when no such loop.
	loops:   [][2]i32,
	loop_of: []i32,
	// The ECMA counter loops, the innermost each instruction lies in (-1 for none, nil for no loop), and each
	// instruction's rows for one count of the loops around it (`block`). An instruction has a block of rows for each
	// count of each loop around it, since what follows depends on the count. A program with counter loops has its
	// rows laid out for each search (`counted_rows`), the others here.
	counters:   []Counter,
	counter_of: []i32,
	block:      []int,
	rows:       []int,
}

// An ECMA counter loop's slot, its least and most counts, and the loop around it, -1 for none.
@(private)
Counter :: struct {
	slot, least, most, outer: int,
}

@(private)
Compiler :: struct {
	insts:      [dynamic]Inst,
	bytes:      [dynamic]byte,
	classes:    [dynamic]^Class,
	refs:       [dynamic][]int,
	groups:     []^Node, // the group nodes by number
	referenced: []bool, // by group number: a backreference or condition reads it
	undone:     []bool, // by group number: the match undoes its bounds as it backs past them (`mark_undone`)
	open:       [dynamic]int, // the groups being emitted, innermost last
	ecma:       bool, // ECMA's loops: no counter loops, no Rep in a look-ahead, an empty iteration fails
	looking:    int, // the look-aheads being emitted
	loops:      [dynamic][2]i32, // `Regex.loops`
	loop_of:    [dynamic]i32, // under ECMA
	loop:       int, // the loop being emitted, -1 for none
	counters:   [dynamic]Counter, // `Visited.counters`
	counter_of: [dynamic]i32, // under ECMA
	counter:    int, // the counter loop being emitted, -1 for none
	looped:     [dynamic]^Node, // the ECMA repeats run as counter loops, which a repeat around them emits again
	tuned:      int, // the last group Oniguruma's tune_tree has reached, as a look-behind measures one
	slots:      int,
	err:        string,
	called:     []bool, // by group number: a call reaches it, so it is a subroutine
	recursive:  []bool, // by group number: its body calls itself
	addr:       []int, // by group number: a called group's first instruction, -1 until emitted
}

// Whether `pattern` is well formed under `flags`. It builds no program, frees what it allocated, and under `ecma`
// takes back references and look-behind as syntax, since a JSON Schema pattern may hold them.
valid :: proc(pattern: string, flags: Flags) -> bool {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena)
	defer mem.dynamic_arena_destroy(&arena)
	context.allocator = mem.dynamic_arena_allocator(&arena)
	_, err := parse(pattern, flags, true)
	return err == ""
}

// Whether `r` has the Unicode property `name` as Oniguruma spells it (`\p{name}`: a general category, a script or a
// binary property). A name it does not know holds for no rune.
in_property :: proc(name: string, r: rune) -> bool {
	it, ok := named_prop(name)
	return ok && in_table(int(it.table), r)
}

// `pattern` compiled as jq compiles it, or Oniguruma's message for why not. The program, what it was built from and
// any message are allocated from `allocator`, which is meant to be an arena the caller frees whole. With `automaton`
// the automaton that answers whether there is a match is built too, which pays for a regex that searches more than a
// few short texts, and with `spans` also the two that find where a match ends and starts, which pay for a regex whose
// searches read bounds. Their build borrows its working memory from `context.allocator` and frees it before returning.
compile :: proc(pattern: string, flags: Flags, allocator := context.allocator, automaton := true, spans := false) -> (re: Regex, err: string) {
	scratch := context.allocator
	if re, err = program(pattern, flags, allocator); err == "" && automaton {
		re.dfa = build_dfa(&re, spans, allocator, scratch)
	}
	return
}

// Oniguruma's message for why `pattern` does not compile under `flags`, allocated from `allocator`, or "" when it does.
// It builds no automaton and frees the program it made.
refusal :: proc(pattern: string, flags: Flags, allocator := context.allocator) -> string {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(&arena, block_size = 4096, out_band_size = 1024)
	defer mem.dynamic_arena_destroy(&arena)
	_, err := program(pattern, flags, mem.dynamic_arena_allocator(&arena))
	return strings.clone(err, allocator) if err != "" else ""
}

// `compile` without the automaton.
@(private = "file")
program :: proc(pattern: string, flags: Flags, allocator: mem.Allocator) -> (re: Regex, err: string) {
	context.allocator = allocator
	if flags.ecma && flags != {ecma = true} {
		return {}, "ecma takes no other flag"
	}
	pat: Pattern
	if pat, err = parse(pattern, flags); err != "" {
		return
	}
	names := pat.names
	root := expand_folds(pat.root)
	c := Compiler{slots = 2 * len(names), groups = pat.groups, referenced = pat.referenced, ecma = flags.ecma, loop = -1, counter = -1}
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
	} else if flags.ecma {
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
	}
	prefix := make([dynamic]byte)
	literal_prefix(root, &prefix)
	re.prefix = string(prefix[:])
	// A callout that ends the search or counts over its starts sees which starts are tried, so the skip is then
	// held to the one Oniguruma's optimizer makes: none by a class or fold that may take a non-ASCII rune.
	like_onig := false
	for co in pat.callouts {
		like_onig ||= co.kind == .Error || co.kind == .Total_Count
	}
	empty, known := first_bytes(root, &re.first, like_onig)
	re.has_first = known && !empty
	// A string or map the optimizer finds at the start of every match is a skip the prefix and first bytes make
	// without windows, and they leave no start too near the end for it.
	o := re.opt
	if o.dist_min == 0 && o.dist_max == 0 {
		#partial switch o.kind {
		case .Exact:
			if re.prefix == "" {
				re.prefix = o.exact
			}
			if strings.has_prefix(re.prefix, o.exact) {
				o.kind, o.threshold = .None, 0
			}
		case .Map:
			re.first = re.first & o.set if re.has_first else o.set
			re.has_first = true
			o.kind, o.threshold = .None, 0
		}
	}
	re.narrowed = o.kind != .None || o.anchored || o.end != .None || o.threshold > 0
	for ins in re.insts {
		re.calls_or_limits ||= ins.op >= .Call
	}
	re.ecma, re.linear = flags.ecma, linear_ops(re.insts, flags.ecma, re.opt.anchored)
	re.longest, re.not_empty = flags.longest, flags.not_empty
	if re.linear {
		v := new(Visited)
		re.visited = v
		if flags.ecma {
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

// Each instruction's first row of the visited set into `rows`, the total last: its block, times the counts
// `radix` gives each counter loop around it. A total past MAX_ROWS is held at it.
@(private)
lay_out_rows :: proc(v: ^Visited, rows: []int, radix: []int) {
	rows[0] = 0
	for block, pc in v.block {
		times := 1
		if radix != nil {
			for k := int(v.counter_of[pc]); k >= 0; k = v.counters[k].outer {
				times = min(times * radix[k], MAX_ROWS)
			}
		}
		rows[pc + 1] = min(rows[pc] + block * times, MAX_ROWS)
	}
}

// More rows than a visited set within MAX_BYTES holds over one place.
@(private)
MAX_ROWS :: MAX_BYTES * 8 + 1

// Whether the visited set pays and holds for a program. Under ECMA it does with a loop, a look-ahead, two choices, or one
// choice in a search that tries more than one start. Under jq it does with a
// choice inside a loop, the one shape that backtracks past polynomial time, and when each instruction's outcome depends
// on the position alone: no look-around, back reference, counter, call or callout, and no empty check, whose exit
// Oniguruma takes where ECMA fails.
@(private = "file")
linear_ops :: proc(insts: []Inst, ecma: bool, anchored: bool) -> bool {
	for ins in insts {
		allowed := ecma
		#partial switch ins.op {
		case .Match, .Str, .Char_Fold, .Any, .Any_All, .Class, .Split, .Split_Head, .Jmp, .Set, .Linebreak, .Rep, .Rep_Lazy:
			allowed = true
		case .Save:
			allowed ||= ins.a != 0 && ins.b == 0 // not \K, nor a referenced group's start
		case .Assert:
			allowed ||= Assert_Kind(ins.a) < .Fail
		}
		if !allowed {
			return false
		}
	}
	choices := 0
	for ins, i in insts {
		if ecma {
			// A program that starts at one place and has one choice and no loop or look-ahead tries each alternative
			// of it along a straight line, so the set would only cost.
			choices += int(is_choice(ins))
			if ins.op == .Look || ins.op == .Count_Next || ins.op == .Jmp && int(ins.a) < i {
				return true
			}
		} else if ins.op == .Jmp && int(ins.a) < i && slice.any_of_proc(insts[ins.a + 1:i], is_choice) {
			return true
		}
	}
	return choices > 1 || choices == 1 && !anchored
}

@(private = "file")
is_choice :: proc(ins: Inst) -> bool {
	#partial switch ins.op {
	case .Split, .Split_Head, .Count, .Count_Lazy, .Look:
		return true
	case .Rep, .Rep_Lazy:
		return ins.a != ins.b
	}
	return false
}

// For each instruction, the look-ahead whose body it lies in (the innermost), or -1. Nil for none.
@(private = "file")
look_owners :: proc(insts: []Inst) -> []i32 {
	owner: []i32
	for ins, i in insts {
		if ins.op != .Look {
			continue
		}
		if owner == nil {
			owner = make([]i32, len(insts))
			slice.fill(owner, -1)
		}
		for k in i + 1 ..= int(ins.b) {
			owner[k] = i32(i)
		}
	}
	return owner
}

// The called groups no call has emitted in place (as a group under `{0}` is), each after the program, then each
// call's address.
@(private = "file")
emit_subroutines :: proc(c: ^Compiler) {
	// By index: emitting a group grows c.insts, and the loop reaches the calls it emits.
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

// Oniguruma's multi-character case folds (expand_case_fold_string, and a class's strings): under (?i) a character
// that folds to two or three (ß to ss) also matches them. Two or three characters of a run that fold to those (ss)
// also match the one character, three tried before two and the run going on past them, and a class not negated
// matches, after its one character, the strings its characters fold to. In a look-behind's body only the classes have
// them, as Oniguruma's parser gives them.
@(private = "file")
expand_folds :: proc(n: ^Node, behind := false) -> ^Node {
	#partial switch n.kind {
	case .Look:
		if n.look == .Behind || n.look == .Not_Behind {
			n.kids[0] = expand_folds(n.kids[0], true)
			return n
		}
	case .Char:
		if runes, ok := multi_fold(n.r); ok && n.fold && !behind {
			return new_node(.Alt, n, fold_string(runes))
		}
		return n
	case .Class:
		strs := class_strings(n.class)
		if len(strs) == 0 {
			return n
		}
		alt := new_node(.Alt, n)
		for s in strs {
			append(&alt.kids, fold_string(s))
		}
		return alt
	case .Cat:
		if behind {
			break
		}
		kids := make([dynamic]^Node, 0, len(n.kids))
		for i := 0; i < len(n.kids); {
			run := 0
			for i + run < len(n.kids) && run < 3 && n.kids[i + run].kind == .Char && n.kids[i + run].fold {
				run += 1
			}
			width := 1
			for w := run; w >= 2 && width == 1; w -= 1 {
				runes: [3]rune
				for k in 0 ..< w {
					runes[k] = n.kids[i + k].r
				}
				if r, ok := unfold(runes[:w]); ok {
					one := new_node(.Char)
					one.r, one.fold = r, true
					append(&kids, new_node(.Alt, new_node(.Cat, ..n.kids[i:i + w]), one))
					width = w
				}
			}
			if width == 1 {
				append(&kids, expand_folds(n.kids[i]))
			}
			i += width
		}
		n.kids = kids
		return n
	}
	for &k in n.kids {
		k = expand_folds(k, behind)
	}
	return n
}

// The strings, folded, a (?i) class that is not negated matches besides its characters: those its
// characters fold to, each once.
@(private = "file")
class_strings :: proc(cls: ^Class) -> [dynamic][]u32 {
	out := make([dynamic][]u32)
	if !cls.fold || cls.negated {
		return out
	}
	next: for &f in MULTI_FOLDS {
		if !class_match_slow(cls, rune(f[0])) {
			continue
		}
		s, _ := multi_fold(rune(f[0]))
		for t in out {
			if slice.equal(s, t) {
				continue next
			}
		}
		append(&out, s)
	}
	return out
}

@(private = "file")
fold_string :: proc(runes: []u32) -> ^Node {
	n := new_node(.Cat)
	for r in runes {
		k := new(Node)
		k.kind, k.r, k.fold = .Char, rune(r), true
		append(&n.kids, k)
	}
	return n
}

@(private = "file")
add :: proc(c: ^Compiler, op: Op, a: int = 0, b: int = 0) -> int {
	if len(c.insts) * size_of(Inst) >= MAX_BYTES {
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

// A character a fold-insensitive comparison sees as only itself.
@(private)
literal :: proc(n: ^Node) -> bool {
	return n.kind == .Str || n.kind == .Char && utf8.valid_rune(n.r) && (!n.fold || fold_next(n.r) == n.r)
}

// The bytes of a `literal` node, a Char's written into `buf`.
@(private)
literal_text :: proc(n: ^Node, buf: ^[4]byte) -> string {
	if n.kind == .Str {
		return n.text
	}
	w: int
	buf^, w = utf8.encode_rune(n.r)
	return string(buf[:w])
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
		for x, k in c.classes { 	// a repeat's copies share the class
			if x == cls {
				add(c, .Class, k)
				return
			}
		}
		for r in rune(0) ..< 0x80 {
			if class_match_slow(cls, r) {
				cls.ascii[r >> 6] |= 1 << (u64(r) & 63)
			}
		}
		append(&c.classes, cls)
		add(c, .Class, len(c.classes) - 1)
	case .Cat:
		for i := 0; i < len(n.kids); {
			j := i
			for j < len(n.kids) && literal(n.kids[j]) {
				j += 1
			}
			if j > i {
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
		// A called group is a subroutine, which the group in place calls too. A counted repeat's later copy of it
		// calls the first.
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
		add(c, .Call, -1, n.target.group) // its address once every group is emitted (`emit_subroutines`)
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
		add(c, .Backref, len(c.refs) - 1, int(n.fold))
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

// A group's captures and body. One that calls itself takes its start from the stack at its end, as Oniguruma's
// OP_MEM_END_REC does, so it captures where its own call began. The whole pattern called (group 0) captures nothing
// of its own.
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

// The groups whose bounds Oniguruma pushes (its backtrack_mem), so the match undoes them as it backs past: those
// within an alternative, a condition's branch, a negative look, an absent operator or a repeat of no fixed count.
// Every other group's MEM_START and MEM_END write its bounds in place, and those a failed try wrote stay.
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

// An absent operator as Oniguruma's make_absent_tree runs one: the end the match reads to (its limit) is saved. The
// absent is tried at each position from here short of the limit, and where it first matches becomes the limit, inside
// a negative look so its captures and position are undone, then exp runs, and the saved limit comes back after it. A
// stopper keeps the new limit, and `(?~|)` sets it to the text's end.
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
	// Under ECMA a look-ahead's body has no Rep, whose alternatives the visited set's log does not follow (match.odin).
	if (x.kind == .Char || x.kind == .Any || x.kind == .Class) && (n.max != n.min || c.ecma) && !(c.ecma && c.looking > 0) {
		add(c, .Rep if n.greedy else .Rep_Lazy, n.min, n.max)
		emit(c, x)
		return
	}
	if n.max >= 0 {
		emit_counted(c, n)
		return
	}
	// A body that can match empty is left once an iteration of it does, as Oniguruma's empty check
	// leaves it, so `(a*)*` ends.
	empty := can_be_empty(x)
	// One least iteration of a body that cannot match empty enters the loop past its Split, as Oniguruma's OP_JUMP
	// does, rather than as a copy, which nested repeats would double at every level.
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
				take_back(c, at)
				append(&c.looped, n)
				emit_counter_loop(c, x, n.min, n.min, true, -1)
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
	} else if h := head_literal(x); h != nil && (h.kind == .Str || h.kind == .Char && !h.fold && utf8.valid_rune(h.r)) && n.greedy && n.min <= 1 {
		// Oniguruma's OP_PUSH_OR_JUMP_EXACT1: no alternative is kept for an iteration that cannot start (one that
		// starts with an exact character, no class, no case folding), which its retry limit counts.
		head, _ := utf8.encode_rune(h.r)
		c.insts[loop] = {op = .Split_Head, a = i32(head[0]), b = i32(exit)}
	}
}

// A repeat to a most count. Oniguruma's counted repeat leaves a body that can match empty once an iteration
// of it does, short of its least count too: `(|a){2}b` matches "ab" with the group empty after the a. ECMA's lets an
// iteration short of the least count match empty, and fails one past it that does, `(a?)?` included.
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
		// Under ECMA a repeat written out past ECMA_WRITTEN_OUT runs as a counter loop instead, whose one body holds
		// the empty-iteration rule by its count.
		if i == 1 && c.ecma && (len(c.insts) - start) * n.max > ECMA_WRITTEN_OUT {
			take_back(c, at)
			append(&c.looped, n)
			emit_counter_loop(c, x, n.min, n.max, n.greedy, mark)
			return
		}
		// A call reuses the slots, so a counter is only kept where no group can be entered again.
		if i == 1 && c.addr == nil && !c.ecma && (len(c.insts) - start) * n.max > COUNTED_WRITTEN_OUT {
			// The rest in a counter loop: its Count is an exit, as a Split is.
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

// A loop's body, after a mark and before the check that leaves the loop once an iteration matched empty, or
// with neither for `mark` -1. Under ECMA an iteration starts with its groups unset. The check's index, or -1.
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

// The most instructions an ECMA counted repeat is written out to, which the automaton needs, and few programs past it
// fit the automaton's caps. A longer one runs its body once in a counter loop, so nested repeats add their bodies
// rather than multiply them.
@(private = "file")
ECMA_WRITTEN_OUT :: 1 << 13

// Whether the ECMA repeat `n` runs as a counter loop, which a repeat around it emitting its body again finds.
@(private = "file")
looped :: proc(c: ^Compiler, n: ^Node) -> bool {
	return slice.contains(c.looped[:], n)
}

// How much of each of the compiler's lists has been emitted, for `take_back`.
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

// An ECMA repeat of `x` from `least` to `most` times as one body in a loop whose count is in a slot of its own. With a
// `mark`, an iteration past the least count that matches nothing fails, and one short of it goes on.
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
	if n.look == .Behind || n.look == .Not_Behind {
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
	// The visited set may carry an ECMA look-ahead on at its end with its groups unset (match.odin), which they are
	// from its start too.
	if last := last_group(body); c.ecma && last > 0 && n.look == .Ahead {
		add(c, .Unset, 2 * first_group(body), 2 * last + 2)
	}
	c.looking += 1
	emit(c, body)
	c.looking -= 1
	end := add(c, .Look_End)
	patch(c, look, int(n.look), end)
}



@(private)
class_match_slow :: proc(cls: ^Class, r: rune) -> bool {
	// `r`, then each character of its case fold orbit when the class folds.
	x := r
	for {
		for g in cls.ranges {
			if x >= g[0] && x <= g[1] {
				return !cls.negated
			}
		}
		for it in cls.props {
			if in_table(int(it.table), x) != it.neg {
				return !cls.negated
			}
		}
		if !cls.fold {
			return cls.negated
		}
		x = fold_next(x)
		if x == r {
			return cls.negated
		}
	}
}
