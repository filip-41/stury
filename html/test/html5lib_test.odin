// Runs every case of the html5lib tokenizer tests from each of its initial states: the tokens and the parse errors,
// with their lines and columns, must be the ones the case lists.
package html_tests

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:testing"
import html ".."

@(private)
TOKENIZER := #load_directory("conformance/html5lib/tokenizer")

// The cases left out, by file and description, and why. The four doubly escaped cases whose input holds a lone
// surrogate are left out too: no UTF-8 input stream holds one.
@(private)
SKIPPED := [?]struct {
	file, description, reason: string,
} {
	// xmlViolation.test holds the tokens an XML infoset coercion makes, which is no tokenizer's output.
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
collect :: proc "contextless" (c: ^Collector, t: ^html.Internal_Token) -> html.Internal_Action {
	context = runtime.default_context()
	context.allocator = c.alloc
	switch t.kind {
	case .Error:
		append(&c.errors, error_line(c.src, t.detail, t.lo))
	case .Text:
		strings.write_string(&c.text, read(c.src, t.data))
	case .Start_Tag:
		flush_text(c)
		attrs := make([]string, len(t.attrs))
		for a, i in t.attrs {
			attrs[i] = fmt.aprintf("%q=%q", read(c.src, a.name), read(c.src, a.value))
		}
		append(&c.tokens, start_tag_line(read(c.src, t.name), attrs, .Self_Closing in t.flags))
	case .End_Tag:
		flush_text(c)
		append(&c.tokens, fmt.aprintf("EndTag %q", read(c.src, t.name)))
	case .Comment:
		flush_text(c)
		append(&c.tokens, fmt.aprintf("Comment %q", read(c.src, t.data)))
	case .Doctype:
		flush_text(c)
		append(&c.tokens, doctype_line(field(c.src, t.name), field(c.src, t.public_id), field(c.src, t.system_id), .Force_Quirks not_in t.flags))
	case .Instruction:
		flush_text(c)
		append(&c.tokens, fmt.aprintf("ProcessingInstruction %q %q", read(c.src, t.name), read(c.src, t.data)))
	}
	return .Next
}

@(private)
read :: proc(src: []u8, s: html.Internal_Span) -> string {
	return strings.clone(html.internal_decode(src, s, make([]u8, html.internal_decode_room(s))))
}

@(private)
field :: proc(src: []u8, s: html.Internal_Span) -> Maybe(string) {
	if .Missing in s.flags {
		return nil
	}
	return read(src, s)
}

@(private)
flush_text :: proc(c: ^Collector) {
	if strings.builder_len(c.text) > 0 {
		append(&c.tokens, fmt.aprintf("Character %q", strings.to_string(c.text)))
		strings.builder_reset(&c.text)
	}
}

@(private)
start_tag_line :: proc(name: string, attrs: []string, self_closing: bool) -> string {
	slice.sort(attrs)
	return fmt.aprintf("StartTag %q {{%s}}%s", name, strings.join(attrs, " "), " /" if self_closing else "")
}

@(private)
doctype_line :: proc(name, public_id, system_id: Maybe(string), correct: bool) -> string {
	b := strings.builder_make()
	strings.write_string(&b, "DOCTYPE")
	for f in ([?]Maybe(string){name, public_id, system_id}) {
		s, ok := f.?
		fmt.sbprintf(&b, " %q" if ok else " null", s)
	}
	fmt.sbprintf(&b, " %v", correct)
	return strings.to_string(b)
}

// The error's code, the standard's spelling, and its line and column, which count UTF-16 code units from 1, a CR LF
// pair as one line break.
@(private)
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

// Replaces the `\uHHHH` escapes of a doubly escaped case. A lone surrogate, which UTF-8 cannot hold, answers false.
@(private)
unescape :: proc(s: string) -> (string, bool) {
	b := strings.builder_make()
	hex :: proc(s: string) -> (u32, bool) {
		if len(s) < 6 || s[0] != '\\' || s[1] != 'u' {
			return 0, false
		}
		v: u32
		for c in transmute([]u8)s[2:6] {
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
			v = v << 4 | d
		}
		return v, true
	}
	for i := 0; i < len(s); {
		v, ok := hex(s[i:])
		if !ok {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		i += 6
		if v >= 0xD800 && v <= 0xDBFF {
			lo, low := hex(s[i:])
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

@(private)
State :: struct {
	name:  string,
	start: html.Internal_Content,
}

@(private)
STATES := [?]State {
	{"Data state", .Data},
	{"PLAINTEXT state", .Plaintext},
	{"RCDATA state", .Rcdata},
	{"RAWTEXT state", .Rawtext},
	{"Script data state", .Script_Data},
	{"CDATA section state", .Cdata_Section},
}

// The expected tokens of a case, in the collector's spelling, adjacent characters joined.
@(private)
expected_tokens :: proc(output: json.Array, double: bool) -> (lines: [dynamic]string, ok: bool) {
	text := strings.builder_make()
	str :: proc(v: json.Value, double: bool) -> (s: string, ok: bool) {
		s = v.(json.String) or_return
		if double {
			return unescape(s)
		}
		return s, true
	}
	for v in output {
		tok := v.(json.Array) or_return
		kind := tok[0].(json.String) or_return
		if kind == "Character" {
			strings.write_string(&text, str(tok[1], double) or_return)
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
					key = unescape(k) or_return
				}
				append(&attrs, fmt.aprintf("%q=%q", key, str(a, double) or_return))
			}
			self := len(tok) > 3 && is_true(tok[3])
			append(&lines, start_tag_line(str(tok[1], double) or_return, attrs[:], self))
		case "EndTag":
			append(&lines, fmt.aprintf("EndTag %q", str(tok[1], double) or_return))
		case "Comment":
			append(&lines, fmt.aprintf("Comment %q", str(tok[1], double) or_return))
		case "DOCTYPE":
			f: [3]Maybe(string)
			for i in 0 ..< 3 {
				if _, null := tok[1 + i].(json.Null); !null {
					f[i] = str(tok[1 + i], double) or_return
				}
			}
			append(&lines, doctype_line(f[0], f[1], f[2], tok[4].(json.Boolean) or_return))
		case "ProcessingInstruction":
			append(&lines, fmt.aprintf("ProcessingInstruction %q %q", str(tok[1], double) or_return, str(tok[2], double) or_return))
		case:
			return
		}
	}
	if strings.builder_len(text) > 0 {
		append(&lines, fmt.aprintf("Character %q", strings.to_string(text)))
	}
	return lines, true
}

@(private)
is_true :: proc(v: json.Value) -> bool {
	b, ok := v.(json.Boolean)
	return ok && bool(b)
}

@(private)
Tally :: struct {
	runs, skipped: int,
}

// Runs the cases of one file, each from every initial state it names.
@(private)
run_file :: proc(t: ^testing.T, file: string) -> (tally: Tally) {
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {
		return
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
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
			if skipped(file, description) {
				tally.skipped += 1
				continue
			}
			double := is_true(c["doubleEscaped"])
			input, plain := c["input"].(json.String)
			if double {
				input, plain = unescape(input)
			}
			if !plain {
				// A lone surrogate, which no UTF-8 input stream holds.
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
			for s in states {
				start, found := initial_state(s.(json.String))
				if !testing.expectf(t, found, "%s %s: state %v", file, description, s) {
					continue
				}
				col := Collector{src = transmute([]u8)input, alloc = context.allocator}
				strings.builder_init(&col.text)
				hi, fault, stopped := html.internal_tokenize(transmute([]u8)input, &col, collect, start, last)
				testing.expectf(t, fault == nil && !stopped && hi == u64(len(input)), "%s %s: %v %v %v", file, description, hi, fault, stopped)
				flush_text(&col)
				testing.expectf(t, slice.equal(col.tokens[:], want[:]), "%s %s (%s, %s) %q:\n got %v\nwant %v", file, description, key, s, input, col.tokens, want)
				testing.expectf(t, slice.equal(col.errors[:], want_errors[:]), "%s %s (%v) %q:\n got errors %v\nwant errors %v", file, description, s, input, col.errors, want_errors)
				tally.runs += 1
			}
		}
	}
	return
}

@(private)
skipped :: proc(file, description: string) -> bool {
	for s in SKIPPED {
		if s.file == file && (s.description == "*" || s.description == description) {
			return true
		}
	}
	return false
}

@(private)
initial_state :: proc(name: string) -> (html.Internal_Content, bool) {
	for s in STATES {
		if s.name == name {
			return s.start, true
		}
	}
	return .Data, false
}

@(test)
html5lib_tokenizer :: proc(t: ^testing.T) {
	total: Tally
	for f in TOKENIZER {
		if !strings.has_suffix(f.name, ".test") {
			continue
		}
		got := run_file(t, f.name)
		total.runs += got.runs
		total.skipped += got.skipped
	}
	testing.expect_value(t, total, Tally{runs = 7042, skipped = 8})
}
