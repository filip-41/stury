package json

import "base:runtime"
import "core:slice"
import "core:strings"
import core_pkg "../core"
import enc "encode"
import scan_pkg "scan"

// The JSONC geometry of the path edits (edit.odin's engine with `jsonc`, on the rows of a JSONC scan, whose
// comments move with the entries they are attached to), and the comment edits. Every result is validated as
// JSONC before it is returned.
//
// An entry's extent runs from its first `.Lead` comment (else its key, or its value in an array) to the
// last of its value, its comma and its `.Trail` comments. Removing an entry removes its extent. A new entry
// goes between extents, so no comment changes owner.

@(private)
extent_lo :: proc(doc: ^Document, r: Node) -> u64 {
	if cms := facts(doc, r); len(cms) > 0 && cms[0].place == .Lead {
		return u64(cms[0].lo)
	}
	return u64(scan_pkg.entry_lo(doc.rows[r]))
}

@(private)
extent_hi :: proc(doc: ^Document, r: Node) -> u64 {
	hi := u64(doc.rows[r].hi)
	if at, ok := comma_after(doc.src, hi); ok {
		hi = at + 1
	}
	for cm in facts(doc, r) {
		if cm.place == .Trail {
			hi = max(hi, u64(cm.hi))
		}
	}
	return hi
}

// The comma after a value ending at `pos`, past blanks and comments, if one is there.
@(private)
comma_after :: proc(src: []byte, pos: u64) -> (at: u64, ok: bool) {
	i := pos
	n := u64(len(src))
	for i < n {
		switch {
		case core_pkg.is_space(src[i]):
			i += 1
		case src[i] == '/' && i + 1 < n && src[i + 1] == '/':
			for i < n && !is_line_break(src[i]) {
				i += 1
			}
		case src[i] == '/':
			i += 2
			for i + 1 < n && !(src[i] == '*' && src[i + 1] == '/') {
				i += 1
			}
			i += 2
		case:
			return i, src[i] == ','
		}
	}
	return n, false
}

// CR is JSON whitespace, so CR, LF and CRLF each end a line, as the scanner ends a line comment.
@(private = "file")
is_line_break :: #force_inline proc(b: u8) -> bool {
	return b == '\n' || b == '\r'
}

// The start of the line holding `pos`, and whether only blanks sit before `pos` on it.
@(private = "file")
line_start :: proc(src: []byte, pos: u64) -> (ls: u64, first: bool) {
	ls = pos
	for ls > 0 && (src[ls - 1] == ' ' || src[ls - 1] == '\t') {
		ls -= 1
	}
	return ls, ls == 0 || is_line_break(src[ls - 1])
}

// Where the line break ending at line start `ls > 0` begins: a CRLF is one break.
@(private = "file")
break_before :: proc(src: []byte, ls: u64) -> u64 {
	if ls >= 2 && src[ls - 1] == '\n' && src[ls - 2] == '\r' {
		return ls - 2
	}
	return ls - 1
}

// Whether only blanks follow `pos` up to the end of its line.
@(private = "file")
line_ends :: proc(src: []byte, pos: u64) -> bool {
	i := pos
	for i < u64(len(src)) && (src[i] == ' ' || src[i] == '\t') {
		i += 1
	}
	return i == u64(len(src)) || is_line_break(src[i])
}

// The line break ending the line that holds `pos`, or the source's end.
@(private = "file")
line_end :: proc(src: []byte, pos: u64) -> u64 {
	i := pos
	for i < u64(len(src)) && !is_line_break(src[i]) {
		i += 1
	}
	return i
}

// Past the line break at `i` (a CRLF whole), or `i` itself at the source's end.
@(private = "file")
past_break :: proc(src: []byte, i: u64) -> u64 {
	n := u64(len(src))
	switch {
	case i >= n:
		return n
	case src[i] == '\r' && i + 1 < n && src[i + 1] == '\n':
		return i + 2
	}
	return i + 1
}

// The entries of container row `c`, in order, as answers with their rows, in `kids`.
@(private)
entries_of :: proc(doc: ^Document, c: Node, kids: ^[dynamic]Path_Answer) -> []Path_Answer {
	clear(kids)
	end := c + Node(doc.rows[c].subtree_size)
	for k := c + 1; k < end; k += Node(doc.rows[k].subtree_size) {
		append(kids, Path_Answer{lo = u64(doc.rows[k].lo), hi = u64(doc.rows[k].hi), owner = u64(doc.rows[c].lo), node = k})
	}
	return kids[:]
}

