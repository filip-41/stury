package regex

// A pattern's tree as a program for the backtracking matcher (match.odin), with what the search can skip
// by: a literal every match starts with, one every match holds, a start pinned to \A.

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// The most instructions a program may have: short counted repeats are written out, so many of them would
// otherwise take any memory they like. Oniguruma has no such limit.
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

@(private = "file")
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

// The called groups no call has emitted in place, as a group under `{0}` is, each after the program, then each call's
// address.
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
@(private = "file")
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

// A look-behind's body as Oniguruma's tune_look_behind leaves it, or its message. It checks what the body
// holds, cuts the repeats that lead each alternative to their least count (alt_reduce_in_look_behind), and
// takes a body Oniguruma is sure may then match nothing, and with no \K, as empty. What is left must be of fixed
// length.
@(private = "file")
tune_behind :: proc(body: ^Node, negative: bool) -> (^Node, string) {
	keeps := false
	if !behind_allows(body, negative, &keeps) {
		return body, "invalid pattern in look-behind"
	}
	out := body
	if body.kind == .Alt && !body.bag {
		out = new(Node)
		out^ = body^
		out.kids = make([dynamic]^Node, len(body.kids))
		for k, i in body.kids {
			ok: bool
			out.kids[i], ok = reduce_branch(k)
			if !ok {
				// Oniguruma returns its cut's "all removed" as though it were an error code.
				return body, "undefined error code"
			}
		}
	} else {
		ok: bool
		out, ok = reduce_branch(body)
		if !ok {
			return body, "undefined error code"
		}
	}
	if least, sure := min_length(out); least == 0 && sure && !keeps {
		return new_node(.Empty), ""
	}
	return out, ""
}

// Oniguruma's check_node_in_look_behind: no end of text, look-ahead, or negative look-behind in a positive
// look-behind, and no capture in a negative one. `keeps` is set when it holds \K or a group something reads
// (Oniguruma's `used`).
@(private = "file")
behind_allows :: proc(n: ^Node, negative: bool, keeps: ^bool) -> bool {
	#partial switch n.kind {
	case .Keep:
		keeps^ = true
	case .Group:
		if negative {
			return false
		}
		keeps^ ||= n.used
	case .Assert:
		return n.assert != .End_Buf && n.assert != .Semi_End_Buf
	case .Look:
		if n.look == .Ahead || n.look == .Not_Ahead || (n.look == .Not_Behind && !negative) {
			return false
		}
	case .Absent:
		if len(n.kids) < 2 { // a stopper changes what follows the look-behind
			return false
		}
	}
	for k in n.kids {
		if !behind_allows(k, negative, keeps) {
			return false
		}
	}
	return true
}

// A branch with its leading repeats cut while each cut leaves nothing. It returns false when every element was cut.
// An option group `(?i:...)` is left whole.
@(private = "file")
reduce_branch :: proc(n: ^Node) -> (^Node, bool) {
	if n.bag {
		return n, true
	}
	if n.kind == .Repeat {
		return least_count(n) if reducible(n) else n, true
	}
	if n.kind != .Cat {
		return n, true
	}
	i := 0
	lead: ^Node
	for ; i < len(n.kids); i += 1 {
		k := n.kids[i]
		if !reducible(k) || (i + 1 < len(n.kids) && made_atomic(k, n.kids[i + 1])) {
			break
		}
		if k.min > 0 {
			lead = least_count(k)
			i += 1
			break
		}
	}
	if i == len(n.kids) && lead == nil {
		return n, false
	}
	if i == 0 {
		return n, true
	}
	cat := new(Node)
	cat^ = n^
	cat.kids = make([dynamic]^Node, 0, len(n.kids) - i + 1)
	if lead != nil {
		append(&cat.kids, lead)
	}
	append(&cat.kids, ..n.kids[i:])
	return cat, true
}

// A repeat Oniguruma's cut takes: of a string (`(?:)` is an empty one), a class, `.` or a backreference, and
// not possessive.
@(private = "file")
reducible :: proc(n: ^Node) -> bool {
	if n.kind != .Repeat || n.possessive {
		return false
	}
	t := n.kids[0]
	#partial switch t.kind {
	case .Char, .Class, .Any, .Backref, .Empty:
		return !t.bag
	case .Cat:
		return !t.bag && is_string(t)
	}
	return false
}

