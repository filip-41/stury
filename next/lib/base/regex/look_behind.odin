#+private
package regex

// Tunes a look-behind's body as Oniguruma's tune_look_behind does, and measures bodies: their fewest characters and
// their fixed length.

import "core:slice"
import "core:unicode/utf8"

// Returns a look-behind's body as Oniguruma's tune_look_behind leaves it, or an error message. It checks what the body
// holds, cuts the repeats that lead each alternative to their least count (alt_reduce_in_look_behind), and replaces by
// an empty node a body that Oniguruma is sure may match nothing and that holds no \K, no group that is read and no
// look-behind. The caller then requires the result to have a fixed length.
tune_behind :: proc(body: ^Node, negative: bool) -> (^Node, string) {
	keeps := false
	if !behind_allows(body, negative, &keeps) {
		return body, "invalid pattern in look-behind"
	}
	alt := body.kind == .Alt && !body.bag
	branches := make([dynamic]^Node, 0, len(body.kids))
	for k in (body.kids[:] if alt else []^Node{body}) {
		cut, ok := reduce_branch(k)
		if !ok {
			// Oniguruma returns the cut's "all removed" result as an error code.
			return body, "undefined error code"
		}
		append(&branches, cut)
	}
	out := branches[0]
	if alt {
		out = new(Node)
		out^ = body^
		out.kids = branches
	}
	// Oniguruma tunes the body before checking it, so a look-behind inside the body is measured here too, and one of no
	// fixed length fails.
	if least, sure := min_length(out); least == 0 && sure && !keeps && !holds_behind(out) {
		return new_node(.Empty), ""
	}
	return out, ""
}

@(private = "file")
holds_behind :: proc(n: ^Node) -> bool {
	if n.kind == .Look && (n.look == .Behind || n.look == .Not_Behind) {
		return true
	}
	for k in n.kids {
		if holds_behind(k) {
			return true
		}
	}
	return false
}

// Oniguruma's check_node_in_look_behind: no end-of-text anchor or look-ahead in either kind, no negative look-behind
// in a positive one, and no capture in a negative one. `keeps` is set when the body holds \K or a group that something
// reads (Oniguruma's `used`).
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
		if len(n.kids) < 2 { // a stopper changes where the text ends for what follows the look-behind
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

// Returns branch `n` with its leading repeats cut to their least count: a repeat with a minimum of 0 is dropped, and
// the first one with a larger minimum is kept at that count. Returns false when every element was cut. An option group
// `(?i:...)` is left whole.
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

// Whether `n` is a repeat that Oniguruma's cut applies to: not possessive, of a string (`(?:)` counts as an empty one),
// a class, `.` or a backreference.
@(private = "file")
reducible :: proc(n: ^Node) -> bool {
	if n.kind != .Repeat || n.possessive {
		return false
	}
	t := n.kids[0]
	#partial switch t.kind {
	case .Char, .Str, .Class, .Any, .Backref, .Empty:
		return !t.bag
	case .Cat:
		return !t.bag && is_string(t)
	}
	return false
}

@(private = "file")
is_string :: proc(n: ^Node) -> bool {
	for k in n.kids {
		if k.kind != .Char && k.kind != .Str {
			return false
		}
	}
	return true
}

// Whether Oniguruma's tune_next makes repeat `n` atomic before `next`, as it makes `a*b` into `(?>a*)b`. That is the
// case for a greedy unbounded repeat with a minimum of at most 1 of a string or class, when `next` cannot start with
// the first character of the repeated body.
@(private = "file")
made_atomic :: proc(n, next: ^Node) -> bool {
	if !n.greedy || n.max >= 0 || n.min > 1 {
		return false
	}
	t := n.kids[0]
	if t.kind != .Char && t.kind != .Str && t.kind != .Class && !(t.kind == .Cat && is_string(t)) {
		return false
	}
	x, y := head_literal(t), head_literal(next)
	return x != nil && y != nil && exclusive(x, y)
}

