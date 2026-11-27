#+private
package regex

// Lowers a pattern's tree into the bytecode program compiled by compile.odin.

import "core:slice"
import "core:unicode/utf8"

// Emits each called group that no call has emitted in place (as a group under `{0}` is) after the program, then sets
// each call's address.
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
	if at >= MAX_BYTES {
		c.err = MEMORY_ERROR
		return
	}
	for n in run {
		buf: [4]byte
		append(&c.bytes, literal_text(n, &buf))
	}
	add(c, .Str, at, len(c.bytes) - at)
}

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
		chain := -1
		for kid, k in n.kids {
			if k == len(n.kids) - 1 {
				emit(c, kid)
				break
			}
			split := add(c, .Split)
			emit(c, kid)
			chain = add(c, .Jmp, chain)
			patch(c, split, split + 1, len(c.insts))
		}
		for chain >= 0 && chain < len(c.insts) {
			next := int(c.insts[chain].a)
			patch(c, chain, len(c.insts))
			chain = next
		}
	case .Group:
		g := n.group
		c.tuned = max(c.tuned, g)
		if c.called == nil || !c.called[g] {
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
	case c.recursive != nil && c.recursive[g]:
		add(c, .Mem_Start, g)
		emit(c, n.kids[0])
		add(c, .Mem_End, g)
	case c.leftwards: // its end is reached first, while its start is still unset
		add(c, .Save, 2 * g + 1)
		emit(c, n.kids[0])
		add(c, .Save, 2 * g)
	case c.undone == nil || c.undone[g]:
		add(c, .Save, 2 * g, int(c.referenced[g]))
		emit(c, n.kids[0])
		add(c, .Save, 2 * g + 1)
	case:
		add(c, .Set, 2 * g)
		emit(c, n.kids[0])
		add(c, .Set, 2 * g + 1)
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
	if n.max == 0 {
		return
	}
	if n.possessive {
		look := add(c, .Look, int(Look_Kind.Atomic))
		n.possessive = false
		emit_repeat(c, n)
		n.possessive = true
		patch(c, look, int(Look_Kind.Atomic), add(c, .Look_End))
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
	if enter < 0 && n.min > 1 && c.ecma && slice.contains(c.looped[:], n) {
		emit_counter_loop(c, x, n.min, n.min, true, -1)
	} else {
		for i in 0 ..< (n.min if enter < 0 else 0) {
			at := emitted(c)
			emit_body(c, x, -1)
			if c.err != "" {
				return
			}
			if i == 0 && n.min > 1 && c.ecma && i64(len(c.insts) - at.insts) * i64(n.min) > ECMA_WRITTEN_OUT {
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
	   loop < len(c.insts) &&
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
	if c.ecma && n.max > 1 && slice.contains(c.looped[:], n) {
		emit_counter_loop(c, x, n.min, n.max, n.greedy, mark)
		return
	}
	splits, checks := -1, -1
	start := len(c.insts)
	at := emitted(c)
	for i in 0 ..< n.max {
		// Under ECMA a repeat written out past ECMA_WRITTEN_OUT runs as a counter loop instead, whose single body
		// applies the empty-iteration rule by its count.
		if i == 1 && c.ecma && i64(len(c.insts) - start) * i64(n.max) > ECMA_WRITTEN_OUT {
			spill_to_counter_loop(c, at, n, n.min, n.max, n.greedy, mark)
			return
		}
		// Calls enter groups again and reuse the slots, so this counter loop is used only in a pattern without calls.
		if i == 1 && c.addr == nil && !c.ecma && i64(len(c.insts) - start) * i64(n.max) > COUNTED_WRITTEN_OUT {
			emit_counter_loop(c, x, max(n.min - 1, 0), n.max - 1, n.greedy, mark)
			break
		}
		if i >= n.min {
			splits = add(c, .Split, splits)
		}
		if k := emit_body(c, x, -1 if c.ecma && i < n.min else mark); k >= 0 && k < len(c.insts) {
			c.insts[k].b = i32(checks)
			checks = k
		}
		if c.err != "" {
			return
		}
	}
	if c.err != "" || gate_failed(context.allocator) {
		return
	}
	exit := len(c.insts)
	for s := splits; s >= 0 && s < len(c.insts); {
		next := int(c.insts[s].a)
		patch(c, s, s + 1 if n.greedy else exit, exit if n.greedy else s + 1)
		s = next
	}
	for k := checks; k >= 0 && k < len(c.insts); {
		next := int(c.insts[k].b)
		patch(c, k, mark, -1 if c.ecma else exit)
		k = next
	}
}

// Emits a loop's body. With `mark` set it saves the mark before the body and adds a check after it that leaves the loop
// once an iteration matched empty. With `mark` -1 it adds neither. Under ECMA an iteration starts with its groups
// unset. Returns the check's instruction index, or -1.
@(private = "file")
emit_body :: proc(c: ^Compiler, x: ^Node, mark: int) -> int {
	if c.ecma {
		if lo, hi := group_range(x); hi > 0 {
			add(c, .Unset, 2 * lo, 2 * hi + 2)
		}
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

// The length of each of the compiler's lists at one point, for `spill_to_counter_loop`.
@(private = "file")
Emitted :: struct {
	insts, bytes, classes, refs, loops, counters: int,
}

@(private = "file")
emitted :: proc(c: ^Compiler) -> Emitted {
	return {len(c.insts), len(c.bytes), len(c.classes), len(c.refs), len(c.loops), len(c.counters)}
}

// Drops what was emitted since `at` (its slots stay allocated and unread) and emits the repeat `n` as a counter loop,
// which `c.looped` records.
@(private = "file")
spill_to_counter_loop :: proc(c: ^Compiler, at: Emitted, n: ^Node, least, most: int, greedy: bool, mark: int) {
	resize(&c.insts, at.insts)
	resize(&c.loop_of, at.insts)
	resize(&c.counter_of, at.insts)
	resize(&c.bytes, at.bytes)
	resize(&c.classes, at.classes)
	resize(&c.refs, at.refs)
	resize(&c.loops, at.loops)
	resize(&c.counters, at.counters)
	append(&c.looped, n)
	emit_counter_loop(c, n.kids[0], least, most, greedy, mark)
}

// Emits a repeat of `x` from `least` to `most` times as one body in a loop whose count is kept in a slot of its own.
// With a `mark`, under ECMA an iteration past the least count that matches empty fails while one short of it continues;
// under Oniguruma an empty iteration leaves the loop.
@(private = "file")
emit_counter_loop :: proc(c: ^Compiler, x: ^Node, least, most: int, greedy: bool, mark: int) {
	slot := new_slot(c)
	add(c, .Count_Reset, slot)
	outer := c.counter
	if c.ecma {
		append(&c.counters, Counter{slot, least, most, outer})
		c.counter = len(c.counters) - 1
	}
	loop := add(c, .Count if greedy else .Count_Lazy, slot)
	add(c, .Count, least, most)
	check := emit_body(c, x, mark)
	add(c, .Count_Next, slot, loop)
	c.counter = outer
	exit := len(c.insts)
	patch(c, loop, slot, exit)
	if check >= 0 && check < len(c.insts) {
		if c.ecma {
			c.insts[check] = {.Count_Check, i32(mark), i32(loop)}
		} else {
			patch(c, check, mark, exit)
		}
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
		_, hi := group_range(body)
		c.tuned = max(c.tuned, hi) // tune_look_behind tunes its body before it measures it
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
	if c.ecma && (n.look == .Ahead || n.look == .Behind) {
		if lo, hi := group_range(body); hi > 0 {
			add(c, .Unset, 2 * lo, 2 * hi + 2)
		}
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

// The least and greatest group numbers in `n`, both 0 for none.
@(private = "file")
group_range :: proc(n: ^Node) -> (first, last: int) {
	if n.kind == .Group && n.group > 0 {
		first, last = n.group, n.group
	}
	for k in n.kids {
		lo, hi := group_range(k)
		if hi > 0 {
			first = lo if first == 0 else min(first, lo)
			last = max(last, hi)
		}
	}
	return
}