@(private = "file")
is_string :: proc(n: ^Node) -> bool {
	for k in n.kids {
		if k.kind != .Char {
			return false
		}
	}
	return true
}

// Whether Oniguruma's tune_next makes repeat `n` atomic before `next`, as it makes `a*b` `(?>a*)b`: a greedy
// unbounded repeat from at most one of a string or class whose first character `next` cannot start with.
@(private = "file")
made_atomic :: proc(n, next: ^Node) -> bool {
	if !n.greedy || n.max >= 0 || n.min > 1 {
		return false
	}
	t := n.kids[0]
	if t.kind != .Char && t.kind != .Class && !(t.kind == .Cat && is_string(t)) {
		return false
	}
	x, y := head_literal(t), head_literal(next)
	return x != nil && y != nil && exclusive(x, y)
}

// The first byte of the character every match of `n` starts with, when Oniguruma's get_tree_head_literal finds
// one exactly (no class, no case folding).
@(private = "file")
head_byte :: proc(n: ^Node) -> (byte, bool) {
	h := head_literal(n)
	if h == nil || h.kind != .Char || h.fold || !utf8.valid_rune(h.r) {
		return 0, false
	}
	b, _ := utf8.encode_rune(h.r)
	return b[0], true
}

// The character or class every match of `n` starts with, as Oniguruma's get_tree_head_literal finds it.
@(private = "file")
head_literal :: proc(n: ^Node) -> ^Node {
	#partial switch n.kind {
	case .Char, .Class:
		return n
	case .Cat:
		return head_literal(n.kids[0]) if len(n.kids) > 0 else nil
	case .Repeat:
		return head_literal(n.kids[0]) if n.min > 0 else nil
	case .Group:
		return head_literal(n.kids[0])
	case .Look:
		return head_literal(n.kids[0]) if n.look == .Ahead || n.look == .Atomic else nil
	}
	return nil
}

// Oniguruma's is_exclusive on two characters or classes: no character starts both. Oniguruma compares strings as far
// as both go. This compares the first characters only.
@(private = "file")
exclusive :: proc(x, y: ^Node) -> bool {
	if folded_string(x) && folded_string(y) {
		return false // as found against jq: `(?i)(?<=σ*s)` and `(?i)(?<=k*[st])` are taken, `(?i)(?<=σ*[tu])` and `(?i)(?<=x*s)` are not
	}
	if x.kind == .Char && y.kind == .Char {
		return fold(x.r) != fold(y.r) if x.fold || y.fold else x.r != y.r
	}
	if x.kind == .Char || y.kind == .Char {
		ch, cl := x, y
		if y.kind == .Char {
			ch, cl = y, x
		}
		if class_match_slow(cl.class, ch.r) {
			return false
		}
		if ch.fold {
			for r := fold_next(ch.r); r != ch.r; r = fold_next(r) {
				if class_match_slow(cl.class, r) {
					return false
				}
			}
		}
		return true
	}
	a, b := x.class, y.class
	if word_type(a) && word_type(b) {
		// \w and \W are Oniguruma's one character type. The other escapes are classes.
		return a.props[0].neg != b.props[0].neg
	}
	for r in rune(0) ..< 0x80 {
		if class_match_slow(a, r) && class_match_slow(b, r) {
			return false
		}
	}
	return ascii_only(a) || ascii_only(b)
}

// Whether `n` is a (?i) character, or a class holding one, with a case variant outside ASCII, which
// Oniguruma's is_exclusive does not tell from another such: `(?i)(?<=σ*[st])` is taken, as ſ folds with s.
@(private = "file")
folded_string :: proc(n: ^Node) -> bool {
	folds_outside :: proc(r: rune) -> bool {
		outside := r >= 0x80
		for f := fold_next(r); f != r; f = fold_next(f) {
			outside ||= f >= 0x80
		}
		return outside && fold_next(r) != r
	}
	if n.kind == .Char && n.fold {
		return folds_outside(n.r)
	}
	if n.kind != .Class || !n.class.fold || n.class.negated || len(n.class.props) > 0 {
		return false
	}
	for x in n.class.ranges {
		for r in x[0] ..= x[1] {
			if folds_outside(r) {
				return true
			}
		}
	}
	return false
}

