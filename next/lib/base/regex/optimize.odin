#+private
package regex

// Oniguruma's search optimizer as jq's build runs it (optimize_nodes and set_optimize_info_from_tree in regcomp.c,
// forward_search and the anchors of onig_search in regexec.c). It finds what a match must hold: an exact string or a
// set of bytes at a distance from the match start, chosen by Oniguruma's own weights, and the anchors that bound the
// start. The search tries only the starts these leave, so a hopeless search fails at once where Oniguruma's does, and
// a start that Oniguruma tries runs into the retry limit as it does.

import "core:strings"
import "core:unicode/utf8"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"

INFINITE_LEN :: max(int)
// The most bytes of an exact string kept (OPT_EXACT_MAXLEN).
@(private = "file")
OPT_EXACT_MAXLEN :: 24
// The most bytes of a UTF-8 character, the length a class past ASCII or `.` may match (ONIGENC_MBC_MAXLEN_DIST).
@(private = "file")
MBC_MAXLEN :: 4

Search_Kind :: enum u8 {
	None,
	Exact, // a match holds `exact` at a distance from its start
	Map, // a match holds a byte of `set` at a distance from its start
}

End_Anchor :: enum u8 {
	None,
	End_Buf, // every match ends at the text's end
	Semi_End_Buf, // or before a newline that ends the text
}

// The string or byte set the search skips by, and the anchors, as Oniguruma's regex_t keeps them.
Search_Opt :: struct {
	kind:               Search_Kind,
	exact:              string,
	set:                [4]u64,
	lead:               kernel.Byte_Set, // `set` as the kernel scans for it, filled in for a head that is a set
	dist_min, dist_max: int, // least and greatest distance from the match start to the string or set, or INFINITE_LEN
	threshold:          int, // the fewest bytes past the search's start a match needs
	anchored:           bool, // every match starts at \A
	end:                End_Anchor,
	anc_min, anc_max:   int, // under `end`, a match's least and most bytes
}

@(private = "file")
Mml :: struct {
	min, max: int,
}

@(private = "file")
Opt_Str :: struct {
	mm:        Mml,
	len:       int,
	reach_end: bool, // the string runs to the node's end, so what follows may extend it
	s:         [OPT_EXACT_MAXLEN]byte,
}

@(private = "file")
Opt_Map :: struct {
	mm:    Mml,
	value: int, // the sum of its bytes' map_position_value, lower is rarer
	set:   [4]u64,
}

@(private = "file")
Anchor :: enum u8 {
	Begin_Buf,
	End_Buf,
	Semi_End_Buf,
}

// Oniguruma's OptNode: the node's length, its anchors at either side, the exact strings at its start (sb), anywhere
// (sm) and read ahead (spr), and the byte map at its start.
@(private = "file")
Opt_Node :: struct {
	len:         Mml,
	left, right: bit_set[Anchor; u8],
	sb, sm, spr: Opt_Str,
	set:         Opt_Map,
}

search_opt :: proc(root: ^Node) -> (out: Search_Opt) {
	opt: Opt_Node
	optimize(root, &opt, {})
	out.anchored = .Begin_Buf in opt.left
	if .End_Buf in opt.right {
		out.end = .End_Buf
	} else if .Semi_End_Buf in opt.right {
		out.end = .Semi_End_Buf
	}
	out.anc_min, out.anc_max = opt.len.min, opt.len.max
	use_map := opt.set.value > 0
	if opt.sb.len > 0 || opt.sm.len > 0 {
		select_exact(&opt.sb, &opt.sm)
		use_map &&= exact_or_map(&opt.sb, &opt.set) > 0
		if !use_map {
			out.kind, out.exact = .Exact, strings.clone(string(opt.sb.s[:opt.sb.len]))
			out.dist_min, out.dist_max = opt.sb.mm.min, opt.sb.mm.max
			out.threshold = distance_add(out.dist_min, opt.sb.len)
		}
	}
	if use_map {
		out.kind, out.set = .Map, opt.set.set
		out.dist_min, out.dist_max = opt.set.mm.min, opt.set.mm.max
		out.threshold = distance_add(out.dist_min, 1)
	}
	return
}

