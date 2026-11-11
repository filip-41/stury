package rules

import regex "../regex"

// The rules of RFC 5891, 5892 and 5893 a U-label is judged by, and the mapping of UTS 46 a name takes before it is.
// The tables are idna_tables.py's, Unicode 12.0.0 (the version IANA's registry is based on), little-endian.

// IDNA2008's derived property of a code point: the others, UNASSIGNED included, are refused.
@(private)
Derived :: enum u8 {
	Disallowed,
	Pvalid,
	Context_J,
	Context_O,
}

@(private)
Joining :: enum u8 {
	U,
	L,
	R,
	D,
	T,
	C,
}

@(private)
Bidi :: enum u8 {
	L,
	R,
	AL,
	AN,
	EN,
	ES,
	CS,
	ET,
	ON,
	BN,
	NSM,
}

// The code points' properties as runs, each a u32 of `start << 10 | derived | joining << 2 | bidi << 5 | virama << 9`
// that holds to the next run's start. A code point that is not PVALID, CONTEXTJ or CONTEXTO has all zero.
@(private, rodata)
PROPERTY_RUNS := #load("tables/idna.bin", []u32)

// UTS 46's mapping as runs, each a u64 of `start << 40 | kind << 32 | payload`: a shift is the signed distance to the
// one code point it maps to, a string the offset << 5 | length of its code points in MAP_POOL.
@(private, rodata)
MAP_RUNS := #load("tables/idna_map.bin", []u64)

@(private, rodata)
MAP_POOL := #load("tables/idna_pool.bin", []u32)

@(private)
Map_Kind :: enum u8 {
	Keep,
	Drop,
	Refuse,
	Shift,
	String,
}

// The most code points the mapping gives one.
@(private)
MAX_MAPPED :: 6

// The last of `runs` that starts at or before `r`; the first starts at 0.
@(private)
run_at :: proc(runs: []$T, shift: uint, r: rune) -> T {
	lo, hi := 0, len(runs)
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		if int(runs[mid] >> shift) <= int(r) {
			lo = mid
		} else {
			hi = mid
		}
	}
	return runs[lo]
}

@(private)
Properties :: struct {
	derived: Derived,
	joining: Joining,
	bidi:    Bidi,
	virama:  bool,
}

@(private)
properties_of :: proc(r: rune) -> Properties {
	run := run_at(PROPERTY_RUNS, 10, r)
	return {Derived(run & 3), Joining(run >> 2 & 7), Bidi(run >> 5 & 15), run >> 9 & 1 == 1}
}

// What UTS 46 makes of `r` in `out`, and how many code points: none when it is ignored. Not ok when it is disallowed,
// which includes what UseSTD3ASCIIRules refuses. The deviations are kept.
@(private)
map_code_point :: proc(r: rune, out: ^[MAX_MAPPED]rune) -> (n: int, ok: bool) {
	run := run_at(MAP_RUNS, 40, r)
	payload := u32(run)
	switch Map_Kind(run >> 32 & 0xFF) {
	case .Keep:
		out[0] = r
		return 1, true
	case .Drop:
		return 0, true
	case .Refuse:
		return 0, false
	case .Shift:
		out[0] = r + rune(i32(payload))
		return 1, true
	case .String:
		n = int(payload & 31)
		for k in 0 ..< n {
			out[k] = rune(MAP_POOL[int(payload >> 5) + k])
		}
		return n, true
	}
	return 0, false
}

@(private)
is_mark :: proc(r: rune) -> bool {
	return regex.in_property("m", r)
}

// Whether `cps` holds a code point of one of the scripts.
@(private)
has_script :: proc(cps: []rune, scripts: ..string) -> bool {
	for r in cps {
		for script in scripts {
			if regex.in_property(script, r) {
				return true
			}
		}
	}
	return false
}

// Whether the zero width non-joiner at `at` is between joining letters, RFC 5892 appendix A.1: a Joining_Type L or D, then
// any T, before it, and any T, then an R or D, after it.
@(private)
joins_across :: proc(cps: []rune, at: int) -> bool {
	i := at - 1
	for i >= 0 && properties_of(cps[i]).joining == .T {
		i -= 1
	}
	if i < 0 || properties_of(cps[i]).joining != .L && properties_of(cps[i]).joining != .D {
		return false
	}
	j := at + 1
	for j < len(cps) && properties_of(cps[j]).joining == .T {
		j += 1
	}
	return j < len(cps) && (properties_of(cps[j]).joining == .R || properties_of(cps[j]).joining == .D)
}

// Whether the code point at `i` of `cps`, which has the context rule of RFC 5892 appendix A, is in its context.
@(private)
in_context :: proc(cps: []rune, i: int) -> bool {
	before, after := rune(0), rune(0)
	if i > 0 {
		before = cps[i - 1]
	}
	if i + 1 < len(cps) {
		after = cps[i + 1]
	}
	switch cps[i] {
	case 0xB7:
		return before == 'l' && after == 'l'
	case 0x375:
		return regex.in_property("greek", after)
	case 0x5F3, 0x5F4:
		return regex.in_property("hebrew", before)
	case 0x30FB:
		return has_script(cps, "hiragana", "katakana", "han")
	case 0x200D:
		return properties_of(before).virama
	case 0x200C:
		return properties_of(before).virama || joins_across(cps, i)
	case 0x660 ..= 0x669:
		return !any_between(cps, 0x6F0, 0x6F9)
	case 0x6F0 ..= 0x6F9:
		return !any_between(cps, 0x660, 0x669)
	}
	return false
}

@(private)
any_between :: proc(cps: []rune, lo, hi: rune) -> bool {
	for r in cps {
		if r >= lo && r <= hi {
			return true
		}
	}
	return false
}

// Whether the code points `cps` of a label are a valid U-label: no hyphen at either end, no mark first, each code point
// PVALID or, with a rule in RFC 5892, in its context. `bidi` applies RFC 5893's rule, and `rtl` returns whether the label
// holds right-to-left text or Arabic-Indic digits.
@(private)
ulabel_valid :: proc(cps: []rune, bidi: bool) -> (rtl, ok: bool) {
	n := len(cps)
	if n == 0 || cps[0] == '-' || cps[n - 1] == '-' || is_mark(cps[0]) {
		return
	}
	for r, i in cps {
		p := properties_of(r)
		switch p.derived {
		case .Disallowed:
			return
		case .Pvalid:
		case .Context_J, .Context_O:
			in_context(cps, i) or_return
		}
		rtl ||= p.bidi == .R || p.bidi == .AL || p.bidi == .AN
	}
	return rtl, !bidi || bidi_valid(cps)
}

// RFC 5893 section 2 for a label of a domain that has right-to-left text.
@(private)
bidi_valid :: proc(cps: []rune) -> bool {
	first := properties_of(cps[0]).bidi
	if first != .L && first != .R && first != .AL {
		return false
	}
	numbers := bit_set[Bidi]{}
	last := first
	for r in cps {
		c := properties_of(r).bidi
		switch {
		case first == .L && (c == .R || c == .AL || c == .AN):
			return false
		case first != .L && c == .L:
			return false
		}
		if c != .NSM {
			last = c
		}
		numbers += {c} & {.EN, .AN}
	}
	if first == .L {
		return last == .L || last == .EN
	}
	return numbers != {.EN, .AN} && (last == .R || last == .AL || last == .EN || last == .AN)
}
