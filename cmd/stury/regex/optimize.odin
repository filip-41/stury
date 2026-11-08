package regex

// Oniguruma's search optimizer as jq's build runs it (optimize_nodes and set_optimize_info_from_tree in regcomp.c,
// forward_search and the anchors of onig_search in regexec.c): what a match must hold, an exact string or a set of
// bytes at a distance from its start, chosen by Oniguruma's own weights, and the anchors that bound its start. The
// search tries the starts these leave, so a hopeless search fails at once where Oniguruma's does, and a start
// Oniguruma tries runs into the retry limit as its does.

import "core:strings"
import "core:unicode/utf8"

INFINITE_LEN :: max(int)
// The most bytes of an exact string kept (OPT_EXACT_MAXLEN).
@(private = "file")
OPT_EXACT_MAXLEN :: 24
// A UTF-8 character's most bytes, which a class past ASCII or `.` may take (ONIGENC_MBC_MAXLEN_DIST).
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

// What the search skips by, as Oniguruma's regex_t keeps it.
Search_Opt :: struct {
	kind:               Search_Kind,
	exact:              string,
	set:                [4]u64,
	dist_min, dist_max: int, // INFINITE_LEN for no bound
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

@(private)
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
		} else if n.fold && utf8.valid_rune(n.r) && orbit_ascii(n.r) {
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
		for r in rune(0) ..< 0x80 {
			if class_match_slow(n.class, r) {
				add_map_byte(&opt.set, byte(r))
			}
		}
		opt.len = {1, 1}
	case .Cat:
		// Literal runs are one string, as Oniguruma's parser joins them.
		xo: Opt_Node
		nenv := env
		for i := 0; i < len(n.kids); {
			j := i
			for j < len(n.kids) && literal(n.kids[j]) {
				j += 1
			}
			if j > i {
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
		// Oniguruma's if-else: the condition, of no length, then the yes branch, merged with the no branch.
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

// A run of literal characters as one string node.
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

// A string node of `total` bytes, which `s` begins.
@(private = "file")
opt_string :: proc(opt: ^Opt_Node, s: []byte, total: int) {
	e := &opt.sb
	p := 0
	for p < len(s) {
		w := lead_width(s[p])
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

// The alternation expand_folds makes of a (?i) character with a multi-character fold, or of the run that folds
// to one: Oniguruma unravels it into an alternation of plain strings, each case variant one.
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
		bytes := 0
		for r in runes {
			bytes += utf8.rune_size(r.r)
		}
		opt.len = {min(opt.len.min, bytes), max(opt.len.max, bytes)}
	}
}

// Whether `r` and every case variant of it are ASCII.
@(private = "file")
orbit_ascii :: proc(r: rune) -> bool {
	x := r
	for x < 0x80 {
		if x = fold_next(x); x == r {
			return true
		}
	}
	return false
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

// Appends `add` to `to` by whole characters, true when `to` filled first.
@(private = "file")
concat_exact :: proc(to, add: ^Opt_Str) -> (full: bool) {
	p := 0
	for p < add.len {
		w := lead_width(add.s[p])
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
		w := lead_width(to.s[i])
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
		w, bit := b >> 6, u64(1) << (u64(b) & 63)
		to.set[w] |= add.set[w] & bit
		if to.set[w] & bit != 0 {
			to.value += map_position_value(byte(b))
		}
	}
}

@(private = "file")
add_map_byte :: proc(m: ^Opt_Map, b: byte) {
	w, bit := b >> 6, u64(1) << (u64(b) & 63)
	if m.set[w] & bit == 0 {
		m.set[w] |= bit
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

// Oniguruma's comp_distance_value: above 0 when (d2, v2) is the better, by value over the distance's spread, then
// by the nearer distance.
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

// How common Oniguruma takes byte `b` to be in a text: a byte of a higher value is the worse to search by.
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

// The starts onig_search tries from `start`, `first` to `last`, with the end a string or map the optimizer finds may
// reach, and the last start of the first window, before `first` when each window is looked for in turn. False when
// no start can match. Kept out of line so the matcher inlined into `search` keeps its registers.
@(private)
search_starts :: #force_no_inline proc(o: ^Search_Opt, s: string, start: int) -> (first, last, limit, high: int, ok: bool) {
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

// The next start at or past `at` in a window of starts, low to high, a string or map the optimizer finds at a
// bounded distance gives, with `high` moved to that window's end, or -1 when there is none.
@(private)
next_window :: #force_no_inline proc(o: ^Search_Opt, s: string, at, limit: int, high: ^int) -> int {
	low, h, found := forward_search(o, s, at, limit)
	if !found {
		return -1
	}
	high^ = h
	return max(at, low)
}

// Oniguruma's forward_search from `from`: the first place at or past it the string or map is, and the starts a match
// holding it there can have, `low` to `high`.
@(private)
forward_search :: proc(o: ^Search_Opt, s: string, from, limit: int) -> (low, high: int, found: bool) {
	p := from
	if o.dist_min != 0 {
		if len(s) - p <= o.dist_min {
			return
		}
		for q := p + o.dist_min; p < q; {
			p += lead_width(s[p])
		}
	}
	if o.kind == .Exact {
		k := strings.index(s[min(p, len(s)):], o.exact)
		if k < 0 {
			return
		}
		p += k
	} else {
		for p < limit && o.set[s[p] >> 6] & (1 << (u64(s[p]) & 63)) == 0 {
			p += lead_width(s[p])
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
		for low > from && low < len(s) && s[low] & 0xC0 == 0x80 {
			low += 1
		}
	}
	return low, max(p - o.dist_min, 0), true
}

// The first and last start of a match that ends at the text's end, or before a newline that ends it, as onig_search's
// end_buf bounds them, first past last for none.
@(private)
end_bounds :: proc(o: ^Search_Opt, s: string, start: int) -> (first, last: int) {
	first, last = start, len(s)
	min_end, max_end := len(s), len(s)
	if o.end == .Semi_End_Buf && s[len(s) - 1] == '\n' && len(s) > 1 && start <= len(s) - 1 {
		min_end = len(s) - 1
	}
	if max_end < o.anc_min {
		return 1, 0
	}
	if o.anc_max != INFINITE_LEN && min_end - first > o.anc_max {
		first = min_end - o.anc_max
		for first < len(s) && s[first] & 0xC0 == 0x80 {
			first += 1
		}
	}
	if max_end - (last - 1) < o.anc_min {
		if max_end + 1 < o.anc_min {
			return 1, 0
		}
		last = max_end - o.anc_min + 1
	}
	return
}
