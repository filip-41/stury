#+private
package regex

// Oniguruma's compile-time search optimizer as jq's build runs it (optimize_nodes and set_optimize_info_from_tree in
// regcomp.c). It finds what a match must hold: an exact string or a set of bytes at a distance from the match start,
// chosen by Oniguruma's own weights, and the anchors that bound the start. The runtime prefilter and start-window
// search live in skip.odin.

import "core:strings"
import "core:unicode/utf8"
import "stury:lib/base/spell"

// The most bytes of an exact string kept (OPT_EXACT_MAXLEN).
@(private = "file")
OPT_EXACT_MAXLEN :: 24
// The most bytes of a UTF-8 character, the length a class past ASCII or `.` may match (ONIGENC_MBC_MAXLEN_DIST).
@(private = "file")
MBC_MAXLEN :: 4

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
		use_map &&= compare_distance(opt.sb.mm, opt.set.mm, 60 * opt.sb.len, 200 / opt.set.value) > 0
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
	xo: Opt_Node
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
		nenv := env
		for i := 0; i < len(n.kids); {
			if j := literal_run_end(n.kids[:], i); j > i {
				run_string(n.kids[i:j], &xo, nenv)
				i = j
			} else {
				optimize(n.kids[i], &xo, nenv)
				i += 1
			}
			nenv = {distance_add(nenv.min, xo.len.min), distance_add(nenv.max, xo.len.max)}
			concat_left(opt, &xo)
		}
	case .Alt:
		if fold_alternation(n) {
			fold_strings(n, opt)
			break
		}
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
			if i <= n.min {
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
	most := (INFINITE_LEN if body.len.max > 0 else 0) if n.max < 0 else distance_multiply(body.len.max, n.max)
	opt.len = {distance_multiply(body.len.min, n.min), most}
}

// Optimizes a run of literal nodes as one string node.
@(private = "file")
run_string :: proc(run: []^Node, opt: ^Opt_Node, env: Mml) {
	opt^ = {}
	opt.sb.mm, opt.spr.mm, opt.set.mm = env, env, env
	e := &opt.sb
	total := 0
	full := false
	for k in run {
		buf: [4]byte
		text := literal_text(k, &buf)
		if total == 0 {
			add_map_byte(&opt.set, text[0])
		}
		total += len(text)
		for p := 0; !full && p < len(text); {
			w := spell.lead_width(text[p])
			if e.len + w > OPT_EXACT_MAXLEN || p + w > len(text) {
				full = true
				break
			}
			copy(e.s[e.len:], text[p:p + w])
			e.len += w
			p += w
		}
	}
	e.reach_end = e.len == total
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
	to.len = {distance_add(to.len.min, add.len.min), distance_add(to.len.max, add.len.max)}
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
		n := min(w, add.len - p)
		copy(to.s[to.len:], add.s[p:p + n])
		to.len, p = to.len + n, p + n
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
	for b in 0 ..< 256 {
		if has_bit(add.set[:], b) {
			add_map_byte(to, byte(b))
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
	if mm.max == INFINITE_LEN {
		return 0
	}
	d := mm.max - mm.min
	return (1000 + (d + 1) / 2) / (d + 1) if d < 100 else 1
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