@(private = "file")
optimize :: proc(n: ^Node, opt: ^Opt_Node, env: Mml) {
	opt^ = {}
	opt.sb.mm, opt.spr.mm, opt.set.mm = env, env, env
	switch n.kind {
	case .Empty, .Keep:
	case .Char, .Str:
		if literal(n) {
			run_string({n}, opt, env)
		} else if n.fold && utf8.valid_rune(n.r) && n.r < 0x80 && !folds_outside(n.r) {
			// A (?i) character Oniguruma takes as the class of its case variants.
			add_variant_leads(&opt.set, n.r)
			opt.len = {1, 1}
		} else {
			opt.len = {1, MBC_MAXLEN}
		}
	case .Any:
		opt.len = {1, MBC_MAXLEN}
	case .Class:
		if !ascii_only(n.class) || folds_out_of_ascii(n.class) {
			opt.len = {1, MBC_MAXLEN}
			break
		}
		bits := ascii_bits(n.class)
		for r in 0 ..< 0x80 {
			if has_bit(bits[:], r) {
				add_map_byte(&opt.set, byte(r))
			}
		}
		opt.len = {1, 1}
	case .Cat:
		// Runs of literal nodes are optimized as one string, as Oniguruma's parser joins them.
		xo: Opt_Node
		nenv := env
		for i := 0; i < len(n.kids); {
			if j := literal_run_end(n.kids[:], i); j > i {
				run_string(n.kids[i:j], &xo, nenv)
				i = j
			} else {
				optimize(n.kids[i], &xo, nenv)
				i += 1
			}
			nenv = mml_add(nenv, xo.len)
			concat_left(opt, &xo)
		}
	case .Alt:
		if fold_alternation(n) {
			fold_strings(n, opt)
			break
		}
		xo: Opt_Node
		for k, i in n.kids {
			if i == 0 {
				optimize(k, opt, env)
			} else {
				optimize(k, &xo, env)
				alt_merge(opt, &xo)
			}
		}
	case .Group:
		optimize(n.kids[0], opt, env)
	case .Repeat:
		optimize_repeat(n, opt, env)
	case .Assert:
		#partial switch n.assert {
		case .Begin_Buf:
			opt.left += {.Begin_Buf}
		case .End_Buf:
			opt.right += {.End_Buf}
		case .Semi_End_Buf:
			opt.right += {.Semi_End_Buf}
		}
	case .Look:
		#partial switch n.look {
		case .Atomic:
			optimize(n.kids[0], opt, env)
		case .Ahead:
			xo: Opt_Node
			optimize(n.kids[0], &xo, env)
			if xo.sb.len > 0 {
				opt.spr = xo.sb
			} else if xo.sm.len > 0 {
				opt.spr = xo.sm
			}
			opt.spr.reach_end = false
			if xo.set.value > 0 {
				opt.set = xo.set
			}
		}
	case .Cond:
		// Oniguruma's if-else: the condition has no length, the yes branch (kids[0]) follows it, and the result is
		// merged with the no branch (kids[1]).
		xo: Opt_Node
		optimize(n.kids[0], &xo, env)
		concat_left(opt, &xo)
		optimize(n.kids[1], &xo, env)
		alt_merge(opt, &xo)
	case .Linebreak:
		opt.len = {1, 3}
	case .Grapheme:
		opt.len = {1, INFINITE_LEN}
	case .Backref, .Call, .Absent:
		opt.len = {0, INFINITE_LEN}
	}
}

@(private = "file")
optimize_repeat :: proc(n: ^Node, opt: ^Opt_Node, env: Mml) {
	if n.max == 0 {
		return
	}
	body: Opt_Node
	optimize(n.kids[0], &body, env)
	if n.min > 0 {
		opt^ = body
		if body.sb.len > 0 && body.sb.reach_end {
			i := 2
			for ; i <= n.min && opt.sb.len < OPT_EXACT_MAXLEN; i += 1 {
				if concat_exact(&opt.sb, &body.sb) {
					break
				}
			}
			if i < n.min {
				opt.sb.reach_end = false
			}
		}
		if n.min != n.max {
			opt.sb.reach_end, opt.sm.reach_end = false, false
		}
		if n.min > 1 {
			opt.sm.reach_end = false
		}
	}
	most := distance_multiply(body.len.max, n.max)
	if n.max < 0 {
		most = INFINITE_LEN if body.len.max > 0 else 0
	}
	opt.len = {distance_multiply(body.len.min, n.min), most}
}

