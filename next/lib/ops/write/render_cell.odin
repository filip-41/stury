package write

import "base:runtime"
import "core:math"
import "core:unicode/utf8"
import "stury:lib/core/tape"

// Scalar/key/number cell formatting, iterative compact nested-container JSON formatting, cell escaping, and Unicode
// display-width truncation shared by `table_render.odin`, `markdown_render.odin`, and `render_grid.odin`.

@(private)
append_value_cell :: proc(b: ^Grid_Builder, w: ^Tree, at: tape.Node_Index) -> Error {
	node := w.doc.nodes[at]
	clear(&b.scratch)
	switch node.kind {
	case .Null:
		return append_escaped_span(b, &b.grid.cells, b.opts.null_text, {.Null})
	case .True:
		return append_escaped_span(b, &b.grid.cells, "true")
	case .False:
		return append_escaped_span(b, &b.grid.cells, "false")
	case .Number:
		format_number_into(&b.scratch, w, at) or_return
		return append_escaped_span(b, &b.grid.cells, string(b.scratch[:]), {.Numeric})
	case .String, .Plain:
		s, ok := text_of(w, at)
		if !ok {
			return w.err
		}
		return append_escaped_span(b, &b.grid.cells, s)
	case .Bytes:
		encoded, ok := bytes_base64(w, at)
		if !ok {
			return w.err
		}
		defer delete(encoded, w.allocator)
		return append_escaped_span(b, &b.grid.cells, encoded)
	case .Array, .Object:
		if node.spelling & tape.CONTAINER_PARTIAL != 0 {
			return Refused{at, .Partial}
		}
		append_compact_json(&b.scratch, w.doc, at, b.opts.sort_keys, b.alloc) or_return
		return append_escaped_span(b, &b.grid.cells, string(b.scratch[:]))
	case .End:
		return append_absent_cell(b)
	}
	return nil
}

@(private)
format_key_raw :: proc(b: ^Grid_Builder, w: ^Tree, at: tape.Node_Index) -> Error {
	node := w.doc.nodes[at]
	if node.kind == .Array || node.kind == .Object {
		return append_compact_json(&b.scratch, w.doc, at, b.opts.sort_keys, b.alloc)
	}
	return format_key_scalar_into(&b.scratch, w, at)
}

@(private = "file")
format_key_scalar_into :: proc(dst: ^[dynamic]u8, w: ^Tree, at: tape.Node_Index) -> Error {
	node := w.doc.nodes[at]
	switch node.kind {
	case .Null:
		if _, err := append(dst, "null"); err != nil {
			return err
		}
	case .True:
		if _, err := append(dst, "true"); err != nil {
			return err
		}
	case .False:
		if _, err := append(dst, "false"); err != nil {
			return err
		}
	case .Number:
		// Use the format's canonical key spelling via `text_of` first (so YAML `1e0`/`.inf`/`.nan` and CBOR int keys
		// match `tape.member` identically), falling back to `format_number_into` for unspelled binary floats.
		if s, ok := text_of(w, at); ok && len(s) > 0 {
			if _, err := append(dst, s); err != nil {
				return err
			}
			return nil
		}
		if w.err != nil {
			return w.err
		}
		return format_number_into(dst, w, at)
	case .String, .Plain:
		s, ok := text_of(w, at)
		if !ok {
			return w.err
		}
		if _, err := append(dst, s); err != nil {
			return err
		}
	case .Bytes:
		// Formats with `.Bytes` keys (CBOR, YAML `!!binary`) already return base64 from `text_of` when `role == .Key`.
		if node.role == .Key {
			if s, ok := text_of(w, at); ok {
				if _, err := append(dst, s); err != nil {
					return err
				}
				return nil
			}
			if w.err != nil {
				return w.err
			}
		}
		encoded, ok := bytes_base64(w, at)
		if !ok {
			return w.err
		}
		defer delete(encoded, w.allocator)
		if _, err := append(dst, encoded); err != nil {
			return err
		}
	case .Array, .Object, .End:
	}
	return nil
}

@(private = "file")
format_number_into :: proc(dst: ^[dynamic]u8, w: ^Tree, at: tape.Node_Index) -> Error {
	buf: [NUMBER_ROOM]u8
	if s, ok := number_text(w, at, &buf); ok {
		if _, err := append(dst, s); err != nil {
			return err
		}
		return nil
	}
	if w.err != nil {
		return w.err
	}
	if n, ok := tape.node_number(w.doc, at); ok && n.kind == .Float {
		f := transmute(f64)n.bits
		switch {
		case math.is_nan(f):
			if _, err := append(dst, "NaN"); err != nil {
				return err
			}
			return nil
		case math.is_inf(f, 1):
			if _, err := append(dst, "Infinity"); err != nil {
				return err
			}
			return nil
		case math.is_inf(f, -1):
			if _, err := append(dst, "-Infinity"); err != nil {
				return err
			}
			return nil
		}
	}
	// Fallback for wide non-binary numbers or raw spans.
	node := w.doc.nodes[at]
	if .Binary not_in w.doc.format.caps {
		if _, err := append(dst, ..tape.span_bytes(w.doc, node.lo, node.n)); err != nil {
			return err
		}
		return nil
	}
	return Refused{at, .No_Spelling}
}

