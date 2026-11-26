// Runs the full html5lib tokenizer suite (7,042 runs across all initial states, verifying every token and parse error line:col).
package html_tests

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:testing"
import "stury:html"
import "stury:testkit"

@(private = "file")
TOKENIZER := #load_directory("conformance/html5lib/tokenizer")

@(private = "file")
SKIPPED := [?]struct {
	file, description, reason: string,
} {
	{"xmlViolation.test", "*", "XML infoset coercion"},
}

@(private)
Collector :: struct {
	src:    []u8,
	tokens: [dynamic]string,
	errors: [dynamic]string,
	text:   strings.Builder,
	alloc:  runtime.Allocator,
}

@(private)
collect :: proc "contextless" (c: ^Collector, tok: ^html.Internal_Token) -> html.Internal_Action {
	context = runtime.default_context()
	context.allocator = c.alloc
	switch tok.kind {
	case .Error:
		append(&c.errors, error_line(c.src, tok.detail, tok.lo))
	case .Text:
		strings.write_string(&c.text, read_span(c.src, tok.data))
	case .Start_Tag:
		flush_text(c)
		attrs := make([]string, len(tok.attrs))
		for a, idx in tok.attrs {
			attrs[idx] = fmt.aprintf("%q=%q", read_span(c.src, a.name), read_span(c.src, a.value))
		}
		append(&c.tokens, start_tag_line(read_span(c.src, tok.name), attrs, .Self_Closing in tok.flags))
	case .End_Tag:
		flush_text(c)
		append(&c.tokens, fmt.aprintf("EndTag %q", read_span(c.src, tok.name)))
	case .Comment:
		flush_text(c)
		append(&c.tokens, fmt.aprintf("Comment %q", read_span(c.src, tok.data)))
	case .Doctype:
		flush_text(c)
		append(&c.tokens, doctype_line(field_span(c.src, tok.name), field_span(c.src, tok.public_id), field_span(c.src, tok.system_id), .Force_Quirks not_in tok.flags))
	case .Instruction:
		flush_text(c)
		append(&c.tokens, fmt.aprintf("ProcessingInstruction %q %q", read_span(c.src, tok.name), read_span(c.src, tok.data)))
	}
	return .Next
}

@(private)
read_span :: proc(src: []u8, s: html.Internal_Span) -> string {
	return strings.clone(html.internal_decode(src, s, make([]u8, html.internal_decode_room(s))))
}

@(private = "file")
field_span :: proc(src: []u8, s: html.Internal_Span) -> Maybe(string) {
	if .Missing in s.flags {
		return nil
	}
	return read_span(src, s)
}

@(private)
flush_text :: proc(c: ^Collector) {
	if strings.builder_len(c.text) > 0 {
		append(&c.tokens, fmt.aprintf("Character %q", strings.to_string(c.text)))
		strings.builder_reset(&c.text)
	}
}

@(private = "file")
start_tag_line :: proc(name: string, attrs: []string, self_closing: bool) -> string {
	slice.sort(attrs)
	return fmt.aprintf("StartTag %q {{%s}}%s", name, strings.join(attrs, " "), " /" if self_closing else "")
}

@(private = "file")
doctype_line :: proc(name, public_id, system_id: Maybe(string), correct: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "DOCTYPE")
	for fld in ([?]Maybe(string){name, public_id, system_id}) {
		str, ok := fld.?
		fmt.sbprintf(&b, " %q" if ok else " null", str)
	}
	fmt.sbprintf(&b, " %v", correct)
	return strings.to_string(b)
}

@(private = "file")
error_line :: proc(src: []u8, d: html.Detail, at: u64) -> string {
	code, _ := strings.replace_all(strings.to_lower(fmt.tprint(d)), "_", "-")
	line, col := 1, 1
	for i := 0; i < int(at); i += 1 {
		c := src[i]
		switch {
		case c == '\n' || c == '\r':
			line, col = line + 1, 1
			if c == '\r' && i + 1 < int(at) && src[i + 1] == '\n' {
				i += 1
			}
		case c >= 0xF0:
			col += 2
		case c & 0xC0 != 0x80:
			col += 1
		}
	}
	return fmt.aprintf("%s %d:%d", code, line, col)
}

