package yaml

import "base:intrinsics"
import "stury:lib/base/kernel"

// Classifies the text's bytes 64 at a time via `stury:lib/base/kernel` and locates token boundaries.

@(private)
RUN_TIER :: kernel.Tier(0)

@(private)
RUN_FEATURES :: kernel.FEATURES[RUN_TIER]

@(private)
Masks :: struct {
	at:    u64,
	brk:   u64, // `\n` and `\r`
	space: u64,
	tab:   u64,
	colon: u64,
	hash:  u64,
	flow:  u64, // `,`, `[`, `]`, `{` and `}`
	quote: u64, // `'`, `"` and `\`
	judge: u64, // a byte past ASCII, a control byte other than a tab or a line break, and DEL
	end:   u64, // the lanes past the text's end
}

@(private)
NO_BLOCK :: max(u64)

// Returns the masks of the 64-byte block holding byte `i`.
@(private)
masks_at :: #force_inline proc "contextless" (p: ^Parser, i: u64) -> ^Masks {
	if p.masks.at != i &~ 63 {
		classify_block(p, i &~ 63)
	}
	return &p.masks
}

@(private, enable_target_feature = RUN_FEATURES)
classify_block :: proc "contextless" (p: ^Parser, at: u64) #no_bounds_check {
	src := p.src
	n := u64(len(src))
	b: kernel.Block
	end: u64
	if at + 64 <= n {
		b = kernel.load(raw_data(src)[at:])
	} else {
		b = kernel.load_padded(src, int(at))
		end = max(u64) << (n - at)
	}
	eq :: kernel.eq
	or :: kernel.either
	x := kernel.pack_n([4]kernel.Block{or(eq(b, '\n'), eq(b, '\r')), eq(b, ' '), eq(b, '\t'), eq(b, ':')})
	y := kernel.pack_n([4]kernel.Block{
		eq(b, '#'),
		or(or(eq(b, ','), eq(b, '[')), or(or(eq(b, ']'), eq(b, '{')), eq(b, '}'))),
		or(or(eq(b, '\''), eq(b, '"')), eq(b, '\\')),
		kernel.below(b, 0x20),
	})
	z := kernel.pack_n([2]kernel.Block{eq(b, 0x7f), kernel.below(b, 0x80)})
	p.masks = Masks {
		at    = at,
		brk   = x[0],
		space = x[1],
		tab   = x[2],
		colon = x[3],
		hash  = y[0],
		flow  = y[1],
		quote = y[2],
		judge = (y[3] &~ (x[0] | x[2]) | z[0] | ~z[1]) &~ end,
		end   = end,
	}
}

// Line breaks (plus past-end lanes) and colons in the 64-byte block starting at `at`.
@(private, enable_target_feature = RUN_FEATURES)
breaks_and_colons :: proc "contextless" (src: []u8, at: u64) -> (brk, colon: u64) #no_bounds_check {
	n := u64(len(src))
	b: kernel.Block
	end: u64
	if at + 64 <= n {
		b = kernel.load(raw_data(src)[at:])
	} else {
		b = kernel.load_padded(src, int(at))
		end = max(u64) << (n - at)
	}
	m := kernel.pack_n([2]kernel.Block{kernel.either(kernel.eq(b, '\n'), kernel.eq(b, '\r')), kernel.eq(b, ':')})
	return m[0] | end, m[1] &~ end
}

// Lanes before the lowest set bit of `m`, or all bits when `m` is 0.
@(private)
before_first :: #force_inline proc "contextless" (m: u64) -> u64 {
	return (m & (~m + 1)) - 1
}

@(private)
lane :: #force_inline proc "contextless" (m: u64) -> u64 {
	return u64(intrinsics.count_trailing_zeros(m))
}

// Returns the first byte at or after `i` in one of `stops(m)`, or `len(p.src)`, validating any `judge` bytes passed,
// and whether every passed byte before the stop is ASCII (< 0x80).
@(private)
run_to :: #force_inline proc "contextless" (p: ^Parser, i: u64, $stops: proc "contextless" (m: ^Masks) -> u64) -> (at: u64, ascii, ok: bool) #no_bounds_check {
	n := u64(len(p.src))
	i := i
	ascii = true
	for i < n {
		base := i &~ 63
		m := masks_at(p, i)
		live := ~u64(0) << (i - base)
		s := (stops(m) | m.end) & live
		if judge := m.judge & live & before_first(s); judge != 0 {
			ascii = false
			i = step(p, base + lane(judge)) or_return
			continue
		}
		if s != 0 {
			return min(base + lane(s), n), ascii, true
		}
		i = base + 64
	}
	return n, ascii, true
}

