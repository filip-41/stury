package tape

import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"

// Resource limits for one read, check or query run. 0 means no limit, except for `depth` and `expansion`, which then
// take their defaults.
Budget :: struct {
	depth:     u32, // deepest nesting, 0 for `DEFAULT_DEPTH`
	nodes:     u32, // most nodes a build keeps
	// Bytes, counted per allocator block. A build with `Options.runner` counts the blocks of its parts, which may fit a
	// budget a build on one thread is refused.
	memory:    u64,
	steps:     u64, // containers a walk opens, regex backtracks, schema branches, evaluator calls and loop turns
	// Bytes a text's references may expand to, an XML entity's replacement text or a YAML alias's value, each counted
	// with the references it holds. 0 for `default_expansion` of the text's length.
	expansion: u64,
}

// Which `Budget` limit an `Exceeded` ran out of.
Budget_Kind :: enum u8 {
	None,
	Depth,
	Nodes,
	Memory,
	Steps,
	Expansion,
}

// The nesting depth a read allows when `Budget.depth` is 0.
DEFAULT_DEPTH :: 10_000

// The expansion a text of `n` bytes may reach when `Budget.expansion` is 0: 8 MiB, or a hundred times the text when
// that is more.
@(require_results)
default_expansion :: proc "contextless" (n: u64) -> u64 {
	return max(8 << 20, n * 100 if n <= max(u64) / 100 else max(u64))
}

// The `at` of an error that names no byte of the text.
NO_BYTE :: max(u64)

// A `Budget` limit that ran out.
Exceeded :: struct {
	at:   u64, // the byte the read was at, or `NO_BYTE` when no single byte applies (e.g. memory)
	kind: Budget_Kind,
}

Fault_Kind :: spell.Fault_Kind

// Why and where a text failed to parse.
Fault :: struct {
	at:     u64,
	rules:  ^Rules,
	kind:   Fault_Kind,
	detail: u8, // index into `rules.details`, 0 for none
}

// A format's fault rules, in rodata. `details[d]` holds the code and message of detail `d`, and `details[0]` is unused.
Rules :: struct {
	format:  string,
	details: []Rule,
}

Rule :: struct {
	code:    string, // stable, for callers to match on
	message: string, // may change
}

// An option the read does not take, which it names.
Bad_Option :: struct {
	option: string,
}

// The error of a library call, one arm per cause.
Error :: union {
	Fault,
	runtime.Allocator_Error,
	Exceeded,
	Piece_Gap,
	Bad_Option,
}

@(private = "file", rodata)
KIND_RULES := [Fault_Kind]Rule {
	.None          = {"none", "No fault"},
	.Truncated     = {"truncated", "Unfinished input"},
	.Bad_Char      = {"bad_char", "Unexpected character"},
	.Bad_Escape    = {"bad_escape", "Invalid escape"},
	.Bad_Number    = {"bad_number", "Invalid number"},
	.Too_Wide      = {"too_wide", "Token is longer than 4 GiB"},
	.Bad_Width     = {"bad_width", "Record width differs from the first record"},
	.Duplicate_Key = {"duplicate_key", "Duplicate key"},
	.Refused       = {"refused", "Value not taken by the type"},
}

@(private = "file", rodata)
BUDGET_MESSAGES := [Budget_Kind]string {
	.None      = "Exceeds limit",
	.Depth     = "Exceeds the depth limit",
	.Nodes     = "Exceeds the node limit",
	.Memory    = "Exceeds the memory limit",
	.Steps     = "Exceeds the step limit",
	.Expansion = "Exceeds the expansion limit",
}

// The rule of fault `f`: its format's detail, or else its kind's.
@(require_results)
fault_rule :: proc "contextless" (f: Fault) -> Rule {
	if f.detail != 0 && f.rules != nil && int(f.detail) < len(f.rules.details) {
		return f.rules.details[f.detail]
	}
	return KIND_RULES[f.kind if f.kind <= max(Fault_Kind) else .None]
}

