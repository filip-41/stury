package json

// A text's spine, the array that holds its bulk, cut at its commas into runs of entries (pieces), each framed in
// brackets as an array of its own. `validate` and a `.Nodes` or `.Dom` scan with no paths (`build`) read a large text
// in its pieces on a runner's threads, and every other reading of it on one thread. `pieces_run.odin` runs them.

import "base:runtime"
import core_pkg "../core"
import scan_pkg "scan"
import index_pkg "scan/index"

// A piece of a split: the entries src[lo:hi], whole, from past the container's open byte or a separator to the
// next separator or the container's close byte.
Piece :: struct {
	lo, hi: int,
}

// The most keyed containers a spine's container sits in.
SPINE_LEVELS :: 4

// Where a text's bulk is: the container src[lo:z + 1], from its open byte to its close byte, the root or the member
// `keys[i]` of each of `levels` containers around it, the members beside it few and small. Found from the framing
// alone: the text may still be malformed, and a key repeated after the spine's may name another value.
Spine :: struct {
	lo, z:  int,
	levels: int,
	keys:   [SPINE_LEVELS]string, // each a key of printable ASCII and no escape, which is its own text
}

// `src`'s spine, past a byte order mark and whitespace: the root array, or the array a root object holds up to
// `SPINE_LEVELS` objects deep beside members whose values span at most SIDE_BYTES each, at most SIDE_MEMBERS on
// either side in each object. False when it has none. Allocates nothing.
find_spine :: proc(src: []byte) -> (s: Spine, ok: bool) {
	at := scan_pkg.skip_space(src, scan_pkg.bom_len(src))
	z := scan_pkg.skip_space_back(src, at, len(src)) - 1
	if z <= at {
		return
	}
	if src[at] == '[' {
		return {lo = at, z = z}, src[z] == ']'
	}
	if src[at] != '{' || src[z] != '}' {
		return
	}
	s.lo = spine_open(src, at, z, &s) or_return
	s.z = spine_close(src, s.lo, z, s.levels) or_return
	return s, true
}

// The most bytes a member beside the spine spans, and the most such members on either side of it in each object.
@(private = "file")
SIDE_BYTES :: 4096
@(private = "file")
SIDE_MEMBERS :: 16

// The `[` of the spine array of the root object src[at:z + 1]: the first member, of the root or of an object the
// spine goes through, whose value does not end within SIDE_BYTES and opens an array (or an object to go into), its
// key and those above it put in `s`. False when there is none, or it has SIDE_MEMBERS before it.
@(private = "file")
spine_open :: proc(src: []byte, at, z: int, s: ^Spine) -> (lo: int, ok: bool) {
	k := at
	for s.levels < SPINE_LEVELS {
		// src[k] opens an object.
		for n := 0; ; n += 1 {
			k = scan_pkg.skip_space(src[:z], k + 1)
			if n == SIDE_MEMBERS || src[k] != '"' {
				return
			}
			key_lo, plain := k + 1, true
			for k += 1; k < z && src[k] != '"'; k += 1 {
				plain &&= src[k] >= 0x20 && src[k] < 0x7f && src[k] != '\\'
				if src[k] == '\\' {
					k += 1
				}
			}
			key_hi := k
			k = scan_pkg.skip_space(src[:z], k + 1)
			if src[k] != ':' {
				return
			}
			k = scan_pkg.skip_space(src[:z], k + 1)
			// A value that ends within SIDE_BYTES is a member beside the spine, or the object's last.
			commas := index_pkg.comma_cursor(k)
			if end := index_pkg.next_top_comma_or_close(&commas, src[:min(k + SIDE_BYTES, z)]); end >= 0 {
				if src[end] != ',' {
					return
				}
				k = end
				continue
			}
			if !plain || src[k] != '[' && src[k] != '{' {
				return
			}
			s.keys[s.levels] = string(src[key_lo:key_hi])
			s.levels += 1
			if src[k] == '[' {
				return k, true
			}
			break
		}
	}
	return
}