// Optimizes a run of literal nodes as one string node.
@(private = "file")
run_string :: proc(run: []^Node, opt: ^Opt_Node, env: Mml) {
	head: [OPT_EXACT_MAXLEN + utf8.UTF_MAX]byte
	kept, total := 0, 0
	for k in run {
		buf: [4]byte
		text := literal_text(k, &buf)
		kept += copy(head[kept:], text)
		total += len(text)
	}
	opt^ = {}
	opt.sb.mm, opt.spr.mm, opt.set.mm = env, env, env
	opt_string(opt, head[:kept], total)
}

// Optimizes a string node of `total` bytes, of which `s` holds the first.
@(private = "file")
opt_string :: proc(opt: ^Opt_Node, s: []byte, total: int) {
	e := &opt.sb
	p := 0
	for p < len(s) {
		w := spell.lead_width(s[p])
		if e.len + w > OPT_EXACT_MAXLEN || p + w > len(s) {
			break
		}
		copy(e.s[e.len:], s[p:p + w])
		e.len += w
		p += w
	}
	e.reach_end = p == total
	add_map_byte(&opt.set, s[0])
	opt.len = {total, total}
}

// Whether `n` is the alternation that expand_folds makes of a (?i) character with a multi-character fold, or of a run
// of characters that folds to one. Oniguruma unravels it into an alternation of plain strings, one per case variant.
@(private = "file")
fold_alternation :: proc(n: ^Node) -> bool {
	folded :: proc(n: ^Node) -> bool {
		return n.kind == .Char && n.fold
	}
	if len(n.kids) < 2 {
		return false
	}
	if folded(n.kids[0]) {
		_, multi := multi_fold(n.kids[0].r)
		return multi
	}
	if len(n.kids) != 2 || n.kids[0].kind != .Cat || !folded(n.kids[1]) {
		return false
	}
	for k in n.kids[0].kids {
		folded(k) or_return
	}
	return true
}

@(private = "file")
fold_strings :: proc(n: ^Node, opt: ^Opt_Node) {
	opt.len = {INFINITE_LEN, 0}
	for k in n.kids {
		runes := k.kids[:] if k.kind == .Cat else []^Node{k}
		add_variant_leads(&opt.set, runes[0].r)
		least, most := 0, 0
		for r in runes {
			// A folded character matches each of its case variants, whose UTF-8 may be longer or shorter (ſ for s).
			x := r.r
			lo, hi := utf8.rune_size(x), utf8.rune_size(x)
			for x = fold_next(x); x != r.r; x = fold_next(x) {
				lo, hi = min(lo, utf8.rune_size(x)), max(hi, utf8.rune_size(x))
			}
			least, most = least + lo, most + hi
		}
		opt.len = {min(opt.len.min, least), max(opt.len.max, most)}
	}
}

// The first byte of `r` and of each of its case variants.
@(private = "file")
add_variant_leads :: proc(m: ^Opt_Map, r: rune) {
	x := r
	for {
		if utf8.valid_rune(x) {
			buf, _ := utf8.encode_rune(x)
			add_map_byte(m, buf[0])
		}
		if x = fold_next(x); x == r {
			return
		}
	}
}

// Oniguruma's concat_left_node_opt_info: `add` follows `to`.
@(private = "file")
concat_left :: proc(to, add: ^Opt_Node) {
	left := to.left + (add.left if to.len.max == 0 else {})
	right := add.right + (to.right if add.len.max == 0 else {})
	to.left, to.right = left, right
	sb_reach, sm_reach := to.sb.reach_end, to.sm.reach_end
	if add.len.max != 0 {
		to.sb.reach_end, to.sm.reach_end = false, false
	}
	if add.sb.len > 0 {
		if sb_reach {
			concat_exact(&to.sb, &add.sb)
			add.sb = {}
		} else if sm_reach {
			concat_exact(&to.sm, &add.sb)
			add.sb = {}
		}
	}
	select_exact(&to.sm, &add.sb)
	select_exact(&to.sm, &add.sm)
	if to.spr.len > 0 {
		if add.len.max > 0 {
			select_exact(&to.sb if to.spr.mm.max == 0 else &to.sm, &to.spr)
		}
	} else if add.spr.len > 0 {
		select_exact(&to.spr, &add.spr)
	}
	select_map(&to.set, &add.set)
	to.len = mml_add(to.len, add.len)
}

