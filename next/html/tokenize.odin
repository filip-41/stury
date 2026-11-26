package html

import "base:intrinsics"
import "base:runtime"
import "stury:lib/base/kernel"
import "stury:lib/base/spell"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// HTML5 tokenizer: the states of section 13.2.5 (`states.odin`) and character references (`refs.odin`).
// Reads UTF-8 from byte `from`, returning a `hook.Walk_Result` offset/fault. Allocates zero memory until an element
// exceeds `ATTRS_INLINE` (16) attributes, then uses the passed `allocator` via `ctx` (never `default_context`).

@(private)
Content :: enum u8 {
	Data,
	Rcdata,
	Rawtext,
	Script_Data,
	Plaintext,
	Cdata_Section,
}

@(private)
Html_Token_Kind :: enum u8 {
	Text,
	Start_Tag,
	End_Tag,
	Comment,
	Doctype,
	Instruction,
	Error,
}

@(private)
Token_Flag :: enum u8 {
	Self_Closing,
	Force_Quirks,
}

@(private)
Mode :: enum u8 {
	Data,
	Text,
	Rcdata,
	Raw,
	Verbatim,
	Name,
	Value,
}

@(private)
Span_Flag :: enum u8 {
	Ref,
	Nul,
	Upper,
	Cr,
	Invalid,
	Missing,
}

@(private)
Span_Flags :: bit_set[Span_Flag; u8]

@(private)
Span :: struct {
	lo:    u64,
	n:     u32,
	mode:  Mode,
	flags: Span_Flags,
}

@(private)
Attribute :: struct {
	name, value: Span,
}

@(private)
Html_Token :: struct {
	lo, hi:               u64,
	name, data:           Span,
	public_id, system_id: Span,
	attrs:                []Attribute,
	kind:                 Html_Token_Kind,
	flags:                bit_set[Token_Flag; u8],
	detail:               Detail,
}

@(private)
Token_Action :: enum u8 {
	Next,
	Stop,
	Rcdata,
	Rawtext,
	Script_Data,
	Plaintext,
	Foreign,
	Html,
}

@(private)
tokenize :: proc(
	src: []u8,
	h: ^$H,
	$on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action,
	start := Content.Data,
	last_start_tag := "",
	from := u64(0),
	in_foreign := false,
	allocator := context.allocator,
	ctx: ^runtime.Context = nil,
) -> (
	hi: u64,
	err: tape.Error,
	stopped: bool,
) {
	t: Tokenizer(H)
	local := context
	t.ctx = ctx^ if ctx != nil else local
	t.h = h
	t.base = raw_data(src)
	start_at := min(from, u64(len(src)))
	t.text_lo = start_at
	t.judged = start_at
	t.in_foreign = in_foreign
	t.attrs = t.inline[:]
	t.allocator = allocator
	t.last = transmute([]u8)last_start_tag
	t.last_set = len(last_start_tag) > 0
	t.last_plain = true
	t.content = start
	t.text_mode = content_mode(start)
	p := raw_data(src)[start_at:]
	end := raw_data(src)[len(src):]
	r: u64
	switch start {
	case .Data:          r = st_data(p, end, &t, on)
	case .Rcdata:        r = st_rcdata(p, end, &t, on)
	case .Rawtext:       r = st_rawtext(p, end, &t, on)
	case .Script_Data:   r = st_script(p, end, &t, on)
	case .Plaintext:     r = st_plaintext(p, end, &t, on)
	case .Cdata_Section: r = st_cdata(p, end, &t, on)
	}
	delete(t.heap, t.allocator)
	delete(t.hash, t.allocator)
	return hook.walk_error(hook.Walk_Result(r), &RULES)
}

@(private)
decode_room :: proc "contextless" (s: Span) -> int {
	return int(s.n) * 3
}

@(private)
Tokenizer :: struct($H: typeid) {
	h:          ^H,
	base:       [^]u8,
	tok:        Html_Token,
	text_lo:    u64,
	text_hi:    u64,
	lo:         u64,
	mark:       u64,
	judged:     u64,
	text_flags: Span_Flags,
	flags:      Span_Flags,
	text_mode:  Mode,
	content:    Content,
	back:       Back,
	ret:        Return,
	quote:      u8,
	system:     bool,
	in_foreign: bool,
	kept:       bool,
	wide:       bool,
	oom:        bool,
	last_set:   bool,
	last_plain: bool,
	last:       []u8,
	attr_n:     int,
	attrs:      []Attribute,
	heap:       []Attribute,
	hash:       []u32,
	allocator:  runtime.Allocator,
	ctx:        runtime.Context,
	inline:     [ATTRS_INLINE]Attribute,
}

