package yaml

// Clears what one document holds and the next must not see.
@(private)
reset_document :: proc(p: ^Parser) {
	clear(&p.handles)
	clear(&p.anchors)
	clear(&p.log)
	clear(&p.open)
	clear(&p.keys.frames)
	clear(&p.keys.keys)
	clear(&p.keys.heads)
	clear(&p.stage)
	clear(&p.blocks)
	clear(&p.flows)
	clear(&p.merges)
	p.holding = false
	p.next = .After
	p.staging = false
	p.pend_anch = -1
	p.tdepth = 0
	p.expanded = 0
	p.depth = 0
	p.has_yaml = false
	p.directives = false
}

// Reads the next document of the text from the cursor: its directives, an optional `---`, its node and an optional
// `...`. Leaves the cursor at the byte after the document: past the `...` line, or at the next `---`, or at the end.
// `found` is false when only comments, blank lines and `...` markers remained.
@(private)
read_document :: proc(p: ^Parser) -> (found: bool, ok: bool) {
	for {
		reset_document(p)
		if p.pos + 3 <= u64(len(p.src)) && p.src[p.pos] == 0xef && p.src[p.pos + 1] == 0xbb && p.src[p.pos + 2] == 0xbf {
			p.pos += 3
			p.ls = p.pos
		}
		peek_next(p) or_return
		for p.nl.kind == .Content && p.nl.ind == 0 && at(p, p.pos) == '%' {
			if p.nl.tab {
				return false, fault(p, p.pos, .Bad_Char, .Tab_Indent)
			}
			read_directive(p) or_return
			peek_next(p) or_return
		}
		l := p.nl
		switch {
		case l.kind == .Eof:
			if p.directives {
				return false, fault(p, p.pos, .Truncated, .Expected_Document_Start)
			}
			clear(&p.pending)
			return false, true
		case l.kind == .Marker && at(p, p.pos) == '.':
			if p.directives {
				return false, fault(p, p.pos, .Bad_Char, .Expected_Document_Start)
			}
			p.pos += 3
			finish_line(p, false) or_return
			clear(&p.pending)
			if !at_eof(p) {
				consume_break(p)
			}
			continue
		case l.kind == .Marker:
			p.pos += 3
			parse_node(p, -1, false, false, .Value) or_return
		case p.directives:
			return false, fault(p, p.pos, .Bad_Char, .Expected_Document_Start)
		case:
			parse_block_at(p, l.ind, -1, .Value, &Props{}, false) or_return
		}
		read_blocks(p) or_return
		break
	}
	return true, end_document(p)
}

// Reads what follows the node of a document whose block collections have all closed: its foot comments and an optional
// `...` line. Leaves the cursor as `read_document` does.
@(private)
end_document :: proc(p: ^Parser) -> bool {
	peek_next(p) or_return
	l := p.nl
	if l.kind == .Content {
		return fault(p, p.pos, .Bad_Char, .Unexpected_Content)
	}
	flush_foot(p, 0) or_return
	if l.kind == .Marker && at(p, p.pos) == '.' {
		p.pos += 3
		finish_line(p, false) or_return
		clear(&p.pending)
		if !at_eof(p) {
			consume_break(p)
		}
	}
	return true
}