// ---------------------------------------------------------------------------
// Iterative compact JSON serializer for nested containers inside table cells.
// Intentional display deviations from strict RFC 8259: non-finite floats emit
// bare `NaN`/`Infinity`/`-Infinity`, and nested container keys collapse to
// `"[...]"` / `"{...}"` to keep the walk strictly non-recursive.
// ---------------------------------------------------------------------------

@(private = "file")
append_compact_json :: proc(dst: ^[dynamic]u8, doc: ^tape.Document, root: tape.Node_Index, sort_keys: bool, allocator: runtime.Allocator) -> Error {
	w: Tree
	tree_start_node(&w, doc, {node = root, sort_keys = sort_keys}, {}, allocator, true) or_return
	defer tree_end(&w)
	key_scratch: [dynamic]u8
	key_scratch.allocator = allocator
	defer delete(key_scratch)
	tables := tree_tables(&w)
	for w.err == nil {
		s := tree_next(&w, false, true) if tables else tree_next(&w, false, false)
		if s.kind == .Done {
			break
		}
		if s.kind == .Close {
			ch: u8 = '}' if doc.nodes[s.node].kind == .Object else ']'
			if _, err := append(dst, ch); err != nil {
				return err
			}
			continue
		}
		if !s.first {
			if _, err := append(dst, ','); err != nil {
				return err
			}
		}
		if s.key != tape.NO_NODE {
			append_json_key_node(dst, &key_scratch, &w, s.key) or_return
			if _, err := append(dst, ':'); err != nil {
				return err
			}
		} else if s.cell {
			ks, ok := text_of_token(&w, w.cell)
			if !ok {
				return w.err
			}
			append_json_quoted(dst, ks) or_return
			if _, err := append(dst, ':'); err != nil {
				return err
			}
		}
		n := doc.nodes[s.node]
		switch n.kind {
		case .Object:
			if _, err := append(dst, '{'); err != nil {
				return err
			}
		case .Array:
			if _, err := append(dst, '['); err != nil {
				return err
			}
		case .Null:
			if _, err := append(dst, "null"); err != nil {
				return err
			}
		case .True:
			if _, err := append(dst, "true"); err != nil {
				return err
			}
		case .False:
			if _, err := append(dst, "false"); err != nil {
				return err
			}
		case .Number:
			format_number_into(dst, &w, s.node) or_return
		case .String, .Plain:
			str, ok := text_of(&w, s.node)
			if !ok {
				return w.err
			}
			append_json_quoted(dst, str) or_return
		case .Bytes:
			encoded, ok := bytes_base64(&w, s.node)
			if !ok {
				return w.err
			}
			err := append_json_quoted(dst, encoded)
			delete(encoded, w.allocator)
			if err != nil {
				return err
			}
		case .End:
		}
	}
	return w.err
}

@(private = "file")
append_json_key_node :: proc(dst, scratch: ^[dynamic]u8, w: ^Tree, key_at: tape.Node_Index) -> Error {
	node := w.doc.nodes[key_at]
	#partial switch node.kind {
	case .Array:
		append_json_quoted(dst, "[...]") or_return
		return nil
	case .Object:
		append_json_quoted(dst, "{...}") or_return
		return nil
	case .End:
		append_json_quoted(dst, "") or_return
		return nil
	}
	clear(scratch)
	format_key_scalar_into(scratch, w, key_at) or_return
	append_json_quoted(dst, string(scratch[:])) or_return
	return nil
}

@(private = "file")
append_json_quoted :: proc(dst: ^[dynamic]u8, s: string) -> runtime.Allocator_Error {
	hex := "0123456789abcdef"
	append(dst, '"') or_return
	run := 0
	b := transmute([]u8)s
	for c, i in b {
		if c >= 0x20 && c != '"' && c != '\\' {
			continue
		}
		if i > run {
			append(dst, ..b[run:i]) or_return
		}
		switch c {
		case '"':
			append(dst, `\"`) or_return
		case '\\':
			append(dst, `\\`) or_return
		case '\b':
			append(dst, `\b`) or_return
		case '\f':
			append(dst, `\f`) or_return
		case '\n':
			append(dst, `\n`) or_return
		case '\r':
			append(dst, `\r`) or_return
		case '\t':
			append(dst, `\t`) or_return
		case:
			esc := [6]u8{'\\', 'u', '0', '0', hex[c >> 4], hex[c & 0xF]}
			append(dst, ..esc[:]) or_return
		}
		run = i + 1
	}
	if run < len(b) {
		append(dst, ..b[run:]) or_return
	}
	append(dst, '"') or_return
	return nil
}