@(private)
ATTRS_INLINE :: 16

@(private)
Back :: enum u8 {
	Rcdata,
	Rawtext,
	Script,
	Escaped,
}

@(private)
Return :: enum u8 {
	Data,
	Rcdata,
	Double,
	Single,
	Unquoted,
}

@(private)
STATE_TIER :: kernel.Tier(0)
@(private)
STATE_FEATURES :: kernel.FEATURES[STATE_TIER]

@(private)
C_WS :: 0x01
@(private)
C_UPPER :: 0x02
@(private)
C_LOWER :: 0x04
@(private)
C_DIGIT :: 0x08
@(private)
C_JUDGE :: 0x20
@(private)
C_TAG_END :: 0x40
@(private)
C_ATTR_END :: 0x80

@(private)
C_ALPHA :: C_UPPER | C_LOWER
@(private)
C_ALNUM :: C_ALPHA | C_DIGIT

@(private, rodata)
CLASS := [256]u8 {
	0x00          = C_TAG_END,
	0x01 ..= 0x08 = C_JUDGE,
	'\t'          = C_WS,
	'\n'          = C_WS,
	0x0B          = C_JUDGE,
	0x0C          = C_WS,
	'\r'          = C_WS | C_JUDGE,
	0x0E ..= 0x1F = C_JUDGE,
	' '           = C_WS,
	'"'           = C_ATTR_END,
	'\''          = C_ATTR_END,
	'/'           = C_TAG_END,
	'0' ..= '9'   = C_DIGIT,
	'<'           = C_ATTR_END,
	'='           = C_ATTR_END,
	'>'           = C_TAG_END,
	'A' ..= 'Z'   = C_UPPER,
	'a' ..= 'z'   = C_LOWER,
	0x7F          = C_JUDGE,
	0x80 ..= 0xFF = C_JUDGE,
}

@(private, rodata)
STOP_DATA := kernel.Nibble_Table {
	lo = {0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x07, 0x03, 0x03, 0x02, 0x02, 0x03, 0x0a, 0x03, 0x03, 0x13},
	hi = {0x01, 0x02, 0x04, 0x08, 0x00, 0x00, 0x00, 0x10, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02},
}
@(private, rodata)
STOP_RAW := kernel.Nibble_Table {
	lo = {0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x02, 0x02, 0x03, 0x06, 0x03, 0x03, 0x0b},
	hi = {0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x08, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02},
}
@(private, rodata)
STOP_PLAIN := kernel.Nibble_Table {
	lo = {0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x02, 0x02, 0x03, 0x02, 0x03, 0x03, 0x07},
	hi = {0x01, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02},
}
@(private, rodata)
STOP_DASH := kernel.Nibble_Table {
	lo = {0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x02, 0x02, 0x03, 0x0a, 0x07, 0x03, 0x13},
	hi = {0x01, 0x02, 0x04, 0x08, 0x00, 0x00, 0x00, 0x10, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02},
}
@(private, rodata)
STOP_CDATA := kernel.Nibble_Table {
	lo = {0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x02, 0x02, 0x03, 0x02, 0x07, 0x03, 0x0b},
	hi = {0x01, 0x02, 0x00, 0x00, 0x00, 0x04, 0x00, 0x08, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02},
}
@(private, rodata)
STOP_BOGUS := kernel.Nibble_Table {
	lo = {0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x02, 0x02, 0x03, 0x02, 0x03, 0x07, 0x0b},
	hi = {0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x08, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02},
}
@(private, rodata)
STOP_DOUBLE := kernel.Nibble_Table {
	lo = {0x03, 0x03, 0x07, 0x03, 0x03, 0x03, 0x07, 0x03, 0x03, 0x02, 0x02, 0x03, 0x02, 0x03, 0x03, 0x0b},
	hi = {0x01, 0x02, 0x04, 0x00, 0x00, 0x00, 0x00, 0x08, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02},
}
@(private, rodata)
STOP_SINGLE := kernel.Nibble_Table {
	lo = {0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x07, 0x07, 0x03, 0x02, 0x02, 0x03, 0x02, 0x03, 0x03, 0x0b},
	hi = {0x01, 0x02, 0x04, 0x00, 0x00, 0x00, 0x00, 0x08, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02},
}
@(private, rodata)
STOP_PI := kernel.Nibble_Table {
	lo = {0x02, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x03, 0x02, 0x02, 0x03, 0x02, 0x03, 0x07, 0x0f},
	hi = {0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0x00, 0x08, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02},
}

