package regex

// What the compiler learns of a tree besides its program: a look-behind's body tuned to a fixed
// length, and the bytes a match can start with or must hold, for the search to skip by.

import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// A look-behind's body as Oniguruma's tune_look_behind leaves it, or its message. It checks what the body
// holds, cuts the repeats that lead each alternative to their least count (alt_reduce_in_look_behind), and
// takes a body Oniguruma is sure may then match nothing, and with no \K, as empty. What is left must be of fixed
// length.
@(private)
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
@(private)
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
@(private)
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
@(private)
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
@(private)
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

@(private)
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
@(private)
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
@(private)
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
