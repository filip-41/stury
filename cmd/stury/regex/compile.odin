// Package regex is the Oniguruma-syntax engine behind jq's `test`, `match`, `sub` and the like.
// A pattern goes: parse.odin (`parse`: source to a tree of Nodes, with Oniguruma's error messages),
// call.odin (`check_calls`: \g<...> calls checked for endless recursion), compile.odin (`compile`:
// the tree to a Regex holding a program of Insts), analyze.odin (a look-behind tuned to a fixed length,
// and the literals a search can skip by), then match.odin (`search`: the backtracking matcher over that
// program). unicode.odin supplies character classes and case folds to all of them, from the generated
// unicode_tables.odin.
package regex

// A pattern's tree as a program for the backtracking matcher (match.odin), with what the search can skip
// by: a literal every match starts with, one every match holds, a start pinned to \A.

import "core:slice"
import "core:unicode/utf8"

// The most instructions a program may have: short counted repeats are written out, so many of them would
// otherwise take unbounded memory. Oniguruma has no such limit.
MAX_INSTS :: 1 << 21

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
	Assert, // Assert_Kind(a); a callout's data at callouts[b]
	Backref, // the text of one of refs[a]'s groups; b: folded
	Look, // a look-around or atomic group, Look_Kind(a), ending at the Look_End at b
	Look_End,
	Back, // a runes back, for a look-behind
	Check, // a loop's body matched empty when slot a is the position: leave the loop, for b
	Cond, // group a matched: go on; otherwise go to b
	Linebreak, // \R
	Grapheme, // \X
	Rep, // the one-rune instruction after this, a to b times (b -1: no bound), as many as can; then pc+2
	Rep_Lazy, // the same, as few as can
	Count_Reset, // slot a, a counted loop's iterations, = 0
	Count, // a counted loop at slot a: its body at pc+2 runs while slot a is short of insts[pc+1].a, may run while short of insts[pc+1].b, as many times as can; then on to b
	Count_Lazy, // the same, as few times as can
	Count_Next, // slot a += 1, then to the loop's Count at b
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

Inst :: struct {
	op:   Op,
	a, b: i32,
}

Regex :: struct {
	insts:    []Inst,
	bytes:    string,
	classes:  []^Class,
	refs:     [][]int,
	callouts: []^Callout, // those that keep data, each at its index
	names:    []string, // group n's name at n, "" for none; [0] is the whole match
	slots:    int, // two per group with the whole match, then a mark per loop that can match empty
	longest:   bool, // ONIG_OPTION_FIND_LONGEST: the longest match of all, not the first
	not_empty: bool, // ONIG_OPTION_FIND_NOT_EMPTY: an empty match is no match
	anchored: bool, // every match starts at \A
	prefix:   string, // every match starts with these bytes
	required:  string, // every match holds these bytes
	first:     [4]u64, // with has_first, the bytes a match can start with
	has_first: bool,
	calls_or_limits: bool, // holds a subexpression call or an absent operator, whose tracking the match then runs
}

@(private)
Compiler :: struct {
	insts:      [dynamic]Inst,
	bytes:      [dynamic]byte,
	classes:    [dynamic]^Class,
	refs:       [dynamic][]int,
	groups:     []^Node, // the group nodes by number
	referenced: []bool, // by group number: a backreference or condition reads it
	open:       [dynamic]int, // the groups being emitted, innermost last
	tuned:      int, // the last group Oniguruma's tune_tree has reached, as a look-behind measures one
	slots:      int,
	err:        string,
	called:     []bool, // by group number: a call reaches it, so it is a subroutine
	recursive:  []bool, // by group number: its body calls itself
	addr:       []int, // by group number: a called group's first instruction, -1 until emitted
}