// Writes the message of `err`, an error of a read of `src`, a text of `format`, into `buf` and returns it, cut to
// `len(buf)` bytes. An error that names a byte starts with its line and column, both from 1, where a line ends at LF
// and a column counts bytes, or in a `.Binary` format with `byte` and its offset, from 0, as a binary text has no
// lines. Nil gives an empty message.
@(require_results)
error_message :: proc "contextless" (buf: []u8, err: Error, src: []u8, format: ^Format = nil) -> string {
	m := Message{buf = buf}
	binary := format != nil && .Binary in format.caps
	switch e in err {
	case Fault:
		if e.at != NO_BYTE {
			message_place(&m, src, e.at, binary)
		}
		r := fault_rule(e)
		message_text(&m, r.message)
		if e.at < u64(len(src)) && (r.code == "control_char" || r.code == "invalid_utf8") {
			hex := "0123456789ABCDEF"
			b := src[e.at]
			message_text(&m, " U+00" if r.code == "control_char" && b < 0x80 else " byte 0x")
			pair := [2]u8{hex[b >> 4], hex[b & 15]}
			message_text(&m, string(pair[:]))
		}
	case Exceeded:
		if e.at != NO_BYTE {
			message_place(&m, src, e.at, binary)
		}
		message_text(&m, BUDGET_MESSAGES[e.kind if e.kind <= max(Budget_Kind) else .None])
	case runtime.Allocator_Error:
		message_text(&m, "Out of memory")
	case Piece_Gap:
		message_text(&m, "The window holds bytes ")
		message_number(&m, e.from)
		message_text(&m, " to ")
		message_number(&m, e.to)
		message_text(&m, ", the read needs ")
		message_number(&m, e.keep)
		message_text(&m, " to ")
		message_number(&m, e.at)
	case Bad_Option:
		message_text(&m, "Option not taken: ")
		message_text(&m, e.option)
	}
	return string(m.buf[:m.n])
}

@(private = "file")
Message :: struct {
	buf: []u8,
	n:   int,
}

@(private = "file")
message_text :: proc "contextless" (m: ^Message, s: string) {
	k := copy(m.buf[m.n:], s)
	m.n += k
}

@(private = "file")
message_number :: proc "contextless" (m: ^Message, v: u64) {
	digits: [20]u8
	i := len(digits)
	for v := v; ; v /= 10 {
		i -= 1
		digits[i] = '0' + u8(v % 10)
		if v < 10 {
			break
		}
	}
	message_text(m, string(digits[i:]))
}

// Writes `line:col: ` of byte `at` of `src`, clamped to its length, or of a `binary` text `byte at: `.
@(private = "file")
message_place :: proc "contextless" (m: ^Message, src: []u8, at: u64, binary: bool) {
	if binary {
		message_text(m, "byte ")
		message_number(m, min(at, u64(len(src))))
		message_text(m, ": ")
		return
	}
	at := int(min(at, u64(len(src))))
	head := src[:at]
	message_number(m, u64(kernel.count_byte(head, '\n')) + 1)
	message_text(m, ":")
	message_number(m, u64(at - (kernel.last_index_byte(head, '\n') + 1)) + 1)
	message_text(m, ": ")
}

@(private = "file")
SNIPPET_TAB_WIDTH :: 4