word_type :: proc(cls: ^Class) -> bool {
	return !cls.negated && len(cls.ranges) == 0 && len(cls.props) == 1 && cls.props[0].table == TABLE_WORD
}

@(private = "file")
ascii_only :: proc(cls: ^Class) -> bool {
	if cls.negated || len(cls.props) > 0 {
		return false
	}
	for x in cls.ranges {
		if x[1] >= 0x80 {
			return false
		}
	}
	return true
}

@(private = "file")
least_count :: proc(n: ^Node) -> ^Node {
	cut := new(Node)
	if n.min == 0 {
		cut.kind = .Empty
		return cut
	}
	cut^ = n^
	cut.max = cut.min
	return cut
}

// The fewest characters `n` matches, and whether Oniguruma is sure of it (node_char_len's min_is_sure): it is
// not when the fewest come through a capture, a backreference, an anchor or a look-around.
@(private = "file")
min_length :: proc(n: ^Node) -> (least: int, sure: bool) {
	#partial switch n.kind {
	case .Char, .Any, .Class, .Linebreak:
		return 1, true
	case .Grapheme:
		return 1, false // Oniguruma's \X is a tree with look-arounds, so `(?<=\X*)` is not taken as empty
	case .Cat:
		sure = true
		for k in n.kids {
			l, s := min_length(k)
			least += l
			sure &&= s
		}
		return
	case .Alt:
		least = -1
		for k in n.kids {
			l, s := min_length(k)
			if least < 0 || l < least {
				least, sure = l, s
			} else if l == least {
				sure ||= s
			}
		}
		return
	case .Group:
		least, _ = min_length(n.kids[0])
		return least, false
	case .Backref, .Keep:
		return 0, false
	case .Assert:
		// Oniguruma is sure of a callout's length, as of nothing, and of no anchor's.
		return 0, n.assert >= .Fail
	case .Cond:
		// As an alternation, but the yes branch follows the condition, which Oniguruma is not sure of.
		yes, _ := min_length(n.kids[0])
		no, no_sure := min_length(n.kids[1])
		if yes < no {
			return yes, false
		}
		return no, no_sure
	case .Repeat:
		if n.max == 0 {
			return 0, true
		}
		least, sure = min_length(n.kids[0])
		return n.min * least, sure
	case .Look:
		#partial switch n.look {
		case .Atomic:
			return min_length(n.kids[0])
		case .Behind, .Not_Behind:
			// A look-behind Oniguruma has already taken as always holding or always failing.
			body, err := tune_behind(n.kids[0], n.look == .Not_Behind)
			return 0, err == "" && body.kind == .Empty
		}
		return 0, false
	case .Call:
		return 0, false
	case .Absent:
		// Oniguruma's absent looks for the absent with a repeat of exp's one character when exp is one, or of any,
		// which may stop at once, and when it may, the absent's fewest is none.
		if len(n.kids) < 2 || simple_repeat_exp(n.kids[1]) {
			return 0, true
		}
		return min_length(n.kids[1])
	}
	return 0, true
}

// Oniguruma's is_simple_one_char_repeat: a greedy repeat, possessive or not, of one character or class (\w and
// `.` are types, not classes).
@(private = "file")
simple_repeat_exp :: proc(n: ^Node) -> bool {
	if n.kind != .Repeat || !n.greedy || n.bag {
		return false
	}
	x := n.kids[0]
	return !x.bag && (x.kind == .Char || x.kind == .Class && !word_type(x.class))
}

