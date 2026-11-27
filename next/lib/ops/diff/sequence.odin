package diff

import "stury:lib/core/tape"

// Iterative Myers longest-common-subsequence algorithm in linear space: finds the middle snake of the edit graph and
// splits each subproblem onto a fixed stack (zero native recursion). Elements are compared by memoized hash first and
// by exact equality on hash match. Bounded by `max_edits` and `Differ.work`.

@(private = "file")
Span_Task :: struct {
	x0, x1, y0, y1: int,
}

@(private = "file")
Sequence :: struct {
	d:                 ^Differ,
	xs, ys:            []tape.Node_Index,
	hx, hy:            []u64,
	forward, backward: []int,
	from:              int,
	edit_cap, found:   int,
	depth:             int,
}

@(private, require_results)
sequence_edits :: proc(d: ^Differ, xs, ys: []tape.Node_Index, depth: int) -> (removed, added: []bool, ok: bool, err: Error) {
	edit_cap := d.opts.max_edits
	if d.work < 0 || abs(len(xs) - len(ys)) > edit_cap {
		return nil, nil, false, nil
	}
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
	if d.scratch_gate.failed {
		return nil, nil, false, .Out_Of_Memory
	}
	s := Sequence {
		d        = d,
		xs       = xs,
		ys       = ys,
		hx       = hx,
		hy       = hy,
		edit_cap = edit_cap,
		depth    = depth + 1,
	}

	// Each middle-snake split halves edit distance `D`, so stack depth is at most `ceil(log2(D)) + 2 < 64`.
	stack: [64]Span_Task = ---
	sp := 1
	stack[0] = {0, len(xs), 0, len(ys)}
	for sp > 0 {
		sp -= 1
		t := stack[sp]
		x0, x1, y0, y1 := t.x0, t.x1, t.y0, t.y1
		for x0 < x1 && y0 < y1 && seq_same(&s, x0, y0) {
			x0, y0 = x0 + 1, y0 + 1
		}
		for x0 < x1 && y0 < y1 && seq_same(&s, x1 - 1, y1 - 1) {
			x1, y1 = x1 - 1, y1 - 1
		}
		if d.scratch_gate.failed {
			return nil, nil, false, .Out_Of_Memory
		}
		switch {
		case x0 == x1:
			for j in y0 ..< y1 {
				add[j] = true
			}
			s.found += y1 - y0
			if s.found > s.edit_cap {
				return nil, nil, false, nil
			}
		case y0 == y1:
			for i in x0 ..< x1 {
				rem[i] = true
			}
			s.found += x1 - x0
			if s.found > s.edit_cap {
				return nil, nil, false, nil
			}
		case:
			if s.forward == nil {
				room := (min((x1 - x0) + (y1 - y0), edit_cap) + 1) / 2 + 1
				stride := 2 * room + 1
				buf := make([]int, 2 * stride, d.scratch) or_return
				s.forward = buf[:stride]
				s.backward = buf[stride:]
				s.from = room
			}
			mx, my, mid_ok := seq_middle(&s, x0, x1, y0, y1)
			if d.scratch_gate.failed {
				return nil, nil, false, .Out_Of_Memory
			}
			if !mid_ok {
				return nil, nil, false, nil
			}
			// Push right half first so left half processes first.
			stack[sp] = {mx, x1, my, y1}
			stack[sp + 1] = {x0, mx, y0, my}
			sp += 2
		}
	}
	return rem, add, true, nil
}

// Invariant: `0 <= i < len(s.xs) == len(s.hx)` and `0 <= j < len(s.ys) == len(s.hy)`.
@(private = "file")
seq_same :: #force_inline proc(s: ^Sequence, i, j: int) -> bool #no_bounds_check {
	s.d.work -= 1
	return s.hx[i] == s.hy[j] && vals_equal_exact(s.d, val_node(s.xs[i]), val_node(s.ys[j]), s.depth)
}

// Invariant: `0 <= x0 < x1 <= len(s.xs)`, `0 <= y0 < y1 <= len(s.ys)`, `s.from >= most + 1`, and
// `len(s.forward) == len(s.backward) >= 2 * s.from + 1`.
@(private = "file", require_results)
seq_middle :: proc(s: ^Sequence, x0, x1, y0, y1: int) -> (x, y: int, ok: bool) #no_bounds_check {
	n, m := x1 - x0, y1 - y0
	delta := n - m
	budget := min(s.edit_cap - s.found, n + m)
	if abs(delta) > budget || budget < 2 {
		return 0, 0, false
	}
	odd := delta & 1 != 0
	most := (budget + int(odd)) / 2
	f, b, at := s.forward, s.backward, s.from
	f[at + 1], b[at + 1] = 0, 0
	for d in 0 ..= most {
		if s.d.work < 0 || s.d.scratch_gate.failed {
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
