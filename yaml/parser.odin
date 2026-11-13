package yaml

import core "../core"

// Where the parser sends a token. It returns false when the walk must stop.
@(private)
Token_Sink :: proc "contextless" (data: rawptr, t: core.Token) -> bool

// A comment held until the node it belongs to is known. `col` is the column of its `#`.
@(private)
Comment :: struct {
	lo:  u64,
	n:   u32,
	col: u32,
}

// An anchor the walk has met. `size` is the bytes a replay of its node reads once it is complete: the node's from `lo`
// and those its own aliases replayed, which `Parser.expanded` held `base` of when the node began. `log` is the range of
// the node's tokens in `Parser.log`.
@(private)
Anchor :: struct {
	name_lo: u64,
	name_n:  u32,
	lo:      u64,
	size:    u64,
	base:    u64,
	log_lo:  int,
	log_hi:  int,
	open:    bool,
}

// A container an anchor was set on, which completes the anchor at its `End`.
@(private)
Open_Anchor :: struct {
	anchor: int,
	depth:  u32,
}

// A tag handle a `%TAG` directive declared, as the spans of its text and of its prefix.
@(private)
Handle :: struct {
	lo, hi:   u64,
	plo, phi: u64,
}

// What the next content line is, as `peek_next` finds it.
@(private)
Line_Kind :: enum u8 {
	Content,
	Marker,
	Eof,
}

@(private)
Line :: struct {
	kind: Line_Kind,
	ind:  int,
	pos:  u64,
	tab:  bool, // a tab stands in the indentation
}

@(private)
Parser :: struct {
	src:        []u8,
	pos:        u64,
	ls:         u64, // the first byte of the line `pos` is on
	depth:      u32,
	max_depth:  u32,
	fail:       u64,
	sink:       Token_Sink,
	data:       rawptr,
	stage:      [dynamic]core.Token,
	staging:    bool,
	pending:    [dynamic]Comment,
	anchors:    [dynamic]Anchor,
	log:        [dynamic]core.Token,
	open:       [dynamic]Open_Anchor,
	handles:    [dynamic]Handle,
	pend_anch:  int, // the anchor the next node token takes, or -1
	tdepth:     u32,
	expanded:   u64, // the bytes the document's replays have read
	limit:      u64, // the most bytes they may read
	last_end:   u64,
	nl:         Line,
	nl_valid:   bool,
	has_yaml:   bool, // the document's `%YAML` directive was seen
	sep_tab:    bool, // the white space before the node being read holds a tab
	directives: bool, // the document has directives
	replaying:  bool, // an alias is sending the tokens of its node
	tag:        Prop, // the tag the next node takes
	merge_keys: bool,
	holding:    bool, // the tokens of a `<<` value are being held
	hold_depth: u32,
	merges:     [dynamic]core.Token,
	blocks:     [dynamic]Block,
	flows:      [dynamic]Flow,
	next:       Next,
	flow_n:     int, // the indentation the outermost flow collection open was read at
	flow_step:  Flow_Step, // the step a paused flow walk takes next
	flow_then:  Flow_Then,
	// A hook stopped a walk that saves a cursor: the walk returns at the next place `read_blocks` can resume from.
	pause:      bool,
	keys:       Key_Table,
	typed:      bool, // a key of the text resolves to no string
	masks:      Masks,
}

@(private)
parser_init :: proc(p: ^Parser, src: []u8, opts: Options, sink: Token_Sink, data: rawptr) {
	p.src = src
	p.masks.at = NO_BLOCK
	p.max_depth = opts.max_depth if opts.max_depth != 0 else core.MAX_DEPTH
	p.sink, p.data = sink, data
	p.pend_anch = -1
	p.limit = opts.alias_limit if opts.alias_limit != 0 else max(ALIAS_FLOOR, ALIAS_RATIO * u64(len(src)))
	p.merge_keys = opts.merge_keys
}

@(private)
parser_destroy :: proc(p: ^Parser) {
	delete(p.stage)
	delete(p.pending)
	delete(p.anchors)
	delete(p.log)
	delete(p.open)
	delete(p.handles)
	delete(p.blocks)
	delete(p.flows)
	keys_destroy(&p.keys)
	delete(p.merges)
}