@(private)
line_end :: proc "contextless" (p: ^Parser, i: u64) -> (u64, bool) {
	at, _, ok := run_to(p, i, proc "contextless" (m: ^Masks) -> u64 {return m.brk})
	return at, ok
}

@(private)
quote_end :: proc "contextless" (p: ^Parser, i: u64) -> (u64, bool, bool) {
	return run_to(p, i, proc "contextless" (m: ^Masks) -> u64 {return m.quote | m.brk})
}

@(private)
past_quoted :: proc "contextless" (p: ^Parser, i: u64) -> (at: u64, ascii, ok: bool) #no_bounds_check {
	lead_ascii := p.src[i] < 0x80
	j := step(p, i) or_return
	tail_ascii: bool
	at, tail_ascii, ok = quote_end(p, j)
	return at, lead_ascii && tail_ascii, ok
}

@(private)
skip_spaces :: proc "contextless" (p: ^Parser, i: u64) -> u64 #no_bounds_check {
	n := u64(len(p.src))
	i := i
	for i < n {
		base := i &~ 63
		m := masks_at(p, i)
		if rest := ~m.space & (~u64(0) << (i - base)); rest != 0 {
			return min(base + lane(rest), n)
		}
		i = base + 64
	}
	return min(i, n)
}

@(private)
plain_word :: #force_inline proc "contextless" (p: ^Parser, from: u64, flow: bool) -> (at: u64, eol, ends: bool) #no_bounds_check {
	src := p.src
	n := u64(len(src))
	for i := from; i < n; i += 1 {
		c := src[i]
		if c > ' ' && c < 0x7f && c != ':' && !(flow && is_flow_indicator(c)) {
			continue
		}
		switch {
		case is_break(c):
			return i, true, true
		case c == ':':
			if is_space_at(p, i + 1) || flow && is_flow_indicator(src[i + 1]) {
				return i, false, true
			}
		case flow && is_flow_indicator(c):
			return i, false, true
		case:
			return i, false, false
		}
	}
	return n, true, true
}

@(private)
scan_plain_line :: proc "contextless" (p: ^Parser, from: u64, flow: bool) -> (stop, last: u64, eol, ascii, ok: bool) #no_bounds_check {
	i := from
	last = from
	if at, at_eol, ends := plain_word(p, from, flow); ends {
		return at, at, at_eol, true, true
	} else if at > from {
		i, last = at, at
	}
	src := p.src
	n := u64(len(src))
	ascii = true
	for i < n {
		base := i &~ 63
		m := masks_at(p, i)
		live := ~u64(0) << (i - base)
		white := m.space | m.tab
		next_sep, next_flow := true, false
		if base + 64 < n {
			c := src[base + 64]
			next_sep, next_flow = is_white(c) || is_break(c), is_flow_indicator(c)
		}
		after := (m.brk | white | m.end) >> 1 | (u64(1) << 63 if next_sep else 0)
		if flow {
			after |= m.flow >> 1 | (u64(1) << 63 if next_flow else 0)
		}
		passed := white << 1
		if base > from && is_white(src[base - 1]) {
			passed |= 1
		}
		if from >= base {
			passed &~= u64(1) << (from - base)
		}
		s := (m.brk | m.end | m.colon & after | m.hash & passed | (m.flow if flow else 0)) & live
		before := before_first(s)
		if judge := m.judge & live & before; judge != 0 {
			ascii = false
			k := base + lane(judge)
			if text := ~white & live & (u64(1) << (k - base) - 1); text != 0 {
				last = base + 64 - u64(intrinsics.count_leading_zeros(text))
			}
			i = step(p, k) or_return
			last = i
			continue
		}
		if text := ~white & live & before; text != 0 {
			last = base + 64 - u64(intrinsics.count_leading_zeros(text))
		}
		if s != 0 {
			at := base + lane(s)
			if at >= n {
				return n, last, true, ascii, true
			}
			return at, last, m.brk >> (at - base) & 1 != 0, ascii, true
		}
		i = base + 64
	}
	return n, last, true, ascii, true
}