// The runes `n` always matches, as a look-behind needs it. A group a backreference names is only measured
// (`referred`), as Oniguruma's node_char_len measures it, where its anchors and look-aheads match nothing,
// check_node_in_look_behind refuses them only in the look-behind's own body. node_char_len refuses a string under
// (?i) that tune_tree has not yet unravelled, in a group past the look-behind (`untuned`).
@(private = "file")
fixed_length :: proc(c: ^Compiler, n: ^Node, referred := false, untuned := false) -> (int, bool) {
	switch n.kind {
	case .Empty, .Keep:
		return 0, true
	case .Char:
		return 1, !(untuned && n.fold)
	case .Any, .Class:
		return 1, true
	case .Cat:
		sum := 0
		for k in n.kids {
			l, ok := fixed_length(c, k, referred, untuned)
			if !ok {
				return 0, false
			}
			sum += l
		}
		return sum, true
	case .Alt, .Cond:
		first := -1
		for k in n.kids {
			l, ok := fixed_length(c, k, referred, untuned)
			if !ok || (first >= 0 && l != first) {
				return 0, false
			}
			first = l
		}
		return first, true
	case .Group:
		append(&c.open, n.group)
		defer pop(&c.open)
		return fixed_length(c, n.kids[0], referred, untuned)
	case .Repeat:
		// Oniguruma measures a repeat from its least to its most count, of no one length unless they agree, and
		// one with no most count, whatever its body, of none.
		if n.max == 0 {
			return 0, true
		}
		l, ok := fixed_length(c, n.kids[0], referred, untuned)
		return l * n.min, ok && n.max > 0 && (l == 0 || n.min == n.max)
	case .Assert:
		#partial switch n.assert {
		case .End_Buf, .Semi_End_Buf:
			return 0, referred
		}
		return 0, true
	case .Look:
		switch n.look {
		case .Ahead, .Not_Ahead:
			return 0, referred
		case .Behind, .Not_Behind:
			return 0, true
		case .Atomic:
			return fixed_length(c, n.kids[0], referred, untuned)
		}
	case .Backref:
		for g in n.refs {
			if slice.contains(c.open[:], g) {
				// Oniguruma takes a backreference inside its group as matching nothing, which also ends the
				// measure of a group that refers to itself.
				return 0, true
			}
		}
		first := -1
		for g in n.refs {
			l, ok := fixed_length(c, c.groups[g], true, untuned || g > c.tuned)
			if !ok || (first >= 0 && l != first) {
				return 0, false
			}
			first = l
		}
		return first, true
	case .Call:
		g := n.target.group
		if slice.contains(c.open[:], g) {
			return 0, false // a call within its own group: Oniguruma measures it as of no bound
		}
		return fixed_length(c, n.target, referred, untuned || g > c.tuned)
	case .Linebreak, .Grapheme, .Absent:
	}
	return 0, false
}

// The greatest group number in `n`, 0 for none.
@(private = "file")
last_group :: proc(n: ^Node) -> int {
	last := n.group if n.kind == .Group else 0
	for k in n.kids {
		last = max(last, last_group(k))
	}
	return last
}

// Adds to `set` every byte a match of `n` can start with, `ok` is false when that is not known, and `empty` is true
// when `n` can match without a byte, so what follows it starts the match too. With `like_onig`, a class or (?i) rune
// that may match a non-ASCII rune is not known.
@(private = "file")
first_bytes :: proc(n: ^Node, set: ^[4]u64, like_onig: bool) -> (empty: bool, ok: bool) {
	add_byte :: proc(set: ^[4]u64, b: byte) {
		set[b >> 6] |= 1 << (u64(b) & 63)
	}
	add_rune :: proc(set: ^[4]u64, r: rune) {
		if !utf8.valid_rune(r) {
			return
		}
		buf, _ := utf8.encode_rune(r)
		add_byte(set, buf[0])
		if r >= 0x80 && r < 0xC0 { // what a search started inside a character reads as r
			add_byte(set, byte(r))
		}
	}
	switch n.kind {
	case .Empty, .Assert, .Keep:
		return true, true
	case .Char:
		add_rune(set, n.r)
		if n.fold {
			for x := fold_next(n.r); x != n.r; x = fold_next(x) {
				if like_onig && (x >= 0x80 || n.r >= 0x80) {
					return false, false
				}
				add_rune(set, x)
			}
		}
		return false, true
	case .Any:
		for b in 0 ..< 256 {
			if b != '\n' || n.dotall {
				add_byte(set, byte(b))
			}
		}
		return false, true
	case .Class:
		set[0] |= n.class.ascii[0] // filled when the class was emitted
		set[1] |= n.class.ascii[1]
		if !ascii_only(n.class) || folds_out_of_ascii(n.class) {
			if like_onig {
				return false, false
			}
			set[2], set[3] = max(u64), max(u64)
		}
		return false, true
	case .Linebreak:
		if like_onig {
			return false, false
		}
		for b in ([]byte{'\n', '\v', '\f', '\r', 0xC2, 0xE2}) {
			add_byte(set, b)
		}
		return false, true
	case .Cat:
		for k in n.kids {
			empty, ok = first_bytes(k, set, like_onig)
			if !ok || !empty {
				return
			}
		}
		return true, true
	case .Alt:
		for k in n.kids {
			e, o := first_bytes(k, set, like_onig)
			if !o {
				return false, false
			}
			empty ||= e
		}
		return empty, true
	case .Group:
		return first_bytes(n.kids[0], set, like_onig)
	case .Repeat:
		empty, ok = first_bytes(n.kids[0], set, like_onig)
		return empty || n.min == 0, ok
	case .Look:
		if n.look == .Atomic {
			return first_bytes(n.kids[0], set, like_onig)
		}
		if n.look == .Ahead {
			if e, o := first_bytes(n.kids[0], set, like_onig); o && !e {
				return false, true // the match starts where the look-ahead's does
			}
		}
		return true, true // takes no bytes, so what follows starts the match
	case .Backref, .Cond, .Grapheme, .Call, .Absent:
	}
	return false, false
}