// The `]` of the spine array opening at src[lo], `levels` objects into the root object closing at src[z]: found
// from the back, past each object's members after the spine's, SIDE_MEMBERS of SIDE_BYTES each at most. False
// when the text does not end so. From the back the quotes are known: the text ends outside a string.
@(private = "file")
spine_close :: proc(src: []byte, lo, z, levels: int) -> (close: int, ok: bool) {
	p := z
	for level in 0 ..< levels {
		// src[p] closes an object. The spine's member is the first from the back whose value does not open within
		// SIDE_BYTES.
		for n := 0; ; n += 1 {
			p = back_space(src, p - 1, lo)
			floor := max(lo, p - SIDE_BYTES)
			first := p // the member's value's first byte
			switch src[p] {
			case '}', ']':
				first = back_open(src, p, floor)
			case '"':
				first = back_quote(src, p, floor)
			case:
				for first > floor && !scan_pkg.is_space(src[first - 1]) && src[first - 1] != ':' {
					first -= 1
				}
			}
			if first < 0 && (src[p] == '}' || src[p] == ']') {
				if src[p] != (']' if level == levels - 1 else '}') {
					return
				}
				break
			}
			if n == SIDE_MEMBERS || first < 0 {
				return
			}
			p = back_space(src, first - 1, lo)
			if src[p] != ':' {
				return
			}
			p = back_space(src, p - 1, lo)
			if src[p] != '"' {
				return
			}
			p = back_quote(src, p, max(lo, p - SIDE_BYTES))
			if p < 0 {
				return
			}
			p = back_space(src, p - 1, lo)
			if src[p] != ',' {
				return
			}
		}
	}
	return p, p > lo
}

@(private = "file")
back_space :: proc(src: []byte, p, lo: int) -> int {
	p := p
	for p > lo && scan_pkg.is_space(src[p]) {
		p -= 1
	}
	return p
}

// Where the container closing at src[p] opens, at `floor` or past, -1 when it opens before.
@(private = "file")
back_open :: proc(src: []byte, p, floor: int) -> int {
	depth := 0
	for q := p; q >= floor; q -= 1 {
		switch src[q] {
		case '"':
			q = back_quote(src, q, floor)
			if q < 0 {
				return -1
			}
		case ']', '}':
			depth += 1
		case '[', '{':
			depth -= 1
			if depth == 0 {
				return q
			}
		}
	}
	return -1
}

// Where the string closing at src[q] opens, at `floor` or past, -1 when it opens before.
@(private = "file")
back_quote :: proc(src: []byte, q, floor: int) -> int {
	for k := q - 1; k >= floor; k -= 1 {
		if src[k] != '"' {
			continue
		}
		backslashes := 0
		for j := k - 1; j >= 0 && src[j] == '\\'; j -= 1 {
			backslashes += 1
		}
		if backslashes % 2 == 0 {
			return k
		}
	}
	return -1
}

// The array src[lo:hi] cut where `each_record` cuts its entries into pieces on `runner`'s threads, in source order,
// in `allocator`. False, with none, when it is no plain JSON array, or a cut would not pay: too small for `runner`,
// or one entry holds most of it.
split_array :: proc(src: []byte, lo, hi: int, runner: ^Batch_Runner, allocator: runtime.Allocator) -> (pieces: []Piece, ok: bool) {
	n := hi - lo
	if n < 2 || src[lo] != '[' || src[hi - 1] != ']' || core_pkg.batch_lanes(runner, n) < 2 {
		return
	}
	// No top-level comma in the first quarter: one entry holds most of the array, and finding the cuts would cost
	// about as much as reading it. A close before the first comma ends the array before src[hi - 1], which is
	// then another text's.
	commas := index_pkg.comma_cursor(lo + 1)
	if first := index_pkg.next_top_comma_or_close(&commas, src[:lo + 1 + n / 4]); first < 0 || src[first] != ',' {
		return
	}
	// A piece number is a claim's, and a claim takes at least one slice.
	cut := Cut{lo = lo}
	aerr: runtime.Allocator_Error
	cut.pieces, aerr = make([]Piece, core_pkg.batch_slices(n), allocator)
	if aerr != nil {
		return
	}
	context.allocator = allocator
	if each_record(src[lo:hi], cut_piece, &cut, {framing = .Root_Entries}, runner) != nil {
		delete(cut.pieces, allocator)
		return
	}
	// A piece holding nearly all of the array takes about as long as the whole would, so the others would only add.
	k, widest := 0, 0
	for p in cut.pieces {
		if p.hi > p.lo {
			cut.pieces[k] = p
			k += 1
			widest = max(widest, p.hi - p.lo)
		}
	}
	if k < 2 || widest > n / 10 * 9 {
		delete(cut.pieces, allocator)
		return
	}
	return cut.pieces[:k], true
}