// Oniguruma's alt_merge_node_opt_info: `add` is an alternative to `to`.
@(private = "file")
alt_merge :: proc(to, add: ^Opt_Node) {
	to.left &= add.left
	to.right &= add.right
	alt_merge_exact(&to.sb, &add.sb)
	alt_merge_exact(&to.sm, &add.sm)
	alt_merge_exact(&to.spr, &add.spr)
	alt_merge_map(&to.set, &add.set)
	to.len = {min(to.len.min, add.len.min), max(to.len.max, add.len.max)}
}

// Appends `add` to `to` by whole characters. Returns true when `to` filled first.
@(private = "file")
concat_exact :: proc(to, add: ^Opt_Str) -> (full: bool) {
	p := 0
	for p < add.len {
		w := spell.lead_width(add.s[p])
		if to.len + w > OPT_EXACT_MAXLEN {
			full = true
			break
		}
		for j := 0; j < w && p < add.len; j += 1 {
			to.s[to.len] = add.s[p]
			to.len += 1
			p += 1
		}
	}
	to.reach_end = add.reach_end if p == add.len else false
	return
}

@(private = "file")
alt_merge_exact :: proc(to, add: ^Opt_Str) {
	if add.len == 0 || to.len == 0 || to.mm != add.mm {
		to^ = {}
		return
	}
	i := 0
	common: for i < min(to.len, add.len) {
		w := spell.lead_width(to.s[i])
		if i + w > min(to.len, add.len) {
			break
		}
		for j in 0 ..< w {
			if to.s[i + j] != add.s[i + j] {
				break common
			}
		}
		i += w
	}
	if !add.reach_end || i < add.len || i < to.len {
		to.reach_end = false
	}
	to.len = i
}

@(private = "file")
alt_merge_map :: proc(to, add: ^Opt_Map) {
	if to.value == 0 {
		return
	}
	if add.value == 0 || to.mm.max < add.mm.min {
		to^ = {}
		return
	}
	to.mm = {min(to.mm.min, add.mm.min), max(to.mm.max, add.mm.max)}
	to.value = 0
	for b in 0 ..< 256 {
		if has_bit(add.set[:], b) {
			add_bit(to.set[:], b)
		}
		if has_bit(to.set[:], b) {
			to.value += map_position_value(byte(b))
		}
	}
}

@(private = "file")
add_map_byte :: proc(m: ^Opt_Map, b: byte) {
	if !has_bit(m.set[:], int(b)) {
		add_bit(m.set[:], int(b))
		m.value += map_position_value(b)
	}
}

// Oniguruma's select_opt_exact: `now` becomes `alt` when that is the better string to search for. For two short
// strings Oniguruma weighs each by the other's first byte.
@(private = "file")
select_exact :: proc(now, alt: ^Opt_Str) {
	vn, va := now.len, alt.len
	if va == 0 {
		return
	}
	if vn == 0 {
		now^ = alt^
		return
	}
	if vn <= 2 && va <= 2 {
		va = map_position_value(now.s[0])
		vn = map_position_value(alt.s[0])
		if now.len > 1 {
			vn += 5
		}
		if alt.len > 1 {
			va += 5
		}
	}
	if compare_distance(now.mm, alt.mm, vn * 2, va * 2) > 0 {
		now^ = alt^
	}
}

@(private = "file")
select_map :: proc(now, alt: ^Opt_Map) {
	if alt.value == 0 {
		return
	}
	if now.value == 0 {
		now^ = alt^
		return
	}
	if compare_distance(now.mm, alt.mm, 32768 / now.value, 32768 / alt.value) > 0 {
		now^ = alt^
	}
}

// Oniguruma's comp_opt_exact_or_map: above 0 when the map is the better to search by.
@(private = "file")
exact_or_map :: proc(e: ^Opt_Str, m: ^Opt_Map) -> int {
	if m.value <= 0 {
		return -1
	}
	return compare_distance(e.mm, m.mm, 20 * e.len * 3, 20 * 5 * 2 / m.value)
}