// `[lo, hi)` widened to drop its lines when only blanks sit before it on its first: from the line break
// before it, or, when that break ends a line comment, from its line's start through the break after it.
@(private)
own_lines :: proc(doc: ^Document, lo, hi: u64) -> (u64, u64) {
	src := doc.src
	ls, first := line_start(src, lo)
	if !first || ls == 0 {
		return lo, hi
	}
	brk := break_before(src, ls)
	for cm in doc.facts {
		if u64(cm.hi) == brk && enc.is_line_comment(src[cm.lo:cm.hi]) {
			if !line_ends(src, hi) {
				return ls, hi
			}
			return ls, past_break(src, line_end(src, hi))
		}
	}
	return brk, hi
}

@(private)
has_place :: proc(doc: ^Document, r: Node, place: Fact_Place) -> bool {
	for cm in facts(doc, r) {
		if cm.place == place {
			return true
		}
	}
	return false
}

// Whether row `r`'s extent, ending at `hi`, ends in a line comment.
@(private)
ends_in_line_comment :: proc(doc: ^Document, r: Node, hi: u64) -> bool {
	for cm in facts(doc, r) {
		if cm.place == .Trail && u64(cm.hi) == hi && enc.is_line_comment(doc.src[cm.lo:cm.hi]) {
			return true
		}
	}
	return false
}

// Whether `comment` is one JSONC comment: a `//` line with no line break, or one `/* */` block.
@(private = "file")
comment_ok :: proc(comment: string) -> bool {
	switch {
	case strings.has_prefix(comment, "//"):
		return !strings.contains_any(comment, "\r\n")
	case strings.has_prefix(comment, "/*") && strings.has_suffix(comment, "*/") && len(comment) >= 4:
		return strings.index(comment[2:], "*/") == len(comment) - 4
	}
	return false
}

// What `edit_comment` does with the comments at its place.
Comment_Op :: enum u8 {
	// Add `comment` after the comments already there. `.Inline` needs a member and `.Foot` a container
	// (`.Unplaceable` otherwise), and so does a `.Trail` after a line comment trailing the same value.
	Insert,
	Set,    // replace the comments there with `comment` (`.Not_Found` when a value has none there)
	Remove, // remove them, each with its line when it stands alone on one (`.Not_Found` when no value has one)
}

// Edit the comments at `place` on every value the path finds, as `op` says. The source is read as JSONC.
// The path is text or a `Path`, as `set`'s. A comment that is not one `//` line or one `/* */` block is
// `.Bad_Comment`. `.Remove` ignores `comment`.
@(require_results)
edit_comment :: proc(src: []byte, path: Path_Spec, place: Fact_Place, comment: string, op: Comment_Op, allocator := context.allocator) -> (out: []byte, err: Maybe(Edit_Error)) {
	watch := Refusal_Watch{backing = allocator}
	out, err = watched_comment(src, path, place, comment, op, watched(&watch))
	return unless_refused(&watch, out, err)
}