@(private = "file")
Cut :: struct {
	lo:     int,
	pieces: []Piece,
}

// A piece's entries, from the first to its last comma or the array's close, at its number.
@(private = "file")
cut_piece :: proc(cut: ^Cut, piece: ^Records, k: int) -> bool {
	if piece.pos <= piece.end {
		cut.pieces[k] = {cut.lo + piece.pos, cut.lo + piece.end}
	}
	return true
}

// Piece `p` framed into `buf` as a text of its own: `[`, the piece's entries, `]`, so `text[0]` stands for the
// array's `[` and `text[i]` is `src[shift + i]` for each byte of the entries. A piece read under `Limits` with as
// many levels less as objects hold the array reads as the whole text would. False when the piece holds no entry.
frame_entries :: proc(src: []byte, p: Piece, buf: ^[dynamic]byte) -> (text: []byte, shift: int, ok: bool) {
	if scan_pkg.skip_space(src[:p.hi], p.lo) == p.hi || non_zero_resize(buf, p.hi - p.lo + 2) != nil {
		return
	}
	buf[0], buf[len(buf) - 1] = '[', ']'
	copy(buf[1:], src[p.lo:p.hi])
	return buf[:], p.lo - 1, true
}

// Whether `src`, a plain JSON text, validates in its spine's pieces on `runner`'s threads: the members beside the
// spine's array once, the array's pieces each. False when it has no spine to cut or a piece fails, which says
// nothing of the text.
@(private)
pieces_valid :: #force_no_inline proc(src: []byte, opts: Read_Opts, runner: ^Batch_Runner) -> bool {
	s := find_spine(src) or_return
	own := opts
	own.limits.max_depth = (opts.limits.max_depth if opts.limits.max_depth > 0 else MAX_DEPTH) - u64(s.levels)
	if own.limits.max_depth == 0 {
		return false
	}
	pieces := split_array(src, s.lo, s.z + 1, runner, context.allocator) or_return
	defer delete(pieces)
	if s.levels > 0 && !shell_valid(src, s, opts) {
		return false
	}
	return pieces_pass(src, pieces, check_piece, &own, runner)
}

// Whether `src` with its spine's array read as `[]` validates.
@(private = "file")
shell_valid :: proc(src: []byte, s: Spine, opts: Read_Opts) -> bool {
	shell := make([dynamic]byte, 0, s.lo + 1 + len(src) - s.z)
	defer delete(shell)
	append(&shell, ..src[:s.lo + 1])
	append(&shell, ..src[s.z:])
	return len(shell) == s.lo + 1 + len(src) - s.z && validate_facts(shell[:], opts, nil) == nil
}

@(private = "file")
check_piece :: proc(opts: ^Read_Opts, text: []byte) -> Maybe(Error) {
	return validate_facts(text, opts^, nil)
}

// `src`'s document built in the pieces of its root array on `runner`'s threads, into `doc`: the rows one build
// gives. False, with `doc` untouched, when it has no root array to cut or a piece fails, which says nothing of the
// text.
@(private)
build_pieces :: #force_no_inline proc(src: []byte, opts: Read_Opts, runner: ^Batch_Runner, allocator: runtime.Allocator, doc: ^Document) -> bool {
	if !scan_pkg.plain_json(opts.dialect) || u64(len(src)) > MAX_ROW_SOURCE {
		return false
	}
	s := find_spine(src) or_return
	if s.levels > 0 {
		return false
	}
	pieces := split_array(src, s.lo, s.z + 1, runner, allocator) or_return
	defer delete(pieces, allocator)
	own := opts
	doc^ = pieces_build(src, s.lo, s.z + 1, pieces, build_piece, &own, runner, allocator) or_return
	return true
}

@(private = "file")
build_piece :: proc(opts: ^Read_Opts, text: []byte) -> (doc: Document, err: Maybe(Error)) {
	return build(text, opts^, runtime.heap_allocator())
}