// `pattern` compiled as jq compiles it, or Oniguruma's message for why not.
compile :: proc(pattern: string, flags: Flags) -> (re: Regex, err: string) {
	decode_tables()
	pat: Pattern
	if pat, err = parse(pattern, flags); err != "" {
		return
	}
	names := pat.names
	root := expand_folds(pat.root)
	c := Compiler{slots = 2 * len(names), groups = pat.groups, referenced = pat.referenced}
	c.called = make([]bool, len(names))
	c.recursive = make([]bool, len(names))
	if pat.has_calls {
		if err = check_calls(root, c.groups, c.called, c.recursive); err != "" {
			return
		}
		c.addr = make([]int, len(names))
		slice.fill(c.addr, -1)
	}
	for g in 1 ..< len(names) {
		c.groups[g].used = c.referenced[g] || c.called[g]
	}
	emit(&c, root)
	append(&c.insts, Inst{op = .Match})
	if pat.has_calls {
		emit_subroutines(&c)
	}
	if c.err != "" {
		return {}, c.err
	}
	re = Regex {
		insts    = c.insts[:],
		bytes    = string(c.bytes[:]),
		classes  = c.classes[:],
		refs     = c.refs[:],
		callouts = pat.callouts,
		names    = names,
		slots    = c.slots,
		anchored = starts_at_buffer(root),
	}
	prefix := make([dynamic]byte)
	literal_prefix(root, &prefix)
	re.prefix = string(prefix[:])
	re.required = required_literal(root)
	// A callout that ends the search or counts over its starts sees which starts are tried, so the skip is then
	// held to the one Oniguruma's optimizer makes: none by a class or fold that may take a non-ASCII rune.
	like_onig := false
	for co in pat.callouts {
		like_onig ||= co.kind == .Error || co.kind == .Total_Count
	}
	empty, known := first_bytes(root, &re.first, like_onig)
	re.has_first = known && !empty
	for ins in re.insts {
		re.calls_or_limits ||= ins.op >= .Call
	}
	return re, ""
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
			return either(n, fold_string(runes))
		}
		return n
	case .Class:
		strs := class_strings(n.class)
		if len(strs) == 0 {
			return n
		}
		alt := either(n)
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
					seg := new_node(.Cat)
					append(&seg.kids, ..n.kids[i:i + w])
					one := new(Node)
					one.kind, one.r, one.fold = .Char, r, true
					append(&kids, either(seg, one))
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
	out := make([dynamic][]u32, context.temp_allocator)
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
either :: proc(kids: ..^Node) -> ^Node {
	n := new_node(.Alt)
	append(&n.kids, ..kids)
	return n
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
	if len(c.insts) >= MAX_INSTS {
		c.err = "fail to memory allocation"
		return len(c.insts)
	}
	append(&c.insts, Inst{op, i32(a), i32(b)})
	return len(c.insts) - 1
}

// A character a fold-insensitive comparison sees as only itself.
@(private)
literal :: proc(n: ^Node) -> bool {
	return n.kind == .Char && utf8.valid_rune(n.r) && (!n.fold || fold_next(n.r) == n.r)
}

