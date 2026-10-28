package regex

// \X's extended grapheme clusters, which the matcher steps over.

import "core:unicode"

// \X, an extended grapheme cluster by UAX #29's rules as Oniguruma 6.9.10 keeps them (no GB9c), over the
// break classes its \X shows (unicode_tables.odin).
@(private)
grapheme :: proc(s: string, pos: int, behind: ^Grapheme_Behind) -> int {
	if pos >= len(s) {
		return -1
	}
	prev, w := decode(s, pos)
	p := pos + w
	// Oniguruma's classes fail on a continuation byte, where jq's global search can start: it is no Control,
	// and its lookbehinds see the whole character it belongs to.
	inside := s[pos] & 0xC0 == 0x80
	if !inside && in_table(TABLE_GCB_ALONE, prev) { // GB3, GB4
		return p + 1 if prev == '\r' && p < len(s) && s[p] == '\n' else p
	}
	before_emoji, before_regional := grapheme_behind(behind, s, pos)
	// An odd count of regional indicators so far, Extended_Pictographic Extend* so far, and a ZWJ after them.
	whole, _ := decode(s, char_start(s, pos))
	regional := !before_regional && in_table(TABLE_REGIONAL, prev)
	emoji := in_table(TABLE_PICTOGRAPHIC, whole) || before_emoji && in_table(TABLE_GCB_EXTEND, whole)
	zwj := before_emoji && whole == 0x200D
	for p < len(s) {
		r, rw := decode(s, p)
		joins: bool
		switch {
		case in_table(TABLE_GCB_ALONE, r): // GB5
		case hangul_joins(prev, r), in_table(TABLE_GCB_JOIN, r), in_table(TABLE_GCB_PREPEND, prev): // GB6-GB9b
			joins = true
		case zwj:
			joins = in_table(TABLE_PICTOGRAPHIC, r) // GB11
		case regional:
			joins = in_table(TABLE_REGIONAL, r) // GB12, GB13
		}
		if !joins {
			break
		}
		zwj = emoji && r == 0x200D
		emoji = in_table(TABLE_PICTOGRAPHIC, r) || emoji && in_table(TABLE_GCB_EXTEND, r)
		regional = !regional && in_table(TABLE_REGIONAL, r)
		prev = r
		p += rw
	}
	return p
}

// What Oniguruma's \X reads back over the text before a cluster (GB11, GB12/13) at `pos`: whether the
// characters before it end in Extended_Pictographic Extend*, and in an odd run of regional indicators.
// Kept for the last position asked, a walk back stops there, so a search's positions in order cost one walk.
@(private)
Grapheme_Behind :: struct {
	pos:             int, // 0 for none kept
	emoji, regional: bool,
}

@(private = "file")
grapheme_behind :: proc(b: ^Grapheme_Behind, s: string, pos: int) -> (emoji, regional: bool) {
	// The characters the walk reads start at stop or after. Those before it are what b kept, the one holding byte
	// stop among them.
	stop := b.pos if 0 < b.pos && b.pos <= pos else 0
	found := false
	for q := pos; q > stop; {
		if q = char_start(s, q - 1); q < stop {
			break
		}
		if r, _ := decode(s, q); !in_table(TABLE_GCB_EXTEND, r) {
			emoji, found = in_table(TABLE_PICTOGRAPHIC, r), true
			break
		}
	}
	if !found && stop > 0 {
		emoji = b.emoji
	}
	found = false
	for q := pos; q > stop; {
		if q = char_start(s, q - 1); q < stop {
			break
		}
		if r, _ := decode(s, q); !in_table(TABLE_REGIONAL, r) {
			found = true
			break
		}
		regional = !regional
	}
	if !found && stop > 0 {
		regional = regional != b.regional
	}
	b^ = {pos, emoji, regional}
	return
}

// GB6-GB8: L × (L | V | LV | LVT), (LV | V) × (V | T), (LVT | T) × T.
@(private = "file")
hangul_joins :: proc(prev, r: rune) -> bool {
	// Unicode 16 has the Kirat Rai vowel signs V too, which core:unicode's Unicode 17 does not.
	vowel :: proc(r: rune) -> bool {
		return unicode.is_hangul_syllable_vowel(r) || r == 0x16D63 || r >= 0x16D67 && r <= 0x16D6A
	}
	if unicode.is_hangul_syllable_leading(prev) {
		return unicode.is_hangul_syllable_leading(r) || vowel(r) || unicode.is_hangul_syllable_lv(r) || unicode.is_hangul_syllable_lvt(r)
	}
	if unicode.is_hangul_syllable_lv(prev) || vowel(prev) {
		return vowel(r) || unicode.is_hangul_syllable_trailing(r)
	}
	return (unicode.is_hangul_syllable_lvt(prev) || unicode.is_hangul_syllable_trailing(prev)) && unicode.is_hangul_syllable_trailing(r)
}
