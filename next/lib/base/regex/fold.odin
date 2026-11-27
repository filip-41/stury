#+private
package regex

// Simple case folding, and the multi-character folds that a (?i) character or class also matches.

import "core:slice"

// The rune `r`'s case-fold class as one rune, so two runes fold alike when their classes are the same rune.
fold :: proc(r: rune) -> rune {
	if r < 0x80 {
		return r + 32 if r >= 'A' && r <= 'Z' else r
	}
	f, ok := fold_entry(r)
	return rune(f & (1 << FOLD_BITS - 1)) if ok else r
}

// The next rune of those `r` folds alike with, cycling back to `r` after the last. Returns `r` when it folds alone.
fold_next :: proc(r: rune) -> rune {
	f, ok := fold_entry(r)
	return rune(f >> FOLD_BITS & (1 << FOLD_BITS - 1)) if ok else r
}

// The two or three runes, folded, that (?i) matches `r` to besides those it folds alike with.
multi_fold :: proc(r: rune) -> (runes: []u32, ok: bool) {
	k := slice.binary_search_by(MULTI_FOLDS[:], u32(r), proc(f: [4]u32, c: u32) -> slice.Ordering {
		return slice.cmp(f[0], c)
	}) or_return
	return MULTI_FOLDS[k][1:3 if MULTI_FOLDS[k][3] == 0 else 4], true
}

// Returns the rune whose `multi_fold` is the fold of each of `runes` (two or three), or false when there is none.
@(private = "file")
unfold :: proc(runes: []rune) -> (r: rune, ok: bool) {
	next: for &f in MULTI_FOLDS {
		if len(runes) != (2 if f[3] == 0 else 3) {
			continue
		}
		for x, i in runes {
			if fold(x) != rune(f[i + 1]) {
				continue next
			}
		}
		return rune(f[0]), true
	}
	return 0, false
}

@(private = "file")
fold_entry :: proc(r: rune) -> (f: u64, ok: bool) {
	k := slice.binary_search_by(FOLDS, u64(u32(r)), fold_order) or_return
	return FOLDS[k], true
}

// Orders an entry of FOLDS against a character by the character it holds.
fold_order :: proc(f: u64, c: u64) -> slice.Ordering {
	return slice.cmp(f >> (2 * FOLD_BITS), c)
}

// Whether `r` folds alike with other runes and `r` or one of them is 0x80 or above.
folds_outside :: proc(r: rune) -> bool {
	for f := fold_next(r); f != r; f = fold_next(f) {
		if r >= 0x80 || f >= 0x80 {
			return true
		}
	}
	return false
}

// Oniguruma's multi-character case folds (expand_case_fold_string, and a class's strings): under (?i) a character
// that folds to two or three (ß to ss) also matches them. Two or three characters of a run that fold to those (ss)
// also match the one character, three tried before two and the run going on past them, and a class not negated
// matches, after its one character, the strings its characters fold to. In a look-behind's body only the classes have
// them, as Oniguruma's parser gives them.
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
		if !n.class.fold || n.class.negated {
			return n
		}
		alt: ^Node
		seen: [dynamic][]u32
		next: for &f in MULTI_FOLDS {
			if !class_match_slow(n.class, rune(f[0])) {
				continue
			}
			s := f[1:3 if f[3] == 0 else 4]
			for t in seen {
				if slice.equal(s, t) {
					continue next
				}
			}
			append(&seen, s)
			if alt == nil {
				alt = new_node(.Alt, n)
			}
			append(&alt.kids, fold_string(s))
		}
		return alt if alt != nil else n
	case .Cat:
		if behind {
			break
		}
		w := 0
		for i := 0; i < len(n.kids); {
			run := 0
			for i + run < len(n.kids) && run < 3 && n.kids[i + run].kind == .Char && n.kids[i + run].fold {
				run += 1
			}
			width := 1
			for k := run; k >= 2 && width == 1; k -= 1 {
				runes: [3]rune
				for j in 0 ..< k {
					runes[j] = n.kids[i + j].r
				}
				if r, ok := unfold(runes[:k]); ok {
					one := new_node(.Char)
					one.r, one.fold = r, true
					n.kids[w] = new_node(.Alt, new_node(.Cat, ..n.kids[i:i + k]), one)
					width = k
				}
			}
			if width == 1 {
				n.kids[w] = expand_folds(n.kids[i])
			}
			w, i = w + 1, i + width
		}
		resize(&n.kids, w)
		return n
	}
	for &k in n.kids {
		k = expand_folds(k, behind)
	}
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
