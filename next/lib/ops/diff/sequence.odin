package diff

import "stury:lib/core/tape"

// Iterative Myers longest-common-subsequence algorithm in linear space: finds the middle snake of the edit graph and
// splits each subproblem onto an explicit heap stack (zero native recursion). Elements are compared by memoized hash
// first and by exact equality on hash match. Bounded by `max_edits` and `Differ.work`.

@(private = "file")
Span_Task :: struct {
	x0, x1, y0, y1: int,
}

@(private = "file")
Sequence :: struct {
	d:                 ^Differ,
	xs, ys:            []tape.Node_Index,
	hx, hy:            []u64,
	removed, added:    []bool,
	forward, backward: []int,
	from:              int,
	cap, found:        int,
	depth:             int,
}

@(private)
sequence_edits :: proc(d: ^Differ, xs, ys: []tape.Node_Index, depth: int) -> (removed, added: []bool, ok: bool, err: Error) {
	hx := make([]u64, len(xs), d.scratch) or_return
	hy := make([]u64, len(ys), d.scratch) or_return
	rem := make([]bool, len(xs), d.scratch) or_return
	add := make([]bool, len(ys), d.scratch) or_return
	for x, i in xs {
		hx[i] = hash_node(d, 0, x, depth + 1)
	}
	for y, j in ys {
		hy[j] = hash_node(d, 1, y, depth + 1)
	}
	cap := d.opts.max_edits
	room := min((len(xs) + len(ys) + 1) / 2, cap) + 3
	fwd := make([]int, 2 * room + 3, d.scratch) or_return
	bwd := make([]int, 2 * room + 3, d.scratch) or_return
	s := Sequence {
		d        = d,
		xs       = xs,
		ys       = ys,
		hx       = hx,
		hy       = hy,
		removed  = rem,
		added    = add,
		forward  = fwd,
		backward = bwd,
		from     = room,
		cap      = cap,
		depth    = depth + 1,
	}

	stack := make([dynamic]Span_Task, 0, 32, d.scratch) or_return
	defer delete(stack)
	append(&stack, Span_Task{0, len(xs), 0, len(ys)}) or_return
	for len(stack) > 0 {
		t := pop(&stack)
		x0, x1, y0, y1 := t.x0, t.x1, t.y0, t.y1
		for x0 < x1 && y0 < y1 && seq_same(&s, x0, y0) {
			x0, y0 = x0 + 1, y0 + 1
		}
		for x0 < x1 && y0 < y1 && seq_same(&s, x1 - 1, y1 - 1) {
			x1, y1 = x1 - 1, y1 - 1
		}
		switch {
		case x0 == x1:
			for j in y0 ..< y1 {
				s.added[j] = true
			}
			s.found += y1 - y0
			if s.found > s.cap {
				return s.removed, s.added, false, nil
			}
		case y0 == y1:
			for i in x0 ..< x1 {
				s.removed[i] = true
			}
			s.found += x1 - x0
			if s.found > s.cap {
				return s.removed, s.added, false, nil
			}
		case:
			mx, my, mid_ok := seq_middle(&s, x0, x1, y0, y1)
			if !mid_ok {
				return s.removed, s.added, false, nil
			}
			// Push right half first so left half processes first.
			append(&stack, Span_Task{mx, x1, my, y1}) or_return
			append(&stack, Span_Task{x0, mx, y0, my}) or_return
		}
	}
	return s.removed, s.added, s.found <= s.cap, nil
}

@(private = "file")
seq_same :: #force_inline proc(s: ^Sequence, i, j: int) -> bool #no_bounds_check {
	s.d.work -= 1
	return s.hx[i] == s.hy[j] && nodes_equal_exact(s.d, s.xs[i], s.ys[j], s.depth)
}

@(private = "file")
seq_middle :: proc(s: ^Sequence, x0, x1, y0, y1: int) -> (x, y: int, ok: bool) #no_bounds_check {
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
			for u < n && v < m && seq_same(s, x0 + u, y0 + v) {
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
			for u < n && v < m && seq_same(s, x1 - 1 - u, y1 - 1 - v) {
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