@(private)
stop_at :: #force_inline proc "contextless" (p, end: [^]u8, table: kernel.Nibble_Table) -> [^]u8 #no_bounds_check {
	q := p
	for {
		live := int(intrinsics.ptr_sub(end, q))
		if live >= 64 {
			m := kernel.pack(kernel.has(kernel.classes(STATE_TIER, kernel.load(q), table), 0xFF))
			if m != 0 {
				return q[intrinsics.count_trailing_zeros(m):]
			}
			q = q[64:]
			continue
		}
		if live <= 0 {
			return end
		}
		b := kernel.load_padded(q[:live], 0)
		m := kernel.pack(kernel.has(kernel.classes(STATE_TIER, b, table), 0xFF)) & (u64(1) << uint(live) - 1)
		return q[intrinsics.count_trailing_zeros(m):] if m != 0 else end
	}
}

@(private)
at :: #force_inline proc "contextless" (t: ^Tokenizer($H), p: [^]u8) -> u64 {
	return u64(intrinsics.ptr_sub(p, t.base))
}

@(private)
content_mode :: #force_inline proc "contextless" (c: Content) -> Mode {
	switch c {
	case .Data:                          return .Data
	case .Rcdata:                        return .Rcdata
	case .Rawtext, .Script_Data, .Plaintext: return .Raw
	case .Cdata_Section:                 return .Verbatim
	}
	return .Data
}

@(private)
span_of :: #force_inline proc "contextless" (t: ^Tokenizer($H), lo, hi: u64, mode: Mode, flags: Span_Flags) -> Span {
	t.wide ||= hi - lo > u64(max(u32))
	return {lo = lo, n = u32(hi - lo), mode = mode, flags = flags}
}

@(private)
halt :: proc "contextless" (t: ^Tokenizer($H), q: [^]u8) -> u64 {
	if t.oom {
		return u64(hook.walk_result(0, hook.WALK_NO_MEMORY))
	}
	if t.wide {
		return u64(hook.walk_result(at(t, q), u8(tape.Fault_Kind.Too_Wide)))
	}
	return u64(hook.walk_result(at(t, q), hook.WALK_STOPPED))
}

@(private)
report :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, q: [^]u8, d: Detail) -> bool {
	e := Html_Token{kind = .Error, lo = at(t, q), hi = at(t, q), detail = d}
	return on(t.h, &e) == .Stop
}

@(private)
flush :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, hi, next: u64) -> bool {
	lo := t.text_lo
	t.text_lo = next
	if hi <= lo {
		t.text_flags = {}
		return false
	}
	text := Html_Token{kind = .Text, lo = lo, hi = hi, data = span_of(t, lo, hi, t.text_mode, t.text_flags)}
	t.text_flags = {}
	if t.wide {
		return false
	}
	#partial switch on(t.h, &text) {
	case .Stop:    return true
	case .Foreign: t.in_foreign = true
	case .Html:    t.in_foreign = false
	}
	return false
}

@(private)
emit :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, q: [^]u8) -> bool {
	if flush(t, on, t.text_hi, at(t, q)) || t.wide {
		return true
	}
	t.tok.hi = at(t, q)
	t.content = .Data
	t.text_mode = .Data
	switch on(t.h, &t.tok) {
	case .Next:
	case .Stop:        return true
	case .Rcdata:      t.content, t.text_mode, t.in_foreign = .Rcdata, .Rcdata, false
	case .Rawtext:     t.content, t.text_mode, t.in_foreign = .Rawtext, .Raw, false
	case .Script_Data: t.content, t.text_mode, t.in_foreign = .Script_Data, .Raw, false
	case .Plaintext:   t.content, t.text_mode, t.in_foreign = .Plaintext, .Raw, false
	case .Foreign:     t.in_foreign = true
	case .Html:        t.in_foreign = false
	}
	return false
}