// Oniguruma's comp_distance_value. Returns above 0 when (d2, v2) is the better, compared by the value times
// 1000 / (spread + 1) of its distance, then by the smaller least distance.
@(private = "file")
compare_distance :: proc(d1, d2: Mml, v1, v2: int) -> int {
	if v2 <= 0 {
		return -1
	}
	if v1 <= 0 {
		return 1
	}
	w1, w2 := v1 * distance_value(d1), v2 * distance_value(d2)
	switch {
	case w2 > w1:
		return 1
	case w2 < w1:
		return -1
	case d2.min < d1.min:
		return 1
	case d2.min > d1.min:
		return -1
	}
	return 0
}

@(private = "file")
distance_value :: proc(mm: Mml) -> int {
	// 1000 / (spread + 1)
	@(static, rodata)
	DIST_VALS := [100]u16 {
		1000, 500, 333, 250, 200, 167, 143, 125, 111, 100, 91, 83, 77, 71, 67, 63, 59, 56, 53, 50,
		48, 45, 43, 42, 40, 38, 37, 36, 34, 33, 32, 31, 30, 29, 29, 28, 27, 26, 26, 25,
		24, 24, 23, 23, 22, 22, 21, 21, 20, 20, 20, 19, 19, 19, 18, 18, 18, 17, 17, 17,
		16, 16, 16, 16, 15, 15, 15, 15, 14, 14, 14, 14, 14, 14, 13, 13, 13, 13, 13, 13,
		12, 12, 12, 12, 12, 12, 11, 11, 11, 11, 11, 11, 11, 11, 11, 10, 10, 10, 10, 10,
	}
	if mm.max == INFINITE_LEN {
		return 0
	}
	d := mm.max - mm.min
	return int(DIST_VALS[d]) if d < len(DIST_VALS) else 1
}

// Returns how common Oniguruma takes byte `b` to be in a text. A byte of a higher value is the worse to search by.
@(private = "file")
map_position_value :: proc(b: byte) -> int {
	@(static, rodata)
	VALS := [128]u8 {
		5, 1, 1, 1, 1, 1, 1, 1, 1, 10, 10, 1, 1, 10, 1, 1,
		1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
		12, 4, 7, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5,
		6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 5, 5, 5, 5, 5, 5,
		5, 6, 6, 6, 6, 7, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
		6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 5, 6, 5, 5, 5,
		5, 6, 6, 6, 6, 7, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
		6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 5, 5, 5, 5, 1,
	}
	return int(VALS[b]) if b < 0x80 else 4
}

@(private = "file")
distance_add :: proc(a, b: int) -> int {
	if a == INFINITE_LEN || b == INFINITE_LEN || a > INFINITE_LEN - b {
		return INFINITE_LEN
	}
	return a + b
}

@(private = "file")
distance_multiply :: proc(d, m: int) -> int {
	if m == 0 {
		return 0
	}
	return d * m if d < INFINITE_LEN / m else INFINITE_LEN
}

@(private = "file")
mml_add :: proc(a, b: Mml) -> Mml {
	return {distance_add(a.min, b.min), distance_add(a.max, b.max)}
}

// The bytes a head scan tests one at a time before it scans with the kernel: a candidate within a few bytes is common
// and the scan's setup costs more than testing them.
@(private = "file")
NEAR :: 8

// A rest of the text shorter than this is walked without the scan, whose setup costs more than it saves.
@(private = "file")
SHORT :: 128

// The first place from `at` whose byte is in the set of the head `h`, or -1. The places are those a walk by character
// reaches, stepping `lead_width` from each byte, as Oniguruma's map search does. Over invalid UTF-8 that steps past
// bytes that a scan for the set would stop at. So the scan stops at a byte of `h.lead`, which holds every byte from
// 0x80 too: the bytes before it are ASCII, which the walk reaches one by one, and where it stops at a byte from 0x80
// the walk takes over. `at` must be a place the walk reaches.
next_head_byte :: #force_inline proc(h: ^Search_Opt, s: string, at: int) -> int {
	if len(s) - at < SHORT {
		return walk_head_byte(h, s, at)
	}
	near := at + NEAR
	for j in at ..< near {
		c := s[j]
		if has_bit(h.set[:], int(c)) {
			return j
		}
		if c >= 0x80 {
			return walk_to_head_byte(h, s, j)
		}
	}
	return scan_to_head_byte(h, s, near)
}

