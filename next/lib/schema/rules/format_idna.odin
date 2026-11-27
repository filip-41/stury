package rules

@(private) Derived  :: enum u8 { Disallowed, Pvalid, Context_J, Context_O }
@(private) Joining  :: enum u8 { U, L, R, D, T, C }
@(private) Bidi     :: enum u8 { L, R, AL, AN, EN, ES, CS, ET, ON, BN, NSM }
@(private) Map_Kind :: enum u8 { Keep, Drop, Refuse, Shift, String }

@(private, rodata) PROPERTY_RUNS := #load("tables/idna.bin", []u32)
@(private, rodata) MAP_RUNS      := #load("tables/idna_map.bin", []u64)
@(private, rodata) MAP_POOL      := #load("tables/idna_pool.bin", []u32)

@(private) MAX_MAPPED :: 6

@(private)
run_at :: proc "contextless" (runs: []$T, shift: uint, r: rune) -> T {
	lo, hi := 0, len(runs)
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		if int(runs[mid] >> shift) <= int(r) { lo = mid } else { hi = mid }
	}
	return runs[lo]
}

@(private)
Properties :: struct { derived: Derived, joining: Joining, bidi: Bidi, virama: bool }

@(private)
properties_of :: proc "contextless" (r: rune) -> Properties {
	run := run_at(PROPERTY_RUNS, 10, r)
	return {Derived(run & 3), Joining(run >> 2 & 7), Bidi(run >> 5 & 15), run >> 9 & 1 == 1}
}

@(private)
map_code_point :: proc "contextless" (r: rune, out: ^[MAX_MAPPED]rune) -> (n: int, ok: bool) {
	run := run_at(MAP_RUNS, 40, r)
	payload := u32(run)
	switch Map_Kind(run >> 32 & 0xFF) {
	case .Keep:   out[0] = r; return 1, true
	case .Drop:   return 0, true
	case .Refuse: return 0, false
	case .Shift:  out[0] = r + rune(i32(payload)); return 1, true
	case .String:
		n = int(payload & 31)
		for k in 0 ..< n { out[k] = rune(MAP_POOL[int(payload >> 5) + k]) }
		return n, true
	}
	return 0, false
}

@(private)
has_cjk_script :: proc "contextless" (cps: []rune) -> bool {
	for r in cps {
		if in_idna_prop(.Hiragana, r) || in_idna_prop(.Katakana, r) || in_idna_prop(.Han, r) { return true }
	}
	return false
}

@(private)
joins_across :: proc "contextless" (cps: []rune, at: int) -> bool {
	i := at - 1
	for i >= 0 && properties_of(cps[i]).joining == .T { i -= 1 }
	if i < 0 || properties_of(cps[i]).joining != .L && properties_of(cps[i]).joining != .D { return false }
	j := at + 1
	for j < len(cps) && properties_of(cps[j]).joining == .T { j += 1 }
	return j < len(cps) && (properties_of(cps[j]).joining == .R || properties_of(cps[j]).joining == .D)
}

@(private)
in_context :: proc "contextless" (cps: []rune, i: int) -> bool {
	before := cps[i - 1] if i > 0 else rune(0)
	after := cps[i + 1] if i + 1 < len(cps) else rune(0)
	switch cps[i] {
	case 0xB7:           return before == 'l' && after == 'l'
	case 0x375:          return in_idna_prop(.Greek, after)
	case 0x5F3, 0x5F4:   return in_idna_prop(.Hebrew, before)
	case 0x30FB:         return has_cjk_script(cps)
	case 0x200D:         return properties_of(before).virama
	case 0x200C:         return properties_of(before).virama || joins_across(cps, i)
	case 0x660 ..= 0x669: return !any_between(cps, 0x6F0, 0x6F9)
	case 0x6F0 ..= 0x6F9: return !any_between(cps, 0x660, 0x669)
	}
	return false
}

@(private)
any_between :: proc "contextless" (cps: []rune, lo, hi: rune) -> bool {
	for r in cps { if r >= lo && r <= hi { return true } }
	return false
}

@(private)
ulabel_valid :: proc "contextless" (cps: []rune, bidi: bool) -> (rtl, ok: bool) {
	n := len(cps)
	if n == 0 || cps[0] == '-' || cps[n - 1] == '-' || in_idna_prop(.Mark, cps[0]) { return }
	for r, i in cps {
		p := properties_of(r)
		switch p.derived {
		case .Disallowed: return
		case .Pvalid:
		case .Context_J, .Context_O: in_context(cps, i) or_return
		}
		rtl ||= p.bidi == .R || p.bidi == .AL || p.bidi == .AN
	}
	return rtl, !bidi || bidi_valid(cps)
}

@(private)
bidi_valid :: proc "contextless" (cps: []rune) -> bool {
	first := properties_of(cps[0]).bidi
	if first != .L && first != .R && first != .AL { return false }
	numbers, last := bit_set[Bidi]{}, first
	for r in cps {
		c := properties_of(r).bidi
		if first == .L && (c == .R || c == .AL || c == .AN) || first != .L && c == .L { return false }
		if c != .NSM { last = c }
		numbers += {c} & {.EN, .AN}
	}
	if first == .L { return last == .L || last == .EN }
	return numbers != {.EN, .AN} && (last == .R || last == .AL || last == .EN || last == .AN)
}