// The detail of a result with no fault when a walk paused, at the place the cursor's resume continues from.
@(private)
PAUSED :: 2

// Records the fault and returns false.
@(private)
fault :: proc "contextless" (p: ^Parser, at: u64, kind: core.Fault_Kind, detail: Detail = .None) -> bool {
	p.fail = core.fault_at(at, kind, u8(detail))
	return false
}

@(private)
is_white :: #force_inline proc "contextless" (b: u8) -> bool {
	return b == ' ' || b == '\t'
}

@(private)
is_break :: #force_inline proc "contextless" (b: u8) -> bool {
	return b == '\n' || b == '\r'
}

@(private)
is_flow_indicator :: #force_inline proc "contextless" (b: u8) -> bool {
	return b == ',' || b == '[' || b == ']' || b == '{' || b == '}'
}

// The byte at `i`, or 0 past the end. A zero byte in the text is a fault wherever it is read, so 0 stands for the end.
@(private)
at :: #force_inline proc "contextless" (p: ^Parser, i: u64) -> u8 {
	return p.src[i] if i < u64(len(p.src)) else 0
}

// Whether the byte at `i` ends a token: white space, a line break or the end.
@(private)
is_space_at :: #force_inline proc "contextless" (p: ^Parser, i: u64) -> bool {
	return i >= u64(len(p.src)) || is_white(p.src[i]) || is_break(p.src[i])
}

@(private)
at_eof :: #force_inline proc "contextless" (p: ^Parser) -> bool {
	return p.pos >= u64(len(p.src))
}

@(private)
at_eol :: #force_inline proc "contextless" (p: ^Parser) -> bool {
	return p.pos >= u64(len(p.src)) || is_break(p.src[p.pos])
}

@(private)
skip_ws :: #force_inline proc "contextless" (p: ^Parser) {
	for p.pos < u64(len(p.src)) && is_white(p.src[p.pos]) {
		p.pos += 1
	}
}

// Moves past the line break at `pos` and starts the next line.
@(private)
consume_break :: #force_inline proc "contextless" (p: ^Parser) {
	if p.src[p.pos] == '\r' && p.pos + 1 < u64(len(p.src)) && p.src[p.pos + 1] == '\n' {
		p.pos += 1
	}
	p.pos += 1
	p.ls = p.pos
}

// Returns the end of the line break at `i`, or `i` when none starts there.
@(private)
break_end :: #force_inline proc "contextless" (p: ^Parser, i: u64) -> u64 {
	if i >= u64(len(p.src)) {
		return i
	}
	if p.src[i] == '\n' {
		return i + 1
	}
	if p.src[i] == '\r' {
		return i + 2 if i + 1 < u64(len(p.src)) && p.src[i + 1] == '\n' else i + 1
	}
	return i
}

// Judges the character at `i` and returns the byte after it. A fault is recorded and `ok` is false. A line break, a
// tab and a printable ASCII byte take the fast path.
@(private)
step :: #force_inline proc "contextless" (p: ^Parser, i: u64) -> (next: u64, ok: bool) {
	b := p.src[i]
	if b >= 0x20 && b < 0x7f || b == '\t' || b == '\n' || b == '\r' {
		return i + 1, true
	}
	return step_wide(p, i)
}

