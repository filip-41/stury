package regex

// Oniguruma's Unicode character types under UTF-8, `\w`, `\d`, `\s`, the POSIX brackets and `\p{...}`, from
// its own tables, and its simple case folding (unicode_tables.odin).

import "core:slice"
import "core:strings"
import "core:sync"
import "core:unicode"

@(private = "file")
decoded: sync.Once

// Fills PROPERTY_RANGES and FOLDS from their deltas (unicode_tables.py), once, before any table is read.
decode_tables :: proc() {
	sync.once_do(&decoded, proc() {
		next :: #force_inline proc(b: ^[^]byte) -> (n: u32) {
			for shift: u32 = 0;; shift += 7 {
				x := b[0]
				b^ = b[1:]
				n |= u32(x & 0x7F) << shift
				if x < 0x80 {
					return
				}
			}
		}
		b := raw_data(RANGE_DELTAS)
		for t in 0 ..< len(PROPERTY_TABLES) - 1 {
			last: u32
			for &r in PROPERTY_RANGES[PROPERTY_TABLES[t]:PROPERTY_TABLES[t + 1]] {
				r[0] = last + next(&b)
				r[1] = r[0] + next(&b)
				last = r[1]
			}
		}
		b = raw_data(FOLD_DELTAS)
		last: u32
		for &f in FOLDS {
			f[0] = last + next(&b)
			for k in 1 ..= 2 {
				z := next(&b)
				f[k] = f[0] + (z >> 1 ~ (0 - z & 1)) // unzigzagged, wrapping below f[0]
			}
			last = f[0]
		}
	})
}

// A character type: a property table, or every character outside it.
Prop_Item :: struct {
	table: u16,
	neg:   bool,
}

// Two types derived from a stored one: \w in a class, Oniguruma's POSIX word, which lacks the digits ²³¹ and
// fractions ¼½¾, and the grapheme break class Extend, Grapheme_Extend with the emoji modifiers.
TABLE_CLASS_WORD :: 0xFFFE
TABLE_GCB_EXTEND :: 0xFFFF

in_table :: proc(table: int, r: rune) -> bool {
	switch table {
	case TABLE_CLASS_WORD:
		switch r {
		case 0xB2, 0xB3, 0xB9, 0xBC ..= 0xBE:
			return false
		}
		return in_table(TABLE_WORD, r)
	case TABLE_GCB_EXTEND:
		return r >= 0x1F3FB && r <= 0x1F3FF || in_table(TABLE_GRAPHEME_EXTEND, r)
	}
	ranges := PROPERTY_RANGES[PROPERTY_TABLES[table]:PROPERTY_TABLES[table + 1]]
	k, _ := slice.binary_search_by(ranges, u32(r), proc(x: [2]u32, c: u32) -> slice.Ordering {
		return slice.cmp(x[1], c)
	})
	return k < len(ranges) && ranges[k][0] <= u32(r)
}

// \w, which \b reads too.
is_word :: proc(r: rune) -> bool {
	if r < 0x80 {
		return (r | 0x20) >= 'a' && (r | 0x20) <= 'z' || (r >= '0' && r <= '9') || r == '_'
	}
	return in_table(TABLE_WORD, r)
}

// `\p{name}`'s type: a name compared as Oniguruma compares them, without case, spaces, `_` or `-`.
named_prop :: proc(name: string) -> (it: Prop_Item, ok: bool) {
	b := strings.builder_make(context.temp_allocator)
	for c in name {
		if c != ' ' && c != '_' && c != '-' {
			strings.write_rune(&b, unicode.to_lower(c))
		}
	}
	names, k := PROPERTY_NAMES, 0
	for each in strings.split_iterator(&names, "\x00") {
		if each == strings.to_string(b) {
			return {table = PROPERTY_NAME_TABLES[k]}, true
		}
		k += 1
	}
	return
}

// The rune `r`'s case-fold class as one rune, so two runes fold alike when their classes are the same rune.
fold :: proc(r: rune) -> rune {
	if r < 0x80 {
		return r + 32 if r >= 'A' && r <= 'Z' else r
	}
	f, ok := fold_entry(r)
	return rune(f[2]) if ok else r
}

// The next rune of those `r` folds alike with, round to `r` again, `r` when it folds alone.
fold_next :: proc(r: rune) -> rune {
	f, ok := fold_entry(r)
	return rune(f[1]) if ok else r
}

// The two or three runes, folded, that (?i) matches `r` to besides those it folds alike with.
multi_fold :: proc(r: rune) -> (runes: []u32, ok: bool) {
	k := slice.binary_search_by(MULTI_FOLDS[:], u32(r), proc(f: [4]u32, c: u32) -> slice.Ordering {
		return slice.cmp(f[0], c)
	}) or_return
	return MULTI_FOLDS[k][1:3 if MULTI_FOLDS[k][3] == 0 else 4], true
}

// A rune whose multi_fold is `runes` as they fold.
unfold :: proc(runes: []rune) -> (r: rune, ok: bool) {
	next: for &f in MULTI_FOLDS {
		if (f[3] == 0) != (len(runes) == 2) {
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
fold_entry :: proc(r: rune) -> (f: [3]u32, ok: bool) {
	k := slice.binary_search_by(FOLDS[:], u32(r), proc(f: [3]u32, c: u32) -> slice.Ordering {
		return slice.cmp(f[0], c)
	}) or_return
	return FOLDS[k], true
}
