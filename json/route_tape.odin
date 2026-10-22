package json

// The tape route: a `.Strict` request of two or more gated columns under one gate (`.logs[].status` and
// `.logs[].id`) builds the rows (`.Nodes`) and walks them, since past a point the demand matcher's
// per-member hooks cost more than the build plus a walk that skips every subtree the gate rules out. The
// answers are the matcher's. What the walk cannot settle (a document fault, an escaped key) goes to the scan.

import "base:runtime"
import core_pkg "../core"

@(private = "file")
TAPE_MAX_PATHS :: core_pkg.MAX_PATH_QUERIES

// Whether `req` is one the tape route answers: at least two gated columns sharing one gate, on `.Strict`
// JSON. One path loses to the scan, so it is not routed.
@(private)
tape_routable :: proc(req: ^Request($Q)) -> bool {
	when Q != {.Path} {
		return false
	}
	if FORCE_AUTOMATON || req.strictness != .Strict || req.dialect != .Json || req.duplicates == .Refuse ||
	   req.limits.max_depth > MAX_DEPTH || len(req.paths) < 2 || len(req.paths) > TAPE_MAX_PATHS {
		return false
	}
	return all_gated(req.paths)
}

@(private = "file")
Tape_Walk :: struct {
	rows:    []core_pkg.Row,
	src:     []byte,
	steps:   []Step,
	mode:    Duplicates,
	// The level of the objects whose members answer: the path's step count.
	depth:   int,
	keys:    [TAPE_MAX_PATHS]string,
	n_keys:  int,
	// Bit `n` set when a key is `n` bytes long (`n < 63`, bit 63 stands for every longer). Most members
	// are rejected by their length alone.
	lens:    u64,
	answers: ^[dynamic]Path_Answer,
}

// Answer `req` from its built rows. False leaves no answers, and the caller scans.
@(private)
scan_tape :: proc(src: []byte, req: ^Request($Q), alloc: runtime.Allocator) -> bool {
	if u64(len(src)) > MAX_ROW_SOURCE {
		return false
	}
	if fault := scan_rows(src, req, alloc); fault != {} || req.verdict != nil || len(req.doc.rows) == 0 {
		return false
	}
	core_pkg.adopt_allocator(&req.answers, alloc)
	clear(&req.answers)
	w := Tape_Walk{
		rows = req.doc.rows[:], src = src, steps = req.paths[0].steps, mode = req.duplicates,
		depth = len(req.paths[0].steps), n_keys = len(req.paths), answers = &req.answers,
	}
	limited := false
	for p, i in req.paths {
		w.keys[i] = string(p.steps[len(p.steps) - 1].(Name))
		limited ||= p.limit > 0
		w.lens |= u64(1) << min(u64(len(w.keys[i])), 63)
	}
	if k := w.rows[0].kind; (k == .Array || k == .Object) && !tape_container(&w, 0, 1) {
		clear(&req.answers)
		return false
	}
	if limited {
		finish_answers(&req.answers, nil, &req.route, req.paths, false)
	}
	req.src, req.stop, req.coverage = src, nil, .Full
	req.groups.grouped = false
	return true
}

// The container at row `i`, whose members the step `level - 1` reads. False when the walk cannot answer.
@(private = "file")
tape_container :: proc(w: ^Tape_Walk, i, level: int) -> bool {
	r := w.rows[i]
	if level == w.depth {
		return r.kind != .Object || tape_members(w, i)
	}
	end := i + int(r.subtree_size)
	if name, is_name := w.steps[level - 1].(Name); is_name {
		if r.kind != .Object {
			return true
		}
		// A gate name repeated in one object resolves as a path does: the first, the last, or every one.
		last := -1
		for j := i + 1; j < end; j += int(w.rows[j].subtree_size) {
			c := w.rows[j]
			if .Key_Escaped in c.flags {
				return false
			}
			if string(w.src[c.key_lo + 1:c.key_hi - 1]) != string(name) {
				continue
			}
			last = j
			if w.mode == .Last {
				continue
			}
			if !tape_descend(w, j, level) {
				return false
			}
			if w.mode == .First {
				return true
			}
		}
		return w.mode != .Last || last < 0 || tape_descend(w, last, level)
	}
	// An `Any` step reads an object's repeated key once, which the scan route settles.
	if r.kind == .Object && w.mode != .All {
		return false
	}
	for j := i + 1; j < end; j += int(w.rows[j].subtree_size) {
		if !tape_descend(w, j, level) {
			return false
		}
	}
	return true
}

@(private = "file")
tape_descend :: #force_inline proc(w: ^Tape_Walk, j, level: int) -> bool {
	if k := w.rows[j].kind; k == .Array || k == .Object {
		return tape_container(w, j, level + 1)
	}
	return true
}

// The members of the object at row `i` that a path names, one row per match. A key repeated within the
// object resolves as the matcher does: `.First` keeps the first row, `.Last` the last in the first's place.
@(private = "file")
tape_members :: proc(w: ^Tape_Walk, i: int) -> bool {
	owner := u64(w.rows[i].lo)
	at: [TAPE_MAX_PATHS]int
	for k in 0 ..< w.n_keys {
		at[k] = -1
	}
	end := i + int(w.rows[i].subtree_size)
	#no_bounds_check for j := i + 1; j < end; j += int(w.rows[j].subtree_size) {
		c := &w.rows[j]
		if .Key_Escaped in c.flags {
			return false
		}
		klen := int(c.key_hi - c.key_lo) - 2
		if w.lens & (u64(1) << min(u64(klen), 63)) == 0 {
			continue
		}
		for k in 0 ..< w.n_keys {
			// The length is the cheap reject, so the bytes are compared only past it.
			if len(w.keys[k]) != klen || string(w.src[c.key_lo + 1:][:klen]) != w.keys[k] {
				continue
			}
			a := Path_Answer{lo = u64(c.lo), hi = u64(c.hi), owner = owner, query = u32(k), node = NO_NODE, outcome = .Found, kind = c.kind}
			if w.mode != .All && at[k] >= 0 {
				if w.mode == .Last {
					w.answers[at[k]] = a
				}
				continue
			}
			at[k] = len(w.answers)
			if !core_pkg.row_append(w.answers, a) {
				return false
			}
		}
	}
	return true
}