@(private = "file")
emit_str :: proc(c: ^Compiler, runes: []^Node) {
	at := len(c.bytes)
	for n in runes {
		buf, w := utf8.encode_rune(n.r)
		append(&c.bytes, ..buf[:w])
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
	case .Char:
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
		jumps := make([dynamic]int, context.temp_allocator)
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
	case:
		add(c, .Save, 2 * g, int(c.referenced[g]))
		emit(c, n.kids[0])
		add(c, .Save, 2 * g + 1)
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
	saved, at := c.slots, c.slots + 1
	c.slots += 2
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
	if (x.kind == .Char || x.kind == .Any || x.kind == .Class) && n.max != n.min {
		add(c, .Rep if n.greedy else .Rep_Lazy, n.min, n.max)
		emit(c, x)
		return
	}
	if n.max >= 0 {
		emit_counted(c, n)
		return
	}
	for _ in 0 ..< n.min {
		emit(c, x)
		if c.err != "" {
			return
		}
	}
	// A body that can match empty is left once an iteration of it does, as Oniguruma's empty check
	// leaves it, so `(a*)*` ends.
	empty := can_be_empty(x)
	loop := add(c, .Split)
	mark := -1
	if empty {
		mark = c.slots
		c.slots += 1
		add(c, .Save, mark)
	}
	emit(c, x)
	check := add(c, .Check, mark) if empty else -1
	add(c, .Jmp, loop)
	exit := len(c.insts)
	patch(c, loop, loop + 1 if n.greedy else exit, exit if n.greedy else loop + 1)
	if empty {
		patch(c, check, mark, exit)
	} else if head, ok := head_byte(x); ok && n.greedy && n.min <= 1 {
		// Oniguruma's OP_PUSH_OR_JUMP_EXACT1: no alternative is kept for an iteration that cannot start,
		// which its retry limit counts.
		c.insts[loop] = {op = .Split_Head, a = i32(head), b = i32(exit)}
	}
}

// A repeat to a most count. Oniguruma's counted repeat leaves a body that can match empty once an iteration
// of it does, short of its least count too: `(|a){2}b` matches "ab" with the group empty after the a.
@(private = "file")
emit_counted :: proc(c: ^Compiler, n: ^Node) {
	x := n.kids[0]
	mark := -1
	if n.max > 1 && can_be_empty(x) {
		mark = c.slots
		c.slots += 1
	}
	splits := make([dynamic]int, context.temp_allocator)
	checks := make([dynamic]int, context.temp_allocator)
	start := len(c.insts)
	for i in 0 ..< n.max {
		// A call reuses the slots, so a counter is only kept where no group can be entered again.
		if i == 1 && c.addr == nil && (len(c.insts) - start) * n.max > COUNTED_WRITTEN_OUT {
			emit_counter_loop(c, x, max(n.min - 1, 0), n.max - 1, n.greedy, mark, &splits, &checks)
			break
		}
		if i >= n.min {
			append(&splits, add(c, .Split))
		}
		if mark >= 0 {
			add(c, .Save, mark)
		}
		emit(c, x)
		if c.err != "" {
			return
		}
		if mark >= 0 {
			append(&checks, add(c, .Check, mark))
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
		patch(c, k, mark, exit)
	}
}

// The most instructions a counted repeat is written out to. A longer one runs its body in a counter loop, as
// Oniguruma's OP_REPEAT does.
@(private = "file")
COUNTED_WRITTEN_OUT :: 1024

// `x` repeated `lo` to `hi` times by a counter, its Count appended to `exits` and its empty check to
// `checks`, which emit_counted points at the end.
@(private = "file")
emit_counter_loop :: proc(c: ^Compiler, x: ^Node, lo, hi: int, greedy: bool, mark: int, exits, checks: ^[dynamic]int) {
	slot := c.slots
	c.slots += 1
	add(c, .Count_Reset, slot)
	loop := add(c, .Count if greedy else .Count_Lazy, slot)
	add(c, .Count, lo, hi)
	append(exits, loop)
	if mark >= 0 {
		add(c, .Save, mark)
	}
	emit(c, x)
	if mark >= 0 {
		append(checks, add(c, .Check, mark))
	}
	add(c, .Count_Next, slot, loop)
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
	emit(c, body)
	end := add(c, .Look_End)
	patch(c, look, int(n.look), end)
}



class_match_slow :: proc(cls: ^Class, r: rune) -> bool {
	found := class_raw(cls, r)
	if !found && cls.fold {
		for x := fold_next(r); x != r; x = fold_next(x) {
			if class_raw(cls, x) {
				found = true
				break
			}
		}
	}
	return found != cls.negated
}

@(private = "file")
class_raw :: proc(cls: ^Class, r: rune) -> bool {
	for x in cls.ranges {
		if r >= x[0] && r <= x[1] {
			return true
		}
	}
	for it in cls.props {
		if in_table(int(it.table), r) != it.neg {
			return true
		}
	}
	return false
}