@(private = "file")
parse_hex4 :: proc(s: string) -> (u32, bool) {
	if len(s) < 6 || s[0] != '\\' || s[1] != 'u' {
		return 0, false
	}
	v := u32(0)
	for i in 2 ..< 6 {
		c := s[i]
		d: u32
		switch c {
		case '0' ..= '9':
			d = u32(c - '0')
		case 'a' ..= 'f':
			d = u32(c - 'a' + 10)
		case 'A' ..= 'F':
			d = u32(c - 'A' + 10)
		case:
			return 0, false
		}
		v = (v << 4) | d
	}
	return v, true
}

@(private = "file")
unescape_double :: proc(s: string) -> (string, bool) {
	b := strings.builder_make()
	for i := 0; i < len(s); {
		v, ok := parse_hex4(s[i:])
		if !ok {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		i += 6
		if v >= 0xD800 && v <= 0xDBFF {
			lo, low := parse_hex4(s[i:])
			if !low || lo < 0xDC00 || lo > 0xDFFF {
				return "", false
			}
			i += 6
			v = 0x10000 + (v - 0xD800) << 10 + (lo - 0xDC00)
		} else if v >= 0xDC00 && v <= 0xDFFF {
			return "", false
		}
		strings.write_rune(&b, rune(v))
	}
	return strings.to_string(b), true
}

@(private = "file")
Tok_State :: struct {
	name:  string,
	start: html.Internal_Content,
}

@(private = "file")
STATES := [?]Tok_State {
	{"Data state", .Data},
	{"PLAINTEXT state", .Plaintext},
	{"RCDATA state", .Rcdata},
	{"RAWTEXT state", .Rawtext},
	{"Script data state", .Script_Data},
	{"CDATA section state", .Cdata_Section},
}

@(private = "file")
unescape_if_double :: proc(v: json.Value, double: bool) -> (s: string, ok: bool) {
	s = v.(json.String) or_return
	if double {
		return unescape_double(s)
	}
	return s, true
}

@(private = "file")
expected_tokens :: proc(output: json.Array, double: bool) -> (lines: [dynamic]string, ok: bool) {
	text := strings.builder_make()
	for v in output {
		tok := v.(json.Array) or_return
		kind := tok[0].(json.String) or_return
		if kind == "Character" {
			strings.write_string(&text, unescape_if_double(tok[1], double) or_return)
			continue
		}
		if strings.builder_len(text) > 0 {
			append(&lines, fmt.aprintf("Character %q", strings.to_string(text)))
			strings.builder_reset(&text)
		}
		switch kind {
		case "StartTag":
			obj := tok[2].(json.Object) or_return
			attrs := make([dynamic]string)
			for k, a in obj {
				key := k
				if double {
					key = unescape_double(k) or_return
				}
				append(&attrs, fmt.aprintf("%q=%q", key, unescape_if_double(a, double) or_return))
			}
			self := len(tok) > 3 && is_json_true(tok[3])
			append(&lines, start_tag_line(unescape_if_double(tok[1], double) or_return, attrs[:], self))
		case "EndTag":
			append(&lines, fmt.aprintf("EndTag %q", unescape_if_double(tok[1], double) or_return))
		case "Comment":
			append(&lines, fmt.aprintf("Comment %q", unescape_if_double(tok[1], double) or_return))
		case "DOCTYPE":
			flds: [3]Maybe(string)
			for idx in 0 ..< 3 {
				if _, null := tok[1 + idx].(json.Null); !null {
					flds[idx] = unescape_if_double(tok[1 + idx], double) or_return
				}
			}
			append(&lines, doctype_line(flds[0], flds[1], flds[2], tok[4].(json.Boolean) or_return))
		case "ProcessingInstruction":
			append(&lines, fmt.aprintf("ProcessingInstruction %q %q", unescape_if_double(tok[1], double) or_return, unescape_if_double(tok[2], double) or_return))
		case:
			return
		}
	}
	if strings.builder_len(text) > 0 {
		append(&lines, fmt.aprintf("Character %q", strings.to_string(text)))
	}
	return lines, true
}

@(private = "file")
is_json_true :: proc(v: json.Value) -> bool {
	b, ok := v.(json.Boolean)
	return ok && bool(b)
}

@(private = "file")
Tally :: struct {
	runs, skipped: int,
}

@(private = "file")
run_tok_file :: proc(t: ^testing.T, file: string) -> (tally: Tally) {
	arena: runtime.Arena
	if !testing.expect(t, runtime.arena_init(&arena, 0, context.allocator) == nil) {
		return
	}
	defer runtime.arena_destroy(&arena)
	context.allocator = runtime.arena_allocator(&arena)
	data: []u8
	for f in TOKENIZER {
		if f.name == file {
			data = f.data
		}
	}
	root, err := json.parse(data)
	if !testing.expectf(t, err == nil, "%s: %v", file, err) {
		return
	}
	for key, list in root.(json.Object) {
		for v in list.(json.Array) {
			c := v.(json.Object)
			description := c["description"].(json.String)
			if is_skipped_case(file, description) {
				tally.skipped += 1
				continue
			}
			double := is_json_true(c["doubleEscaped"])
			input, plain := c["input"].(json.String)
			if double {
				input, plain = unescape_double(input)
			}
			if !plain {
				tally.skipped += 1
				continue
			}
			want, ok := expected_tokens(c["output"].(json.Array), double)
			if !testing.expectf(t, ok, "%s %s: unread output", file, description) {
				continue
			}
			want_errors := make([dynamic]string)
			if errors, has := c["errors"].(json.Array); has {
				for e in errors {
					o := e.(json.Object)
					append(&want_errors, fmt.aprintf("%s %d:%d", o["code"].(json.String), i64(o["line"].(json.Float)), i64(o["col"].(json.Float))))
				}
			}
			last, _ := c["lastStartTag"].(json.String)
			states := []json.Value{json.String("Data state")}
			if named, has := c["initialStates"].(json.Array); has {
				states = named[:]
			}
			for st in states {
				start, found := initial_tok_state(st.(json.String))
				if !testing.expectf(t, found, "%s %s: state %v", file, description, st) {
					continue
				}
				col := Collector{src = transmute([]u8)input, alloc = context.allocator}
				strings.builder_init(&col.text)
				hi, fault, stopped := html.internal_tokenize(transmute([]u8)input, &col, collect, start, last)
				testing.expectf(t, fault == nil && !stopped && hi == u64(len(input)), "%s %s: %v %v %v", file, description, hi, fault, stopped)
				flush_text(&col)
				testing.expectf(t, slice.equal(col.tokens[:], want[:]), "%s %s (%s, %s) %q:\n got %v\nwant %v", file, description, key, st, input, col.tokens, want)
				testing.expectf(t, slice.equal(col.errors[:], want_errors[:]), "%s %s (%v) %q:\n got errors %v\nwant errors %v", file, description, st, input, col.errors, want_errors)
				tally.runs += 1
			}
		}
	}
	return
}

@(private = "file")
is_skipped_case :: proc(file, description: string) -> bool {
	for s in SKIPPED {
		if s.file == file && (s.description == "*" || s.description == description) {
			return true
		}
	}
	return false
}

@(private = "file")
initial_tok_state :: proc(name: string) -> (html.Internal_Content, bool) {
	for s in STATES {
		if s.name == name {
			return s.start, true
		}
	}
	return .Data, false
}

@(test)
html5lib_tokenizer :: proc(t: ^testing.T) {
	testkit.deadline(t)
	total: Tally
	for f in TOKENIZER {
		if !strings.has_suffix(f.name, ".test") {
			continue
		}
		got := run_tok_file(t, f.name)
		total.runs += got.runs
		total.skipped += got.skipped
	}
	testing.expect_value(t, total, Tally{runs = 7042, skipped = 8})
}