@(private = "file")
watched_comment :: proc(src: []byte, path: Path_Spec, place: Fact_Place, comment: string, op: Comment_Op, allocator: runtime.Allocator) -> (out: []byte, err: Maybe(Edit_Error)) {
	steps: [core_pkg.MAX_PATH_STEPS]Step
	p, names := edit_parse(path, steps[:], allocator) or_return
	defer delete(names, allocator)
	if op != .Remove && !comment_ok(comment) {
		return nil, Edit_Error{kind = .Bad_Comment}
	}
	paths := [1]Path{p}
	req: Request({.Path, .Nodes})
	defer request_destroy(&req)
	edit_scan(src, &req, paths[:], .Jsonc, allocator) or_return
	doc := &req.doc
	text := make([dynamic]u8, allocator)
	defer delete(text)
	places := make([dynamic]Place, allocator)
	defer delete(places)
	any_found := false
	for a in req.answers {
		if a.outcome != .Found {
			continue
		}
		any_found = true
		r := a.node
		if op == .Insert {
			if !comment_insert(&text, &places, doc, r, place, comment) {
				return nil, Edit_Error{kind = .Unplaceable}
			}
			continue
		}
		first := true
		for cm in facts(doc, r) {
			if cm.place != place {
				continue
			}
			from := len(text)
			if op == .Set && first {
				append_string(&text, comment)
				if enc.is_line_comment(transmute([]u8)comment) && !line_ends(src, u64(cm.hi)) {
					append(&text, '\n')
				}
				append(&places, Place{at = u64(cm.lo), cut = u64(cm.hi), from = from, to = len(text)})
			} else {
				lo, hi := comment_cut(src, cm)
				append(&places, Place{at = lo, cut = hi, from = from, to = from})
			}
			first = false
		}
		if first && op == .Set {
			return nil, Edit_Error{kind = .Not_Found}
		}
	}
	if !any_found || len(places) == 0 {
		return nil, Edit_Error{kind = .Not_Found}
	}
	slice.sort_by(places[:], proc(a, b: Place) -> bool {
		return a.at < b.at
	})
	for i in 1 ..< len(places) {
		if places[i].at < places[i - 1].cut {
			return nil, Edit_Error{kind = .Unplaceable}
		}
	}
	return judged(places_apply(src, places[:], text[:], allocator), allocator, .Jsonc)
}

// What removing `cm` deletes: its line, line break before it included, when it stands alone on one, else
// the comment and the blanks before it.
@(private = "file")
comment_cut :: proc(src: []byte, cm: Fact) -> (lo, hi: u64) {
	ls, first := line_start(src, u64(cm.lo))
	if !first || !line_ends(src, u64(cm.hi)) {
		return ls, u64(cm.hi)
	}
	end := line_end(src, u64(cm.hi))
	if ls > 0 {
		return break_before(src, ls), end
	}
	return 0, past_break(src, end)
}

// Place `comment` at `place` on row `r`. A `.Lead` or `.Foot` comment takes a line of its own, indented as
// the line it goes before. An `.Inline` one goes before the value, a `.Trail` one after the extent.
@(private = "file")
comment_insert :: proc(text: ^[dynamic]u8, places: ^[dynamic]Place, doc: ^Document, r: Node, place: Fact_Place, comment: string) -> bool {
	src := doc.src
	nd := doc.rows[r]
	line := enc.is_line_comment(transmute([]u8)comment)
	from := len(text)
	at: u64
	switch place {
	case .Lead:
		at = u64(scan_pkg.entry_lo(nd))
		if ls, first := line_start(src, at); first {
			append_string(text, comment, "\n")
			append(text, ..src[ls:at])
		} else {
			append_string(text, "\n", comment, "\n")
		}
	case .Inline:
		if nd.key_lo == core_pkg.NO_KEY {
			return false
		}
		at = u64(nd.lo)
		append_string(text, comment)
		if line {
			append_string(text, "\n")
			if ls, first := line_start(src, u64(nd.key_lo)); first {
				append(text, ..src[ls:nd.key_lo])
			}
		} else {
			append_string(text, " ")
		}
	case .Trail:
		for cm in facts(doc, r) {
			if cm.place == .Trail && enc.is_line_comment(src[cm.lo:cm.hi]) {
				return false
			}
		}
		at = extent_hi(doc, r)
		append_string(text, " ", comment)
		if line && !line_ends(src, at) {
			append_string(text, "\n")
		}
	case .Foot:
		if nd.kind != .Array && nd.kind != .Object {
			return false
		}
		close := u64(nd.hi) - 1
		ls, first := line_start(src, close)
		if !first {
			at = close
			append_string(text, "\n", comment, "\n")
			break
		}
		at = ls
		indent := src[ls:close]
		if nd.subtree_size > 1 {
			last := r + 1
			for last + Node(doc.rows[last].subtree_size) < r + Node(nd.subtree_size) {
				last += Node(doc.rows[last].subtree_size)
			}
			kl := u64(scan_pkg.entry_lo(doc.rows[last]))
			if kls, kfirst := line_start(src, kl); kfirst {
				indent = src[kls:kl]
			}
		}
		append(text, ..indent)
		append_string(text, comment, "\n")
	}
	append(places, Place{at = at, cut = at, from = from, to = len(text)})
	return true
}