// Whether (?i) takes a rune of `cls` to a non-ASCII one, as k to the Kelvin sign and s to the long s.
@(private = "file")
folds_out_of_ascii :: proc(cls: ^Class) -> bool {
	for x in cls.ranges {
		for r in x[0] ..= min(x[1], 0x7F) {
			for f := fold_next(r); cls.fold && f != r; f = fold_next(f) {
				if f >= 0x80 {
					return true
				}
			}
		}
	}
	return false
}

@(private = "file")
starts_at_buffer :: proc(n: ^Node) -> bool {
	#partial switch n.kind {
	case .Assert:
		return n.assert == .Begin_Buf
	case .Cat, .Group:
		return len(n.kids) > 0 && starts_at_buffer(n.kids[0])
	}
	return false
}

// The literal every match of `n` starts with, appended to `out`. Whether `n` is wholly that literal.
@(private = "file")
literal_prefix :: proc(n: ^Node, out: ^[dynamic]byte) -> bool {
	#partial switch n.kind {
	case .Char:
		if !literal(n) {
			return false
		}
		buf, w := utf8.encode_rune(n.r)
		append(out, ..buf[:w])
		return true
	case .Cat:
		for k in n.kids {
			if !literal_prefix(k, out) {
				return false
			}
		}
		return true
	case .Group:
		return literal_prefix(n.kids[0], out)
	}
	return false
}

// A run of literal runes every match holds: the longest, the earliest of equals, as Oniguruma's optimizer
// picks the text it searches for first. Which one it picks decides whether a hopeless search fails at
// once or backtracks into the retry limit.
@(private = "file")
required_literal :: proc(n: ^Node) -> string {
	#partial switch n.kind {
	case .Char:
		if literal(n) {
			buf, w := utf8.encode_rune(n.r)
			return strings.clone(string(buf[:w]))
		}
	case .Group:
		return required_literal(n.kids[0])
	case .Alt:
		// What every alternative's literal starts with, as Oniguruma merges its alternatives' literals.
		common := required_literal(n.kids[0])
		for k in n.kids[1:] {
			lit := required_literal(k)
			i := 0
			for i < min(len(common), len(lit)) && common[i] == lit[i] {
				i += 1
			}
			common = common[:i]
		}
		return common
	case .Repeat:
		if n.min >= 1 {
			return required_literal(n.kids[0])
		}
	case .Look:
		if n.look == .Atomic {
			return required_literal(n.kids[0])
		}
	case .Cat:
		// The run ended: kept if longer, and emptied.
		ended :: proc(best: string, run: ^strings.Builder) -> string {
			defer strings.builder_reset(run)
			return strings.clone(strings.to_string(run^)) if strings.builder_len(run^) > len(best) else best
		}
		best, run := "", strings.builder_make(context.temp_allocator)
		for k in n.kids {
			if literal(k) {
				strings.write_rune(&run, k.r)
				continue
			}
			best = ended(best, &run)
			if inner := required_literal(k); len(inner) > len(best) {
				best = inner
			}
		}
		return ended(best, &run)
	}
	return ""
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