@(private = "file")
walk_head_byte :: #force_inline proc(h: ^Search_Opt, s: string, from: int) -> int {
	at := from
	for at < len(s) && !has_bit(h.set[:], int(s[at])) {
		at += spell.lead_width(s[at])
	}
	return at if at < len(s) else -1
}

@(private = "file")
walk_to_head_byte :: #force_no_inline proc(h: ^Search_Opt, s: string, from: int) -> int {
	return walk_head_byte(h, s, from)
}

@(private = "file")
scan_to_head_byte :: #force_no_inline proc(h: ^Search_Opt, s: string, from: int) -> int {
	k := kernel.index_set(transmute([]u8)s[from:], h.lead)
	if k < 0 {
		return -1
	}
	at := from + k
	if s[at] >= 0x80 && !has_bit(h.set[:], int(s[at])) {
		return walk_head_byte(h, s, at)
	}
	return at
}

// Computes the starts onig_search tries from `start`: `first` to `last`. `limit` is how far a string or map that the
// optimizer finds may reach. `high` is the last start of the first window, or -1 when the windows are found one at a
// time with `next_window`. Returns ok false when no start can match. Kept out of line so that the matcher inlined into
// `search` keeps its registers.
search_starts :: #force_no_inline proc(
	o: ^Search_Opt,
	s: string,
	start: int,
) -> (
	first, last, limit, high: int,
	ok: bool,
) {
	first, last, limit, high = start, len(s), len(s), INFINITE_LEN
	if o.anchored {
		if start != 0 {
			return
		}
		last = min(1, len(s))
	} else if o.end != .None && len(s) > 0 {
		if first, last = end_bounds(o, s, start); first > last {
			return
		}
	}
	if len(s) - first < o.threshold {
		return
	}
	if o.kind == .None {
		return first, last, limit, high, true
	}
	if o.dist_max == INFINITE_LEN {
		_, _, found := forward_search(o, s, first, limit)
		return first, last, limit, high, found
	}
	if o.dist_max == 0 {
		limit = last
	} else if len(s) - last >= o.dist_max {
		limit = last + o.dist_max
	}
	return first, last, limit, -1, true
}

// Returns the next start at or past `at`, in a window of starts from low to high that a string or map found at a
// bounded distance gives, and sets `high^` to that window's last start. Returns -1 when there is none.
next_window :: #force_no_inline proc(o: ^Search_Opt, s: string, at, limit: int, high: ^int) -> int {
	low, h, found := forward_search(o, s, at, limit)
	if !found {
		return -1
	}
	high^ = h
	return max(at, low)
}

// Oniguruma's forward_search from `from`. Finds the first place at or past `from` where the string or map occurs, and
// returns the starts that a match holding it there can have, `low` to `high`.
forward_search :: proc(o: ^Search_Opt, s: string, from, limit: int) -> (low, high: int, found: bool) {
	p := from
	if o.dist_min != 0 {
		if len(s) - p <= o.dist_min {
			return
		}
		for q := p + o.dist_min; p < q; {
			p += spell.lead_width(s[p])
		}
	}
	if o.kind == .Exact {
		k := strings.index(s[min(p, len(s)):], o.exact)
		if k < 0 {
			return
		}
		p += k
	} else {
		for p < limit && !has_bit(o.set[:], int(s[p])) {
			p += spell.lead_width(s[p])
		}
	}
	if p >= limit {
		return
	}
	if o.dist_max == 0 {
		return p, p, true
	}
	low = from
	if o.dist_max != INFINITE_LEN {
		low = max(p - o.dist_max, 0)
		if low > from {
			low = spell.skip_continuations(s, low)
		}
	}
	return low, max(p - o.dist_min, 0), true
}