@(private)
finish :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, end: [^]u8, hi: u64) -> u64 {
	flush(t, on, hi, at(t, end))
	out := u8(tape.Fault_Kind.Too_Wide) if t.wide else 0
	return u64(hook.walk_result(at(t, end), out))
}

@(private)
emit_at_end :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, end: [^]u8) -> u64 {
	if emit(t, on, end) {
		return halt(t, end)
	}
	return finish(t, on, end, at(t, end))
}

@(private)
eof_in_tag :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, end: [^]u8) -> u64 {
	if report(t, on, end, .Eof_In_Tag) {
		return halt(t, end)
	}
	return finish(t, on, end, t.text_hi)
}

@(private)
eof_in_pi :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, end: [^]u8) -> u64 {
	q := end
	if name := t.tok.name; name.n > 0 {
		q = t.base[name.lo + u64(name.n):]
	}
	if report(t, on, q, .Eof_In_Processing_Instruction) {
		return halt(t, end)
	}
	return finish(t, on, end, t.text_hi)
}

@(private)
eof_error :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, end: [^]u8, d: Detail) -> u64 {
	if report(t, on, end, d) {
		return halt(t, end)
	}
	return finish(t, on, end, at(t, end))
}

@(private)
eof_in_comment :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, end: [^]u8) -> u64 {
	if report(t, on, end, .Eof_In_Comment) {
		return halt(t, end)
	}
	t.tok.data = span_of(t, t.lo, t.mark, .Raw, t.flags)
	return emit_at_end(t, on, end)
}

@(private)
eof_in_doctype :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, end: [^]u8) -> u64 {
	t.tok.flags += {.Force_Quirks}
	if report(t, on, end, .Eof_In_Doctype) {
		return halt(t, end)
	}
	return emit_at_end(t, on, end)
}

@(private)
doctype_error :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, p, end: [^]u8, d: Detail, consumes: bool) -> bool {
	t.tok.flags += {.Force_Quirks}
	return consumes && judge_first(t, on, p, end) || report(t, on, p, d)
}

@(private)
judge_first :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, p, end: [^]u8) -> bool {
	if p >= end || CLASS[p[0]] & C_JUDGE == 0 {
		return false
	}
	scratch: Span_Flags
	_, stop := judge(t, on, p, end, &scratch)
	return stop
}

@(private)
skip_ws :: #force_inline proc "contextless" (p, end: [^]u8) -> [^]u8 {
	q := p
	for q < end && CLASS[q[0]] & C_WS != 0 {
		q = q[1:]
	}
	return q
}

@(private)
open_comment :: #force_inline proc "contextless" (t: ^Tokenizer($H), lo: u64, p: [^]u8) {
	t.tok = Html_Token{kind = .Comment, lo = lo}
	t.lo = at(t, p)
	t.flags = {}
}

@(private)
is_script :: #force_inline proc "contextless" (t: ^Tokenizer($H), q: [^]u8) -> bool {
	return at(t, q) - t.mark == 6 && fold_equal(t.base[t.mark:], transmute([]u8)string("script"))
}

@(private)
open_id :: #force_inline proc "contextless" (t: ^Tokenizer($H), p: [^]u8) {
	t.quote = p[0]
	t.lo = at(t, p) + 1
	t.flags = {}
}

@(private)
doctype_id :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, p, end: [^]u8) -> (q: [^]u8, stop: bool) {
	q = p
	for q < end {
		c := q[0]
		switch {
		case c == t.quote || c == '>':
			return q, false
		case c == 0:
			t.flags += {.Nul}
			if report(t, on, q, .Unexpected_Null_Character) {
				return q, true
			}
			q = q[1:]
		case CLASS[c] & C_JUDGE != 0:
			n, s := judge(t, on, q, end, &t.flags)
			if s {
				return q, true
			}
			q = q[n:]
		case:
			q = q[1:]
		}
	}
	return q, false
}