// Formats a bounded two-line source snippet with a column-aligned `^` caret pointing at byte offset `at` in `src`:
//   <source line>
//   <spaces>^
// Expands tabs to 4 spaces, strips `\r\n`/`\n`, windows long lines around `at` with `...`, handles EOF
// (`at == u64(len(src))`), and returns `ok = false` for empty, binary, or non-UTF8 inputs (or if `buf` is too small).
@(require_results)
error_snippet :: proc "contextless" (buf: []u8, src: []u8, at: u64, max_cols := 120) -> (snippet: string, ok: bool) #no_bounds_check {
	if len(src) == 0 || at == NO_BYTE || len(buf) < 6 {
		return "", false
	}
	cap_cols := clamp(max_cols, 16, 4096) if max_cols > 0 else 120
	scan_limit := cap_cols * 4 + 32

	pos := int(min(at, u64(len(src))))
	if pos == len(src) && pos > 0 && src[pos - 1] == '\n' {
		pos -= 1
		if pos > 0 && src[pos - 1] == '\r' {
			pos -= 1
		}
	}

	scan_lo := pos
	for scan_lo > 0 && src[scan_lo - 1] != '\n' && pos - scan_lo < scan_limit {
		scan_lo -= 1
	}
	left_cut := scan_lo > 0 && src[scan_lo - 1] != '\n'
	if left_cut {
		for scan_lo < pos && (src[scan_lo] & 0xC0) == 0x80 {
			scan_lo += 1
		}
	}

	scan_hi := pos
	for scan_hi < len(src) && src[scan_hi] != '\n' && scan_hi - pos < scan_limit {
		scan_hi += 1
	}
	right_cut := scan_hi < len(src) && src[scan_hi] != '\n'
	if right_cut {
		scan_hi = trim_trailing_partial_utf8(src, scan_lo, scan_hi, pos)
	}
	for scan_hi > scan_lo && src[scan_hi - 1] == '\r' {
		scan_hi -= 1
	}
	if pos > scan_hi {
		pos = scan_hi
	}
	// Snap `pos` onto a UTF-8 codepoint boundary when it falls inside a multi-byte sequence.
	for pos > scan_lo && pos < scan_hi && (src[pos] & 0xC0) == 0x80 {
		pos -= 1
	}

	line := src[scan_lo:scan_hi]
	if !kernel.utf8_valid(line) {
		return "", false
	}

	rel_pos := pos - scan_lo
	ctrl_cnt, char_cnt, pre_cols, total_cols := 0, 0, 0, 0
	for i := 0; i < len(line); {
		b := line[i]
		if b == 0 {
			return "", false
		}
		step, w := 1, 1
		if b < 0x80 {
			if b == '\t' {
				w = SNIPPET_TAB_WIDTH
			} else if b < 0x20 || b == 0x7f {
				ctrl_cnt += 1
			}
		} else {
			step = utf8_char_len(b)
		}
		if i < rel_pos {
			pre_cols += w
		}
		total_cols += w
		char_cnt += 1
		i += step
	}
	if ctrl_cnt >= 2 && ctrl_cnt * 4 >= char_cnt {
		return "", false
	}

	has_left := left_cut
	has_right := right_cut
	win_lo := 0
	win_hi := total_cols
	if !left_cut && !right_cut && total_cols <= cap_cols {
		// Entire line fits cleanly within `cap_cols`.
	} else if !left_cut && pre_cols <= cap_cols - 4 {
		has_left = false
		has_right = true
		win_lo = 0
		win_hi = min(total_cols, cap_cols - 3)
	} else if !right_cut && total_cols - pre_cols <= cap_cols - 4 {
		has_left = true
		has_right = false
		win_hi = total_cols
		win_lo = max(0, total_cols - (cap_cols - 3))
	} else {
		has_left = true
		has_right = true
		avail := max(cap_cols - 6, 4)
		win_lo = max(0, pre_cols - avail / 2)
		win_hi = min(total_cols, win_lo + avail)
		if win_hi - win_lo < avail && win_lo > 0 {
			win_lo = max(0, win_hi - avail)
		}
	}

	caret_col := (3 if has_left else 0) + clamp(pre_cols - win_lo, 0, win_hi - win_lo)

	n := 0
	if !buf_put(buf, &n, "  ") || (has_left && !buf_put(buf, &n, "...")) {
		return "", false
	}

	col := 0
	for i := 0; i < len(line); {
		step := utf8_char_len(line[i])
		if line[i] == '\t' {
			lo_k := max(win_lo - col, 0)
			hi_k := min(win_hi - col, SNIPPET_TAB_WIDTH)
			spaces := "    "
			if hi_k > lo_k && !buf_put(buf, &n, spaces[:hi_k - lo_k]) {
				return "", false
			}
			col += SNIPPET_TAB_WIDTH
		} else {
			if col >= win_lo && col < win_hi {
				b := line[i]
				s := "?" if step == 1 && (b < 0x20 || b == 0x7f) else string(line[i:i + step])
				if !buf_put(buf, &n, s) {
					return "", false
				}
			}
			col += 1
		}
		i += step
	}

	if has_right && !buf_put(buf, &n, "...") {
		return "", false
	}
	if n + 3 + caret_col + 2 > len(buf) {
		return "", false
	}
	buf[n], buf[n + 1], buf[n + 2] = '\n', ' ', ' '
	n += 3
	for k in 0 ..< caret_col {
		buf[n + k] = ' '
	}
	n += caret_col
	buf[n], buf[n + 1] = '^', '\n'
	n += 2
	return string(buf[:n]), true
}

@(private = "file")
buf_put :: #force_inline proc "contextless" (buf: []u8, n: ^int, s: string) -> bool #no_bounds_check {
	if len(s) > len(buf) - n^ {
		return false
	}
	copy(buf[n^:], s)
	n^ += len(s)
	return true
}

@(private = "file")
utf8_char_len :: #force_inline proc "contextless" (b: u8) -> int {
	switch b {
	case 0x00 ..= 0x7F:
		return 1
	case 0xC2 ..= 0xDF:
		return 2
	case 0xE0 ..= 0xEF:
		return 3
	case 0xF0 ..= 0xF4:
		return 4
	}
	return 0
}

@(private = "file")
trim_trailing_partial_utf8 :: proc "contextless" (src: []u8, lo, hi, min_hi: int) -> int #no_bounds_check {
	// Walk back at most 3 bytes from `hi` to find any multi-byte leader cut short by the scan cap.
	k := hi
	back := 0
	for k > lo && back < 4 {
		k -= 1
		back += 1
		b := src[k]
		if (b & 0xC0) != 0x80 {
			need := utf8_char_len(b)
			if need > 0 && k + need > hi && k >= min_hi {
				return k
			}
			break
		}
	}
	return hi
}
