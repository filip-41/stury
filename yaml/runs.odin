package yaml

import "base:intrinsics"
import kernel "../core/kernel"

// The walk sorts the text's bytes into classes 64 at a time, once per block, and its readers find where a run ends from
// the block's masks. A reader judges every byte it passes: the bytes of a block that `judge` marks go through `step`,
// which judges the characters past ASCII and refuses a control byte, and every other byte is allowed.

@(private)
RUN_TIER :: kernel.Tier(0)
@(private)
RUN_FEATURES :: kernel.FEATURES[RUN_TIER]

// The classes of the 64 bytes of the text from `at`, a multiple of 64, one bit per byte.
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

// Returns the masks of the block that holds byte `i`, which is inside the text.
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
		b, end = kernel.load_padded(RUN_TIER, src, int(at)), max(u64) << (n - at)
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

// The line breaks, with the lanes past the text's end, and the colons of the 64 bytes from `at`, leaving the block the
// readers hold in place.
@(private, enable_target_feature = RUN_FEATURES)
breaks_and_colons :: proc "contextless" (src: []u8, at: u64) -> (brk, colon: u64) #no_bounds_check {
	n := u64(len(src))
	b: kernel.Block
	end: u64
	if at + 64 <= n {
		b = kernel.load(raw_data(src)[at:])
	} else {
		b, end = kernel.load_padded(RUN_TIER, src, int(at)), max(u64) << (n - at)
	}
	m := kernel.pack_n([2]kernel.Block{kernel.either(kernel.eq(b, '\n'), kernel.eq(b, '\r')), kernel.eq(b, ':')})
	return m[0] | end, m[1] &~ end
}

// The lanes before the lowest set bit of `m`, all of them when `m` is 0.
@(private)
before_first :: #force_inline proc "contextless" (m: u64) -> u64 {
	return (m & (~m + 1)) - 1
}

@(private)
lane :: #force_inline proc "contextless" (m: u64) -> u64 {
	return u64(intrinsics.count_trailing_zeros(m))
}

// Returns the first byte at or after `i` in one of the classes `stops` picks from a block's masks, or the text's end,
// having judged every byte before it.
@(private)
run_to :: #force_inline proc "contextless" (p: ^Parser, i: u64, $stops: proc "contextless" (m: ^Masks) -> u64) -> (at: u64, ok: bool) #no_bounds_check {
	n := u64(len(p.src))
	i := i
	for i < n {
		base := i &~ 63
		m := masks_at(p, i)
		live := ~u64(0) << (i - base)
		s := (stops(m) | m.end) & live
		if judge := m.judge & live & before_first(s); judge != 0 {
			i = step(p, base + lane(judge)) or_return
			continue
		}
		if s != 0 {
			return min(base + lane(s), n), true
		}
		i = base + 64
	}
	return n, true
}

// Returns the first byte at or after `i` that is a line break, or the text's end, having judged every byte before it.
@(private)
line_end :: proc "contextless" (p: ^Parser, i: u64) -> (u64, bool) {
	return run_to(p, i, proc "contextless" (m: ^Masks) -> u64 {return m.brk})
}

// Returns the first byte at or after `i` that is a quote, a backslash or a line break, or the text's end, having
// judged every byte before it.
@(private)
quote_end :: proc "contextless" (p: ^Parser, i: u64) -> (u64, bool) {
	return run_to(p, i, proc "contextless" (m: ^Masks) -> u64 {return m.quote | m.brk})
}

// Moves past the character at `i` in a quoted scalar and the bytes after it up to a quote, a backslash or a line break.
@(private)
past_quoted :: proc "contextless" (p: ^Parser, i: u64) -> (at: u64, ok: bool) {
	j := step(p, i) or_return
	return quote_end(p, j)
}

// Returns the first byte at or after `i` that is not a space.
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

// Moves over the printable ASCII bytes from `from` other than white space and returns where a plain scalar of them ends:
// a line break, the end, a `:` before white space, and in `flow` a flow indicator or a `:` before one. `ends` is false
// where the scalar may go on past a byte the run does not take.
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

// Scans the rest of a plain scalar's line from `from`. Returns where it stopped, the end of its last character and
// whether it stopped at the line end. A `:` stops it before white space, a line break or the end, and before a flow
// indicator in `flow`, a `#` after white space it passed, and a flow indicator in `flow`.
@(private)
scan_plain_line :: proc "contextless" (p: ^Parser, from: u64, flow: bool) -> (stop, last: u64, eol: bool, ok: bool) #no_bounds_check {
	if at, at_eol, ends := plain_word(p, from, flow); ends {
		return at, at, at_eol, true
	}
	src := p.src
	n := u64(len(src))
	i := from
	last = from
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
				return n, last, true, true
			}
			return at, last, m.brk >> (at - base) & 1 != 0, true
		}
		i = base + 64
	}
	return n, last, true, true
}