@(private)
judge :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, q, end: [^]u8, flags: ^Span_Flags) -> (n: int, stop: bool) {
	c := q[0]
	d := Detail.Control_Character_In_Input_Stream
	switch {
	case c == '\r':
		flags^ += {.Cr}
		return 1, false
	case c < 0x80:
		n = 1
	case:
		r, kind := spell.utf8_char(q, end)
		if kind != .None {
			flags^ += {.Invalid}
			return int(intrinsics.ptr_sub(spell.utf8_subpart(q, end), q)), false
		}
		n = int(intrinsics.ptr_sub(r, q))
		cp := code_point(q, n)
		switch {
		case cp <= 0x9F:
		case cp >= 0xFDD0 && cp <= 0xFDEF || cp & 0xFFFE == 0xFFFE:
			d = .Noncharacter_In_Input_Stream
		case:
			return n, false
		}
	}
	pos := at(t, q)
	if pos < t.judged {
		return n, false
	}
	t.judged = pos + u64(n)
	return n, report(t, on, q, d)
}

@(private)
code_point :: #force_inline proc "contextless" (q: [^]u8, n: int) -> u32 {
	switch n {
	case 2: return u32(q[0] & 0x1F) << 6 | u32(q[1] & 0x3F)
	case 3: return u32(q[0] & 0x0F) << 12 | u32(q[1] & 0x3F) << 6 | u32(q[2] & 0x3F)
	case 4: return u32(q[0] & 0x07) << 18 | u32(q[1] & 0x3F) << 12 | u32(q[2] & 0x3F) << 6 | u32(q[3] & 0x3F)
	}
	return u32(q[0])
}

@(private)
open_tag :: #force_inline proc "contextless" (t: ^Tokenizer($H), kind: Html_Token_Kind, lo: u64, p: [^]u8) {
	t.tok = Html_Token{kind = kind, lo = lo}
	t.attr_n = 0
	t.lo = at(t, p)
	t.flags = {}
}

@(private)
end_name :: #force_inline proc "contextless" (t: ^Tokenizer($H), q: [^]u8) {
	t.tok.name = span_of(t, t.lo, at(t, q), .Name, t.flags)
}

@(private)
emit_tag :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, q: [^]u8) -> bool {
	t.tok.attrs = t.attrs[:t.attr_n]
	if t.tok.kind == .End_Tag {
		if t.attr_n > 0 && report(t, on, q, .End_Tag_With_Attributes) {
			return true
		}
		if .Self_Closing in t.tok.flags && report(t, on, q, .End_Tag_With_Trailing_Solidus) {
			return true
		}
	} else {
		name := t.tok.name
		t.last = t.base[name.lo:][:name.n]
		t.last_set = true
		t.last_plain = name.flags & {.Nul, .Invalid} == {}
	}
	return emit(t, on, q[1:])
}

@(private)
appropriate :: #force_inline proc "contextless" (t: ^Tokenizer($H), q: [^]u8) -> bool {
	n := int(at(t, q) - t.lo)
	if !t.last_set || !t.last_plain || n != len(t.last) {
		return false
	}
	return fold_equal(t.base[t.lo:], t.last)
}

@(private)
fold_equal :: proc "contextless" (a: [^]u8, b: []u8) -> bool {
	for c, i in b {
		x := a[i]
		if x != c && (x | 0x20 != c | 0x20 || CLASS[x] & C_ALPHA == 0) {
			return false
		}
	}
	return true
}

@(private)
open_attr :: #force_inline proc "contextless" (t: ^Tokenizer($H), p: [^]u8) {
	t.lo = at(t, p)
	t.flags = {}
}

@(private)
end_attr_name :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, q: [^]u8) -> bool {
	name := span_of(t, t.lo, at(t, q), .Name, t.flags)
	if repeated(t, name) {
		t.kept = false
		return report(t, on, q, .Duplicate_Attribute)
	}
	if t.attr_n == len(t.attrs) && !grow_attrs(t) {
		return true
	}
	t.attrs[t.attr_n] = {name = name, value = {lo = at(t, q), mode = .Value}}
	t.attr_n += 1
	t.kept = true
	if t.attr_n == ATTRS_INLINE + 1 {
		return !rehash(t)
	}
	if t.attr_n > ATTRS_INLINE {
		hash_attr(t, t.attr_n - 1)
	}
	return false
}

@(private)
end_value :: #force_inline proc "contextless" (t: ^Tokenizer($H), q: [^]u8) {
	if t.kept {
		t.attrs[t.attr_n - 1].value = span_of(t, t.lo, at(t, q), .Value, t.flags)
	}
}