// ---------------------------------------------------------------------------
// Cell escaping + UTF-8 display width & truncation
// ---------------------------------------------------------------------------

// Appends `raw` escaped according to `mode` into `dst` and returns its terminal display width.
@(private)
append_escaped :: proc(dst: ^[dynamic]u8, raw: []u8, mode: Escape_Mode) -> (width: int, err: runtime.Allocator_Error) {
	if len(raw) == 0 {
		return 0, nil
	}
	// ASCII fast path: printable ASCII without mode-special bytes copies straight through.
	clean := true
	switch mode {
	case .Table:
		for c in raw {
			if c < 0x20 || c >= 0x7F {
				clean = false
				break
			}
		}
	case .Markdown:
		for c in raw {
			if c < 0x20 || c >= 0x7F || c == '|' || c == '\\' {
				clean = false
				break
			}
		}
	}
	if clean {
		append(dst, ..raw) or_return
		return len(raw), nil
	}

	hex := "0123456789abcdef"
	s := string(raw)
	i := 0
	for i < len(raw) {
		c := raw[i]
		if c < 0x80 {
			if c >= 0x20 && c < 0x7F && (mode == .Table || (c != '|' && c != '\\')) {
				append(dst, c) or_return
				width += 1
				i += 1
				continue
			}
			switch c {
			case '\n':
				if mode == .Markdown {
					append(dst, "<br>") or_return
					width += 4
				} else {
					append(dst, `\n`) or_return
					width += 2
				}
			case '\r':
				if mode == .Markdown {
					if i + 1 < len(raw) && raw[i + 1] == '\n' {
						i += 1
					}
					append(dst, "<br>") or_return
					width += 4
				} else {
					append(dst, `\r`) or_return
					width += 2
				}
			case '\t':
				if mode == .Markdown {
					append(dst, ' ') or_return
					width += 1
				} else {
					append(dst, `\t`) or_return
					width += 2
				}
			case '|':
				append(dst, `\|`) or_return
				width += 2
			case '\\':
				append(dst, `\\`) or_return
				width += 2
			case:
				esc := [4]u8{'\\', 'x', hex[c >> 4], hex[c & 0xF]}
				append(dst, ..esc[:]) or_return
				width += 4
			}
			i += 1
			continue
		}
		r, sz := utf8.decode_rune_in_string(s[i:])
		if sz <= 0 {
			sz = 1
		}
		// Escape C1 control characters (U+0080..U+009F) so terminal sequences cannot leak through.
		if r >= 0x80 && r <= 0x9F {
			esc := [6]u8{'\\', 'u', '0', '0', hex[(r >> 4) & 0xF], hex[r & 0xF]}
			append(dst, ..esc[:]) or_return
			width += 6
			i += sz
			continue
		}
		append(dst, ..raw[i:i + sz]) or_return
		width += rune_display_width(r)
		i += sz
	}
	return width, nil
}

// Truncates UTF-8 string `s` so its rendered width plus ellipsis fits within `max_width`.
@(private)
truncate_display :: proc "contextless" (s: string, max_width: int, ascii_ellipsis: bool) -> (prefix: string, used: int, suffix: string) {
	if max_width <= 0 {
		return "", 0, ""
	}
	if ascii_ellipsis {
		if max_width >= 3 {
			suffix = "..."
		} else if max_width == 2 {
			suffix = ".."
		} else {
			suffix = "."
		}
	} else {
		suffix = "…"
	}
	suffix_w := len(suffix) if ascii_ellipsis else 1
	budget := max_width - suffix_w
	if budget <= 0 {
		return "", suffix_w, suffix
	}
	i := 0
	w := 0
	for i < len(s) {
		r, sz := utf8.decode_rune_in_string(s[i:])
		if sz <= 0 {
			sz = 1
		}
		rw := rune_display_width(r)
		if rw > 0 && w + rw > budget {
			break
		}
		w += rw
		i += sz
	}
	// Do not emit orphan leading zero-width/combining marks when no base rune fits in `budget`.
	if w == 0 {
		i = 0
	}
	return s[:i], w + suffix_w, suffix
}

@(private = "file")
Rune_Range :: struct {
	lo, hi: rune,
}

