package toml

import "stury:lib/core/tape"

// The services of the TOML specs beyond the node readers: the reads and records that `toml.reads` returns to a caller
// picking the format at run time, where a container closes, and the names of the facts a node spells.

// The reads of `spec`, for a caller that picks the format at run time, to use with the handle `as` returns. Nil for a
// `spec` out of range.
reads :: proc "contextless" (spec: Spec) -> ^tape.Reads {
	return tape.format_reads(Spec, ID, validate, build, find, scan, Records, records_open, records_validate, records_find, records_scan) if spec <= max(Spec) else nil
}

// The offset just past the close of container node `at` of `doc`: past its closing bracket for one written in brackets
// or braces, and where its last member's value ends for a table no bracket closes, its own offset for an empty one.
// False for a container other than the root of a `.Held` document, which holds no byte between its nodes.
@(private)
close_end :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index) -> (u64, bool) #no_bounds_check {
	if at == tape.ROOT {
		return doc.root_close, true
	}
	if .Held in doc.flags {
		return 0, false
	}
	// The container ends where its chain of last children ends, past one closing bracket for each container of the
	// chain written in brackets or braces.
	brackets := 0
	end: u64
	k := at
	for {
		node := doc.nodes[k]
		if node.kind <= .Plain {
			_, tail := bounds(doc.src, node)
			end = node.lo + u64(node.n) + u64(tail)
			break
		}
		inline := node.spelling & tape.CONTAINER_STYLE == STYLE_INLINE
		brackets += int(inline)
		if node.n <= 1 {
			end = node.lo + u64(inline)
			break
		}
		// The last child is the one whose subtree reaches the container's last node.
		last := k + tape.Node_Index(node.n) - 1
		k += 1
		for after := tape.node_after(doc, k); after <= last; after = tape.node_after(doc, k) {
			k = after
		}
	}
	for _ in 0 ..< brackets {
		end = bracket_after(doc.src, end)
	}
	return end, true
}

// One past the first `]` or `}` from `p` of `src` outside a comment, the close of an array or inline table whose last
// value ends at `p`.
@(private)
bracket_after :: proc "contextless" (src: []u8, p: u64) -> u64 #no_bounds_check {
	p := p
	for p < u64(len(src)) {
		switch src[p] {
		case ']', '}':
			return p + 1
		case '#':
			for p < u64(len(src)) && src[p] != '\n' {
				p += 1
			}
		case:
			p += 1
		}
	}
	return u64(len(src))
}

@(private, rodata)
DATE_NAMES := [Date_Kind]string {
	.None           = "",
	.Datetime       = "datetime",
	.Local_Datetime = "datetime-local",
	.Local_Date     = "date-local",
	.Local_Time     = "time-local",
}

@(private, rodata)
STRING_STYLES := [Style]string {
	.Basic             = "basic",
	.Literal           = "literal",
	.Multiline         = "multiline",
	.Multiline_Literal = "multiline_literal",
}

// The facts a TOML node spells. `.Tag` is a date-time's type: `datetime`, `datetime-local`, `date-local` or
// `time-local`. `.Style` is how a value is written: a string's or key's quotes, `bare` for a key without them, a
// number's `integer`, `float`, `hex`, `octal`, `binary`, `inf` or `nan`, and for a container below the root
// `inline` in brackets or braces, `dotted` for a table a dotted key made, `header` for a table or an array of tables
// a header made, and `implicit` for a table only other headers' paths made.
@(private)
spelled_fact :: proc "contextless" (doc: ^tape.Document, at: tape.Node_Index, kind: tape.Fact_Kind) -> (string, bool) #no_bounds_check {
	n := doc.nodes[at]
	#partial switch kind {
	case .Tag:
		if d := date_kind(n); d != .None {
			return DATE_NAMES[d], true
		}
	case .Style:
		#partial switch n.kind {
		case .String:
			if n.spelling & tape.SPELLING_QUOTED != 0 {
				return STRING_STYLES[style_of(n.spelling)], true
			}
			if n.role == .Key {
				return "bare", true
			}
		case .Number:
			switch Number_Spelling(n.spelling & tape.NUMBER_KIND) {
			case .Plain, .Decimal:
				form, _ := tape.number_form(doc, at)
				return "float" if form.frac_digits > 0 || form.exponent else "integer", true
			case .Hex:
				return "hex", true
			case .Octal:
				return "octal", true
			case .Binary:
				return "binary", true
			case .Inf:
				return "inf", true
			case .Nan:
				return "nan", true
			}
		case .Array, .Object:
			if at == tape.ROOT {
				return "", false
			}
			switch n.spelling & tape.CONTAINER_STYLE {
			case STYLE_INLINE:
				return "inline", true
			case STYLE_DOTTED:
				return "dotted", true
			case STYLE_IMPLICIT:
				return "implicit", true
			}
			return "header", true
		}
	}
	return "", false
}

// `doc`, a scan's, with the kinds of fact its nodes spell, which are in no fact, `.Style` and `.Tag`, among those it
// holds. A table's first member is a key, which spells a style, and a quoted string's spelling has no date-time bits.
@(private, cold)
spelled_present :: proc "contextless" (doc: tape.Document, err: tape.Error) -> (tape.Document, tape.Error) #no_bounds_check {
	doc := doc
	if err != nil || len(doc.nodes) == 0 {
		return doc, err
	}
	if doc.nodes[0].kind == .Object && len(doc.nodes) > 1 {
		doc.present += {.Style}
	} else {
		for i in 0 ..< len(doc.nodes) {
			if _, ok := spelled_fact(&doc, tape.Node_Index(i), .Style); ok {
				doc.present += {.Style}
				break
			}
		}
	}
	dates: u16
	for n in doc.nodes {
		dates |= n.spelling >> DATE_SHIFT if n.kind == .String && n.role == .Value else 0
	}
	if dates != 0 {
		doc.present += {.Tag}
	}
	return doc, nil
}