// Returns the first and last start of a match that ends at the text's end, or before a newline that ends it, as
// onig_search's end_buf bounds them. `first` is past `last` when there is none. When the text's final newline is also
// its first byte, or lies before `start`, the starts stay unbounded, as onig_search then skips end_buf.
end_bounds :: proc(o: ^Search_Opt, s: string, start: int) -> (first, last: int) {
	first, last = start, len(s)
	min_end, max_end := len(s), len(s)
	if o.end == .Semi_End_Buf && s[len(s) - 1] == '\n' {
		if len(s) == 1 || start > len(s) - 1 {
			return
		}
		min_end = len(s) - 1
	}
	if max_end < o.anc_min {
		return 1, 0
	}
	if o.anc_max != INFINITE_LEN && min_end - first > o.anc_max {
		first = min_end - o.anc_max
		first = spell.skip_continuations(s, first)
	}
	if max_end - (last - 1) < o.anc_min {
		if max_end + 1 < o.anc_min {
			return 1, 0
		}
		last = max_end - o.anc_min + 1
	}
	return
}

// Adds to `set` every byte a match of `n` can start with. `ok` is false when that is not known, and `empty` is true
// when `n` can match without a byte, so what follows it starts the match too.
first_bytes :: proc(n: ^Node, set: ^[4]u64) -> (empty: bool, ok: bool) {
	add_rune :: proc(set: ^[4]u64, r: rune) {
		if !utf8.valid_rune(r) {
			return
		}
		buf, _ := utf8.encode_rune(r)
		add_bit(set[:], int(buf[0]))
		if r >= 0x80 && r < 0xC0 { // a search that starts inside a character reads the byte r itself
			add_bit(set[:], int(r))
		}
	}
	switch n.kind {
	case .Empty, .Assert, .Keep:
		return true, true
	case .Char:
		add_rune(set, n.r)
		if n.fold {
			for x := fold_next(n.r); x != n.r; x = fold_next(x) {
				add_rune(set, x)
			}
		}
		return false, true
	case .Str:
		add_rune(set, n.r)
		return false, true
	case .Any:
		for b in 0 ..< 256 {
			if b != '\n' || n.dotall {
				add_bit(set[:], b)
			}
		}
		return false, true
	case .Class:
		set[0] |= n.class.ascii[0] // filled when the class was emitted
		set[1] |= n.class.ascii[1]
		if !ascii_only(n.class) || folds_out_of_ascii(n.class) {
			set[2], set[3] = max(u64), max(u64)
		}
		return false, true
	case .Linebreak:
		for b in ([]byte{'\n', '\v', '\f', '\r', 0xC2, 0xE2}) {
			add_bit(set[:], int(b))
		}
		return false, true
	case .Cat:
		for k in n.kids {
			empty, ok = first_bytes(k, set)
			if !ok || !empty {
				return
			}
		}
		return true, true
	case .Alt:
		for k in n.kids {
			e, o := first_bytes(k, set)
			if !o {
				return false, false
			}
			empty ||= e
		}
		return empty, true
	case .Group:
		return first_bytes(n.kids[0], set)
	case .Repeat:
		empty, ok = first_bytes(n.kids[0], set)
		return empty || n.min == 0, ok
	case .Look:
		if n.look == .Atomic {
			return first_bytes(n.kids[0], set)
		}
		if n.look == .Ahead {
			if e, o := first_bytes(n.kids[0], set); o && !e {
				return false, true // the match starts where the look-ahead's does
			}
		}
		return true, true // consumes no bytes, so what follows starts the match
	case .Backref, .Cond, .Grapheme, .Call, .Absent:
	}
	return false, false
}

// Appends to `out` the literal every match of `n` starts with. Returns whether `n` is wholly that literal.
literal_prefix :: proc(n: ^Node, out: ^[dynamic]byte) -> bool {
	#partial switch n.kind {
	case .Char, .Str:
		if !literal(n) {
			return false
		}
		buf: [4]byte
		append(out, literal_text(n, &buf))
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
	case .Repeat:
		// A counted literal is searched as the text it spells, so that a long run does not retry at each start.
		one: [dynamic]byte
		defer delete(one)
		if n.min == 0 || !literal_prefix(n.kids[0], &one) || len(one) == 0 || n.min * len(one) > PREFIX_MAXLEN {
			return false
		}
		for _ in 0 ..< n.min {
			append(out, ..one[:])
		}
		return n.max == n.min
	}
	return false
}

// The most bytes of a literal prefix built from a counted repeat.
PREFIX_MAXLEN :: 1 << 16