@(private = "file", rodata)
ZERO_WIDTH_RANGES := [?]Rune_Range{
	{0x0300, 0x036F}, {0x0483, 0x0489}, {0x0591, 0x05BD}, {0x05BF, 0x05BF},
	{0x05C1, 0x05C2}, {0x05C4, 0x05C5}, {0x05C7, 0x05C7}, {0x0610, 0x061A},
	{0x064B, 0x065F}, {0x0670, 0x0670}, {0x06D6, 0x06DC}, {0x06DF, 0x06E4},
	{0x06E7, 0x06E8}, {0x06EA, 0x06ED}, {0x0711, 0x0711}, {0x0730, 0x074A},
	{0x0901, 0x0902}, {0x093C, 0x093C}, {0x0941, 0x0948}, {0x094D, 0x094D},
	{0x0951, 0x0957}, {0x0962, 0x0963}, {0x0E31, 0x0E31}, {0x0E34, 0x0E3A},
	{0x0E47, 0x0E4E}, {0x1160, 0x11FF}, {0x1AB0, 0x1AFF}, {0x1DC0, 0x1DFF},
	{0x200B, 0x200F}, {0x202A, 0x202E}, {0x2060, 0x206F}, {0x20D0, 0x20FF},
	{0xFE00, 0xFE0F}, {0xFE20, 0xFE2F}, {0xFEFF, 0xFEFF}, {0xE0100, 0xE01EF},
}

@(private = "file", rodata)
WIDE_RANGES := [?]Rune_Range{
	{0x1100, 0x115F}, {0x231A, 0x231B}, {0x2329, 0x232A}, {0x23E9, 0x23EC},
	{0x23F0, 0x23F0}, {0x23F3, 0x23F3}, {0x25FD, 0x25FE}, {0x2614, 0x2615},
	{0x2648, 0x2653}, {0x267F, 0x267F}, {0x2693, 0x2693}, {0x26A1, 0x26A1},
	{0x26AA, 0x26AB}, {0x26BD, 0x26BE}, {0x26C4, 0x26C5}, {0x26CE, 0x26CE},
	{0x26D4, 0x26D4}, {0x26EA, 0x26EA}, {0x26F2, 0x26F3}, {0x26F5, 0x26F5},
	{0x26FA, 0x26FA}, {0x26FD, 0x26FD}, {0x2705, 0x2705}, {0x270A, 0x270B},
	{0x2728, 0x2728}, {0x274C, 0x274C}, {0x274E, 0x274E}, {0x2753, 0x2755},
	{0x2757, 0x2757}, {0x2795, 0x2797}, {0x27B0, 0x27B0}, {0x27BF, 0x27BF},
	{0x2B1B, 0x2B1C}, {0x2B50, 0x2B50}, {0x2B55, 0x2B55}, {0x2E80, 0x303E},
	{0x3041, 0x4DBF}, {0x4E00, 0xA4CF}, {0xA960, 0xA97C}, {0xAC00, 0xD7A3},
	{0xF900, 0xFAFF}, {0xFE10, 0xFE19}, {0xFE30, 0xFE6B}, {0xFF01, 0xFF60},
	{0xFFE0, 0xFFE6}, {0x1F004, 0x1F004}, {0x1F0CF, 0x1F0CF}, {0x1F18E, 0x1F18E},
	{0x1F191, 0x1F19A}, {0x1F200, 0x1F251}, {0x1F300, 0x1F64F}, {0x1F680, 0x1F6FF},
	{0x1F900, 0x1FAFF}, {0x20000, 0x2FFFD}, {0x30000, 0x3FFFD},
}

// Invariant: `ranges` is sorted ascending and non-overlapping, and `lo < hi` guarantees `0 <= mid < len(ranges)`.
@(private = "file")
in_rune_ranges :: proc "contextless" (ranges: []Rune_Range, r: rune) -> bool #no_bounds_check {
	lo, hi := 0, len(ranges)
	for lo < hi {
		mid := lo + (hi - lo) >> 1
		rng := ranges[mid]
		if r < rng.lo {
			hi = mid
		} else if r > rng.hi {
			lo = mid + 1
		} else {
			return true
		}
	}
	return false
}

// Terminal display width of Unicode code point `r` (0, 1, or 2).
@(private = "file")
rune_display_width :: proc "contextless" (r: rune) -> int {
	if r < 0x20 || (r >= 0x7F && r < 0xA0) {
		return 0
	}
	if r < 0x0300 {
		return 1
	}
	if in_rune_ranges(ZERO_WIDTH_RANGES[:], r) {
		return 0
	}
	if in_rune_ranges(WIDE_RANGES[:], r) {
		return 2
	}
	return 1
}