@(private)
step_wide :: proc "contextless" (p: ^Parser, i: u64) -> (next: u64, ok: bool) {
	src := p.src
	b := src[i]
	if b < 0x80 {
		return i, fault(p, i, .Bad_Char, .Control_Char)
	}
	n: u64
	cp: u32
	switch {
	case b >= 0xc2 && b <= 0xdf:
		n, cp = 2, u32(b & 0x1f)
	case b >= 0xe0 && b <= 0xef:
		n, cp = 3, u32(b & 0x0f)
	case b >= 0xf0 && b <= 0xf4:
		n, cp = 4, u32(b & 0x07)
	case:
		return i, fault(p, i, .Bad_Char, .Invalid_Utf8)
	}
	for k in u64(1) ..< n {
		if i + k >= u64(len(src)) {
			return i, fault(p, i, .Truncated, .Cut_Utf8)
		}
		c := src[i + k]
		if c & 0xc0 != 0x80 {
			return i, fault(p, i, .Bad_Char, .Invalid_Utf8)
		}
		cp = cp << 6 | u32(c & 0x3f)
	}
	min_cp := u32(0x80) if n == 2 else u32(0x800) if n == 3 else u32(0x10000)
	if cp < min_cp || cp > 0x10ffff || cp >= 0xd800 && cp <= 0xdfff {
		return i, fault(p, i, .Bad_Char, .Invalid_Utf8)
	}
	// c-printable, and no byte order mark inside a text.
	printable := cp == 0x85 || cp >= 0xa0 && cp <= 0xd7ff || cp >= 0xe000 && cp <= 0xfffd && cp != 0xfeff || cp >= 0x10000
	if !printable {
		return i, fault(p, i, .Bad_Char, .Control_Char)
	}
	return i + n, true
}

// Returns the column of `i` on the line that starts at `ls`.
@(private)
col_of :: #force_inline proc "contextless" (ls, i: u64) -> int {
	return int(i - ls)
}

// Whether `-`, `?` or `:` at `i` is an indicator, which a space, a break or the end follows.
@(private)
indicator_at :: #force_inline proc "contextless" (p: ^Parser, i: u64) -> bool {
	return is_space_at(p, i + 1)
}

// Sends the pending comments as head comments of the node that follows.
@(private)
flush_pending :: proc(p: ^Parser) -> bool {
	for c in p.pending {
		if !emit_raw(p, core.Token{c.lo, c.n, .Plain, .Comment, core.comment_spelling(1, 0)}) {
			return false
		}
	}
	clear(&p.pending)
	return true
}

// Sends the pending comments at column `col` or more as foot comments of the container that closes.
@(private)
flush_foot :: proc(p: ^Parser, col: int) -> bool {
	kept := 0
	for c, i in p.pending {
		if int(c.col) >= col {
			if !emit_raw(p, core.Token{c.lo, c.n, .Plain, .Comment_Foot, core.comment_spelling(1, 0)}) {
				return false
			}
		} else {
			p.pending[kept] = p.pending[i]
			kept += 1
		}
	}
	resize(&p.pending, kept)
	return true
}

// Sends a token, or holds it while a possible implicit key is read.
@(private)
emit :: proc(p: ^Parser, t: core.Token) -> bool {
	if p.staging {
		append(&p.stage, t)
		return true
	}
	return emit_now(p, t)
}

@(private)
emit_now :: proc(p: ^Parser, t: core.Token) -> bool {
	if len(p.pending) > 0 && t.role != .Comment_Inline && t.role != .Comment_Foot && t.kind != .End {
		flush_pending(p) or_return
	}
	return emit_raw(p, t)
}

// Sends a token past the pending comments, keeping the anchors and the token log. A comment and an anchor fact are not
// counted or logged, since an alias does not read them back.
@(private)
emit_raw :: proc(p: ^Parser, t: core.Token) -> bool {
	#partial switch t.role {
	case .Comment, .Comment_Inline, .Comment_Foot:
		return call_sink(p, t)
	case .Anchor:
		p.pend_anch = len(p.anchors)
		append(&p.anchors, Anchor{name_lo = t.lo + 1, name_n = t.n - 1, lo = t.lo + u64(t.n), base = p.expanded, log_lo = len(p.log), open = true})
		return call_sink(p, t)
	}
	if p.sink != nil && (p.pend_anch >= 0 || len(p.open) > 0) {
		append(&p.log, t)
	}
	if t.role == .Tag || t.role == .Alias {
		if t.role == .Tag {
			p.tag = Prop{t.lo, t.n}
		}
		return call_sink(p, t)
	}
	switch t.kind {
	case .Array, .Object:
		p.tag.n = 0
		if p.merge_keys {
			keys_open(&p.keys, t.kind == .Object)
		}
		p.tdepth += 1
		if p.pend_anch >= 0 {
			append(&p.open, Open_Anchor{p.pend_anch, p.tdepth})
			p.pend_anch = -1
		}
	case .End:
		if p.merge_keys {
			if f := p.keys.frames[len(p.keys.frames) - 1]; f.merge_hi > f.merge_lo {
				merge_apply(p, f) or_return
			}
			keys_close(&p.keys)
		}
		if len(p.open) > 0 && p.open[len(p.open) - 1].depth == p.tdepth {
			complete_anchor(p, pop(&p.open).anchor)
		}
		p.tdepth -= 1
	case .Null, .False, .True, .Number, .Bytes, .String, .Plain:
		if p.tag.n != 0 {
			ct := check_tag(p, t) or_return
			if t.role == .Key {
				return emit_key(p, t, key_tag_bits(ct))
			}
		}
		if t.role == .Key && p.merge_keys {
			key_enter(&p.keys, t, p.src)
		}
		if p.pend_anch >= 0 {
			complete_anchor(p, p.pend_anch)
			p.pend_anch = -1
		}
	}
	p.last_end = t.lo + u64(t.n)
	if t.role == .Key && merge_starts(p, t) {
		merge_hold(p, t)
		return true
	}
	return call_sink(p, t)
}

