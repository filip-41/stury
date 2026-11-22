package json

import "base:runtime"
import "stury:lib/core/tape"

// The services of the JSON formats beyond the node readers: the reads that `json.reads` returns to a caller picking the
// format at run time, and where a container closes.

// The spec of a JSON format handle.
@(private)
spec_of :: #force_inline proc "contextless" (f: ^tape.Format) -> Spec {
	return Spec(f.id - 1)
}

@(private)
validate_of :: proc(f: ^tape.Format, src: []u8, opts: tape.Options, allocator: runtime.Allocator) -> tape.Error {
	return validate(src, spec_of(f), opts, allocator)
}

@(private)
build_of :: proc(f: ^tape.Format, src: []u8, opts: tape.Options, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	return build(src, spec_of(f), opts, allocator)
}

@(private)
find_of :: proc(f: ^tape.Format, src: []u8, path: []tape.Step, read: tape.Read_Options, opts: tape.Options, allocator: runtime.Allocator) -> (tape.Span_Answer, tape.Error) {
	return find(src, path, spec_of(f), read, opts, allocator)
}

@(private)
scan_of :: proc(f: ^tape.Format, src: []u8, demand: ^tape.Demand, read: tape.Read_Options, opts: tape.Options, allocator: runtime.Allocator) -> (tape.Document, tape.Error) {
	return scan(src, demand, spec_of(f), read, opts, allocator)
}

// The offset just past the close of container node `at` of `doc`, counting the closes of the containers its last
// descendant ends inside, with the white space, commas and comments before each, none of which holds a node. False for
// a container other than the root of a `.Held` document, which holds no byte between its nodes.
@(private)
close_end :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (u64, bool) #no_bounds_check {
	if at == tape.ROOT {
		return doc.root_close, true
	}
	if .Held in doc.flags {
		return 0, false
	}
	closes := 1
	last := at
	for {
		node := doc.nodes[last]
		end := last + tape.Node_Index(node.n)
		if node.kind < .Array || node.n == 1 {
			break
		}
		k := last + 1
		for {
			after := tape.node_after(doc, k)
			if after == end {
				break
			}
			k = after
		}
		last = k
		if doc.nodes[last].kind > .Plain {
			closes += 1
		}
	}
	t := doc.nodes[last]
	p := t.lo + 1
	if t.kind <= .Plain {
		_, tail := quotes(doc.src, t)
		p = t.lo + u64(t.n) + u64(tail)
	}
	src := doc.src
	for p < u64(len(src)) {
		switch src[p] {
		case ']', '}':
			p += 1
			if closes -= 1; closes == 0 {
				return p, true
			}
		case '/':
			if p + 1 < u64(len(src)) && src[p + 1] == '*' {
				p += 2
				for p + 1 < u64(len(src)) && !(src[p] == '*' && src[p + 1] == '/') {
					p += 1
				}
				p += 2
			} else {
				p = line_comment_end(src, p, doc.format == &FORMATS[.Json5])
			}
		case:
			p += 1
		}
	}
	return u64(len(src)), true
}

// The line end that closes the `//` comment at `p` of `src`: LF or CR, and in JSON5 U+2028 or U+2029 too.
@(private)
line_comment_end :: proc "contextless" (src: []u8, p: u64, json5: bool) -> u64 #no_bounds_check {
	end := raw_data(src)[len(src):]
	for q := p; q < u64(len(src)); q += 1 {
		if src[q] == '\n' || src[q] == '\r' || json5 && line_sep5(raw_data(src)[q:], end) {
			return q
		}
	}
	return u64(len(src))
}

// The size in bytes of a buffer that holds the decoded text of node `t`: its span, since an escape decodes to no more
// bytes than it spells, or three times the span for a `SPELLING_LAX` node, since a tolerated byte reads as U+FFFD.
@(private)
text_room :: proc "contextless" (src: []u8, t: tape.Node) -> int {
	return int(t.n) * (3 if t.spelling & tape.SPELLING_LAX != 0 else 1)
}