// Returns the character or class every match of `n` starts with, as Oniguruma's get_tree_head_literal finds it, or nil.
head_literal :: proc(n: ^Node) -> ^Node {
	#partial switch n.kind {
	case .Char, .Str, .Class:
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

// Oniguruma's is_exclusive on two characters or classes: whether no character starts both. Oniguruma compares strings
// as far as both go. This compares only the first characters.
@(private = "file")
exclusive :: proc(x, y: ^Node) -> bool {
	if folded_string(x) && folded_string(y) {
		// Found by testing against jq: `(?i)(?<=σ*s)` and `(?i)(?<=k*[st])` are taken, `(?i)(?<=σ*[tu])` and
		// `(?i)(?<=x*s)` are not.
		return false
	}
	if x.kind != .Class && y.kind != .Class { // a Str is compared by its first character
		return fold(x.r) != fold(y.r) if x.fold || y.fold else x.r != y.r
	}
	if x.kind != .Class || y.kind != .Class {
		ch, cl := x, y
		if y.kind != .Class {
			ch, cl = y, x
		}
		for r := ch.r; !class_match_slow(cl.class, r); {
			if r = fold_next(r) if ch.fold else r; r == ch.r {
				return true
			}
		}
		return false
	}
	a, b := x.class, y.class
	if word_type(a) && word_type(b) {
		// \w and \W are Oniguruma's word type, and the other escapes are classes. Two word types exclude each other
		// when exactly one is negated.
		return a.props[0].neg != b.props[0].neg
	}
	for r in rune(0) ..< 0x80 {
		if class_match_slow(a, r) && class_match_slow(b, r) {
			return false
		}
	}
	return ascii_only(a) || ascii_only(b)
}

// Whether `n` is a (?i) character, or a (?i) class with a range holding one, that has a case variant outside ASCII.
// Oniguruma's is_exclusive cannot tell two such apart: `(?i)(?<=σ*[st])` is taken, as ſ folds with s.
@(private = "file")
folded_string :: proc(n: ^Node) -> bool {
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

// Returns the fewest characters `n` matches, and whether Oniguruma is sure of it (node_char_len's min_is_sure). It is
// not sure when the fewest come through a capture, a backreference, an anchor or a look-around.
@(private = "file")
min_length :: proc(n: ^Node) -> (least: int, sure: bool) {
	#partial switch n.kind {
	case .Char, .Any, .Class, .Linebreak:
		return 1, true
	case .Str:
		return utf8.rune_count_in_string(n.text), true
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
		// A callout has length 0 and Oniguruma is sure of it. It is sure of no anchor's length.
		return 0, n.assert >= .Fail
	case .Cond:
		// Taken as an alternation. The yes branch follows the condition, so Oniguruma is not sure of its length.
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
			// Sure only when tune_behind reduces the body to Empty, which Oniguruma takes as always holding or failing.
			body, err := tune_behind(n.kids[0], n.look == .Not_Behind)
			return 0, err == "" && body.kind == .Empty
		}
		return 0, false
	case .Call:
		return 0, false
	case .Absent:
		// Oniguruma finds the absent with a repeat of exp's single character when exp is one, or of any. That repeat
		// may stop at once, so the fewest is 0 for a stopper and for such an exp. Otherwise it is exp's fewest.
		if len(n.kids) < 2 || simple_repeat_exp(n.kids[1]) {
			return 0, true
		}
		return min_length(n.kids[1])
	}
	return 0, true
}

// Oniguruma's is_simple_one_char_repeat: whether `n` is a greedy repeat, possessive or not, of one character or class
// (\w and `.` are types, not classes).
@(private = "file")
simple_repeat_exp :: proc(n: ^Node) -> bool {
	if n.kind != .Repeat || !n.greedy || n.bag {
		return false
	}
	x := n.kids[0]
	return !x.bag && (x.kind == .Char || x.kind == .Class && !word_type(x.class))
}

// Returns the number of runes `n` always matches, as a look-behind needs it, and whether that is fixed. A group that a
// backreference names is only measured (`referred`), as Oniguruma's node_char_len measures it. There an end anchor or
// look-ahead has length 0, because check_node_in_look_behind refuses them only in the look-behind's own body. A (?i)
// character in a group past the look-behind is refused when tune_tree has not yet unravelled it (`untuned`), as
// node_char_len refuses it.
fixed_length :: proc(c: ^Compiler, n: ^Node, referred := false, untuned := false) -> (int, bool) {
	switch n.kind {
	case .Empty, .Keep:
		return 0, true
	case .Char:
		return 1, !(untuned && n.fold)
	case .Str:
		return utf8.rune_count_in_string(n.text), true
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
		// Oniguruma measures a repeat from its least to its most count, so it has a fixed length only when they are
		// equal or the body has length 0. A repeat with no maximum has none, whatever its body.
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
				// Oniguruma takes a backreference inside its own group as matching nothing. This also ends the
				// measuring of a group that refers to itself.
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
			return 0, false // a call inside its own group: Oniguruma measures it as unbounded
		}
		return fixed_length(c, n.target, referred, untuned || g > c.tuned)
	case .Linebreak, .Grapheme, .Absent:
	}
	return 0, false
}