// Sends key `t` again with `bits` in its tag bits, noting a key that resolves to no string in `Parser.typed`.
@(private)
emit_key :: #force_no_inline proc(p: ^Parser, t: core.Token, bits: u16) -> bool {
	if p.sink != nil && (p.pend_anch >= 0 || len(p.open) > 0) {
		pop(&p.log)
	}
	t := t
	t.spelling = t.spelling &~ KEY_TAGS | bits
	p.typed ||= bits > u16(Key_Tag.Text) << KEY_TAG_SHIFT
	return emit_raw(p, t)
}

// Judges scalar `t` against the core type its tag names, under the document's `%TAG` directives, and returns that type:
// a text the type does not hold is a fault.
@(private)
check_tag :: proc(p: ^Parser, t: core.Token) -> (ct: Core_Type, ok: bool) {
	tag := string(p.src[p.tag.lo:p.tag.lo + u64(p.tag.n)])
	p.tag.n = 0
	handle, suffix := tag_parts(tag)
	prefix: string
	declared := false
	for h in p.handles {
		if string(p.src[h.lo:h.hi]) == handle {
			prefix, declared = string(p.src[h.plo:h.phi]), true
		}
	}
	ct = core_type(handle, suffix, prefix, declared)
	if ct == .None || ct == .Str {
		return ct, true
	}
	stack: [64]u8 = ---
	text := transmute([]u8)scalar_text(p.src, t, stack[:])
	class, _, integer, _ := classify_number(text)
	if !holds(ct, class, integer) {
		return ct, fault(p, t.lo, .Bad_Char, .Tag_Mismatch)
	}
	return ct, true
}

@(private)
complete_anchor :: proc(p: ^Parser, i: int) {
	a := &p.anchors[i]
	a.open = false
	a.size = max(p.pos, a.lo) - a.lo + p.expanded - a.base
	a.log_hi = len(p.log)
}

@(private)
call_sink :: #force_inline proc(p: ^Parser, t: core.Token) -> bool {
	if p.holding {
		merge_take(p, t)
		return true
	}
	if p.sink != nil && !p.sink(p.data, t) {
		p.fail = core.fault_at(t.lo + u64(t.n), .None, core.STOPPED)
		return false
	}
	return true
}

// Sends the held tokens, giving the one at `key` the role `Key` when `key` is not negative, and else the first the
// role `role`.
@(private)
flush_stage :: proc(p: ^Parser, key: int, role := core.Role.Value) -> bool {
	p.staging = false
	patched := key < 0 && role == .Value
	for t, i in p.stage {
		x := t
		if !patched && i >= max(key, 0) && x.role <= .Key {
			x.role = .Key if key >= 0 else role
			if x.kind == .Plain && x.role == .Key {
				x = plain_token(p, x.lo, x.n, .Key, at(p, x.lo), x.spelling)
			}
			patched = true
		}
		emit_now(p, x) or_return
	}
	clear(&p.stage)
	return true
}
