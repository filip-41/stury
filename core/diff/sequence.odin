package diff

import core ".."

// The elements of `xs` and `ys` outside a longest common subsequence, found by Myers' algorithm in linear space: the
// middle snake of the edit graph splits the problem in two, and only the endpoints of the furthest paths are kept. Elements
// are compared by hash first and by `core.equal` on a hash match. `ok` is false when the sequences differ by more than the
// edits the options allow, or when the steps left of the diff's work run out.
@(private)
edits :: proc(d: ^Differ, xs, ys: []core.Value) -> (removed, added: []bool, ok: bool) {
	cap := d.opts.max_edits
	s := Sequence {
		d       = d,
		xs      = xs,
		ys      = ys,
		hx      = hashes(d, xs),
		hy      = hashes(d, ys),
		removed = make([]bool, len(xs), context.temp_allocator),
		added   = make([]bool, len(ys), context.temp_allocator),
		cap     = cap,
	}
	// A path of `cap` edits reaches the diagonals -cap to cap and no others.
	room := min((len(xs) + len(ys) + 1) / 2, cap) + 3
	s.from = room
	s.forward = make([]int, 2 * room + 3, context.temp_allocator)
	s.backward = make([]int, 2 * room + 3, context.temp_allocator)
	s.found = 0
	ok = divide(&s, 0, len(xs), 0, len(ys))
	return s.removed, s.added, ok && s.found <= cap
}

@(private = "file")
Sequence :: struct {
	d:                  ^Differ,
	xs, ys:             []core.Value,
	hx, hy:             []u64,
	removed, added:     []bool,
	// Diagonal `k` of the furthest forward path is `forward[from + k]`, and likewise backward.
	forward, backward:  []int,
	from:               int,
	cap, found:         int,
}

@(private = "file")
hashes :: proc(d: ^Differ, vs: []core.Value) -> []u64 {
	out := make([]u64, len(vs), context.temp_allocator)
	for v, i in vs {
		out[i] = hash_of(d, v)
	}
	return out
}

@(private = "file")
same :: #force_inline proc(s: ^Sequence, i, j: int) -> bool {
	s.d.work -= 1
	return s.hx[i] == s.hy[j] && core.equal(s.xs[i], s.ys[j])
}

// Marks the elements of `xs[x0:x1]` and `ys[y0:y1]` that no longest common subsequence keeps. False when a part needs more
// edits than the cap.
@(private = "file")
divide :: proc(s: ^Sequence, x0, x1, y0, y1: int) -> bool {
	x0, x1, y0, y1 := x0, x1, y0, y1
	for x0 < x1 && y0 < y1 && same(s, x0, y0) {
		x0, y0 = x0 + 1, y0 + 1
	}
	for x0 < x1 && y0 < y1 && same(s, x1 - 1, y1 - 1) {
		x1, y1 = x1 - 1, y1 - 1
	}
	switch {
	case x0 == x1:
		for j in y0 ..< y1 {
			s.added[j] = true
		}
		s.found += y1 - y0
		return s.found <= s.cap
	case y0 == y1:
		for i in x0 ..< x1 {
			s.removed[i] = true
		}
		s.found += x1 - x0
		return s.found <= s.cap
	}
	x, y, ok := middle(s, x0, x1, y0, y1)
	return ok && divide(s, x0, x, y0, y) && divide(s, x, x1, y, y1)
}

// The point where the furthest forward and backward paths of `xs[x0:x1]` against `ys[y0:y1]` first meet, which lies on a
// shortest edit path and splits it into two shorter ones.
@(private = "file")
middle :: proc(s: ^Sequence, x0, x1, y0, y1: int) -> (x, y: int, ok: bool) {
	n, m := x1 - x0, y1 - y0
	delta := n - m
	odd := delta & 1 != 0
	most := min((n + m + 1) / 2, s.cap) + 1
	f, b, at := s.forward, s.backward, s.from
	f[at + 1], b[at + 1] = 0, 0
	for d in 0 ..= most {
		if s.d.work < 0 {
			return 0, 0, false
		}
		for k := -d; k <= d; k += 2 {
			u := f[at + k + 1] if k == -d || (k != d && f[at + k - 1] < f[at + k + 1]) else f[at + k - 1] + 1
			v := u - k
			start_u, start_v := u, v
			for u < n && v < m && same(s, x0 + u, y0 + v) {
				u, v = u + 1, v + 1
			}
			f[at + k] = u
			if odd && k >= delta - (d - 1) && k <= delta + (d - 1) && u + b[at + delta - k] >= n {
				return x0 + start_u, y0 + start_v, true
			}
		}
		for k := -d; k <= d; k += 2 {
			u := b[at + k + 1] if k == -d || (k != d && b[at + k - 1] < b[at + k + 1]) else b[at + k - 1] + 1
			v := u - k
			for u < n && v < m && same(s, x1 - 1 - u, y1 - 1 - v) {
				u, v = u + 1, v + 1
			}
			b[at + k] = u
			if !odd && k >= delta - d && k <= delta + d && u + f[at + delta - k] >= n {
				return x1 - u, y1 - v, true
			}
		}
	}
	return 0, 0, false
}