@(private)
repeated :: proc "contextless" (t: ^Tokenizer($H), name: Span) -> bool {
	src := t.base
	if t.attr_n <= ATTRS_INLINE {
		for a in t.attrs[:t.attr_n] {
			if names_equal(src, a.name, name) {
				return true
			}
		}
		return false
	}
	mask := u32(len(t.hash) - 1)
	for i := name_hash(src, name) & mask; t.hash[i] != 0; i = (i + 1) & mask {
		if names_equal(src, t.attrs[t.hash[i] - 1].name, name) {
			return true
		}
	}
	return false
}

@(private)
grow_attrs :: #force_no_inline proc "contextless" (t: ^Tokenizer($H)) -> bool {
	bigger, ok := regrow(&t.ctx, t.attrs, t.heap, 2 * len(t.attrs), t.allocator)
	if !ok {
		t.oom = true
		return false
	}
	t.heap = bigger
	t.attrs = bigger
	return t.attr_n <= ATTRS_INLINE || rehash(t)
}

@(private)
rehash :: #force_no_inline proc "contextless" (t: ^Tokenizer($H)) -> bool {
	room := 2 * len(t.attrs)
	if len(t.hash) != room {
		ok: bool
		t.hash, ok = fresh_hash(&t.ctx, t.hash, room, t.allocator)
		if !ok {
			t.oom = true
			return false
		}
	} else {
		for &k in t.hash {
			k = 0
		}
	}
	for i in 0 ..< t.attr_n {
		hash_attr(t, i)
	}
	return true
}

@(private)
regrow :: proc "contextless" (ctx: ^runtime.Context, kept, heap: []Attribute, n: int, allocator: runtime.Allocator) -> ([]Attribute, bool) {
	context = ctx^
	bigger, err := make([]Attribute, n, allocator)
	if err != nil {
		return nil, false
	}
	copy(bigger, kept)
	delete(heap, allocator)
	return bigger, true
}

@(private)
fresh_hash :: proc "contextless" (ctx: ^runtime.Context, old: []u32, n: int, allocator: runtime.Allocator) -> ([]u32, bool) {
	context = ctx^
	delete(old, allocator)
	table, err := make([]u32, n, allocator)
	return table, err == nil
}

@(private)
hash_attr :: proc "contextless" (t: ^Tokenizer($H), i: int) {
	mask := u32(len(t.hash) - 1)
	k := name_hash(t.base, t.attrs[i].name) & mask
	for t.hash[k] != 0 {
		k = (k + 1) & mask
	}
	t.hash[k] = u32(i + 1)
}

@(private)
names_equal :: proc "contextless" (src: [^]u8, a, b: Span) -> bool {
	if (a.flags | b.flags) & {.Nul, .Invalid} == {} {
		return a.n == b.n && fold_equal(src[a.lo:], src[b.lo:][:b.n])
	}
	i, j: u32
	for {
		x, y := name_char(src, a, &i), name_char(src, b, &j)
		if x != y {
			return false
		}
		if x < 0 {
			return true
		}
	}
}

@(private)
name_hash :: proc "contextless" (src: [^]u8, s: Span) -> u32 {
	h := u32(2166136261)
	i: u32
	for {
		c := name_char(src, s, &i)
		if c < 0 {
			return h
		}
		h = (h ~ u32(c)) * 16777619
	}
}

@(private)
name_char :: proc "contextless" (src: [^]u8, s: Span, i: ^u32) -> rune {
	if i^ >= s.n {
		return -1
	}
	p := src[s.lo + u64(i^):]
	c := p[0]
	switch {
	case c == 0:
		i^ += 1
		return 0xFFFD
	case c < 0x80:
		i^ += 1
		return rune(c | 0x20) if CLASS[c] & C_UPPER != 0 else rune(c)
	}
	end := src[s.lo + u64(s.n):]
	q, kind := spell.utf8_char(p, end)
	if kind != .None {
		i^ += u32(intrinsics.ptr_sub(spell.utf8_subpart(p, end), p))
		return 0xFFFD
	}
	n := int(intrinsics.ptr_sub(q, p))
	i^ += u32(n)
	return rune(code_point(p, n))
}
