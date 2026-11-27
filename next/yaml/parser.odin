package yaml

import "base:runtime"
import "stury:lib/core/hook"
import "stury:lib/core/tape"

// YAML 1.2 Parser state, UTF-8/character checks, scalar Core Schema & tag resolution, anchor log, and token emission.

@(private)
Token_Sink :: proc "contextless" (data: rawptr, t: tape.Token) -> bool

@(private)
Comment :: struct {
	lo:  u64,
	n:   u32,
	col: u32,
}

@(private)
Anchor :: struct {
	name_lo:   u64,
	name_n:    u32,
	lo:        u64,
	size:      u64,
	base:      u64,
	log_lo:    int,
	log_hi:    int,
	rel_depth: u32,
	open:      bool,
}

@(private)
Open_Anchor :: struct {
	anchor: int,
	depth:  u32,
	peak:   u32,
}

@(private)
Tag_Handle :: struct {
	handle, prefix: string,
}

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
	tab:  bool,
}

@(private)
Parser :: struct {
	using state: Parser_State,
	stage:       [dynamic]tape.Token,
	pending:     [dynamic]Comment,
	anchors:     [dynamic]Anchor,
	names:       map[string]int,
	indexed:     int,
	log:         [dynamic]tape.Token,
	open:        [dynamic]Open_Anchor,
	handles:     [dynamic]Tag_Handle,
	merges:      [dynamic]tape.Token,
	merge_runs:  [dynamic]Merge_Run,
	blocks:      [dynamic]Block,
	flows:       [dynamic]Flow,
	keys:        Key_Table,
}

@(private)
Parser_State :: struct {
	src:                []u8,
	pos:                u64,
	ls:                 u64,
	start:              u64,
	depth:              u32,
	max_depth:          u32,
	tdepth:             u32,
	fail:               hook.Walk_Result,
	sink:               Token_Sink,
	sink_data:          rawptr,
	scratch:            runtime.Allocator,
	staging:            bool,
	pend_anch:          int,
	expanded:           u64,
	limit:              u64,
	last_end:           u64,
	root_close:         u64,
	open_roots:         u64,
	saw_node:           bool,
	nl:                 Line,
	nl_valid:           bool,
	has_yaml:           bool,
	sep_tab:            bool,
	directives:         bool,
	replaying:          bool,
	needs_log:          bool,
	resolve_scalars:    bool,
	dialect:            tape.Yaml_Dialect,
	merge_keys:         bool,
	allow_complex_keys: bool,
	holding:            bool,
	hold_depth:         u32,
	hold_open_n:        int,
	hold_anch_lo:       int,
	hold_log_lo:        int,
	tag:                Prop,
	next:               Next,
	flow_n:             int,
	flow_step:          Flow_Step,
	flow_then:          Flow_Then,
	masks:              Masks,
}

@(private)
parser_init :: proc(
	p: ^Parser,
	src: []u8,
	depth: u32,
	expansion: u64,
	merge_keys: bool,
	allow_complex_keys: bool,
	needs_log: bool,
	resolve_scalars: bool,
	dialect: tape.Yaml_Dialect,
	scratch: runtime.Allocator,
	sink: Token_Sink,
	sink_data: rawptr,
) {
	p.src = src
	p.masks.at = NO_BLOCK
	p.max_depth = depth if depth != 0 else tape.DEFAULT_DEPTH
	p.limit = expansion if expansion != 0 else tape.default_expansion(u64(len(src)))
	p.merge_keys = merge_keys
	p.allow_complex_keys = allow_complex_keys
	p.needs_log = needs_log
	p.resolve_scalars = resolve_scalars
	p.dialect = dialect
	p.scratch = scratch
	p.sink = sink
	p.sink_data = sink_data
	p.pend_anch = -1

	p.stage.allocator = scratch
	p.pending.allocator = scratch
	p.anchors.allocator = scratch
	p.names.allocator = scratch
	p.log.allocator = scratch
	p.open.allocator = scratch
	p.handles.allocator = scratch
	p.merges.allocator = scratch
	p.merge_runs.allocator = scratch
	p.blocks.allocator = scratch
	p.flows.allocator = scratch
	keys_init(&p.keys, scratch)
}

@(private)
parser_destroy :: proc(p: ^Parser) {
	delete(p.stage)
	delete(p.pending)
	delete(p.anchors)
	delete(p.names)
	delete(p.log)
	delete(p.open)
	delete(p.handles)
	delete(p.blocks)
	delete(p.flows)
	keys_destroy(&p.keys)
	delete(p.merge_runs)
	delete(p.merges)
}

@(private)
fault :: #force_inline proc "contextless" (p: ^Parser, offset: u64, kind: tape.Fault_Kind, detail: Detail = .None) -> bool {
	p.fail = hook.walk_result(offset, u8(kind), u8(detail))
	return false
}

@(private)
depth_fault :: #force_inline proc "contextless" (p: ^Parser, offset: u64) -> bool {
	p.fail = hook.walk_result(offset, hook.WALK_TOO_DEEP)
	return false
}

@(private)
oom_fault :: #force_inline proc "contextless" (p: ^Parser, offset: u64) -> bool {
	p.fail = hook.walk_result(offset, hook.WALK_NO_MEMORY)
	return false
}

@(private)
push_comment :: #force_inline proc(p: ^Parser, c: Comment) -> bool {
	if _, err := append(&p.pending, c); err != nil {
		return oom_fault(p, c.lo)
	}
	return true
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

@(private)
at :: #force_inline proc "contextless" (p: ^Parser, i: u64) -> u8 #no_bounds_check {
	return p.src[i] if i < u64(len(p.src)) else 0
}

@(private)
is_space_at :: #force_inline proc "contextless" (p: ^Parser, i: u64) -> bool #no_bounds_check {
	return i >= u64(len(p.src)) || is_white(p.src[i]) || is_break(p.src[i])
}

@(private)
at_eof :: #force_inline proc "contextless" (p: ^Parser) -> bool {
	return p.pos >= u64(len(p.src))
}

@(private)
at_eol :: #force_inline proc "contextless" (p: ^Parser) -> bool #no_bounds_check {
	return p.pos >= u64(len(p.src)) || is_break(p.src[p.pos])
}

@(private)
skip_ws :: #force_inline proc "contextless" (p: ^Parser) #no_bounds_check {
	for p.pos < u64(len(p.src)) && is_white(p.src[p.pos]) {
		p.pos += 1
	}
}

@(private)
consume_break :: #force_inline proc "contextless" (p: ^Parser) #no_bounds_check {
	if p.src[p.pos] == '\r' && p.pos + 1 < u64(len(p.src)) && p.src[p.pos + 1] == '\n' {
		p.pos += 1
	}
	p.pos += 1
	p.ls = p.pos
}

@(private)
break_end :: #force_inline proc "contextless" (p: ^Parser, i: u64) -> u64 #no_bounds_check {
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

@(private)
step :: #force_inline proc "contextless" (p: ^Parser, i: u64) -> (next: u64, ok: bool) #no_bounds_check {
	b := p.src[i]
	if b >= 0x20 && b < 0x7f || b == '\t' || b == '\n' || b == '\r' {
		return i + 1, true
	}
	return step_wide(p, i)
}

@(private)
step_wide :: proc "contextless" (p: ^Parser, i: u64) -> (next: u64, ok: bool) #no_bounds_check {
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
	printable := cp == 0x85 || cp >= 0xa0 && cp <= 0xd7ff || cp >= 0xe000 && cp <= 0xfffd && cp != 0xfeff || cp >= 0x10000
	if !printable {
		return i, fault(p, i, .Bad_Char, .Control_Char)
	}
	return i + n, true
}

@(private)
col_of :: #force_inline proc "contextless" (ls, i: u64) -> int {
	return int(i - ls)
}

@(private)
indicator_at :: #force_inline proc "contextless" (p: ^Parser, i: u64) -> bool {
	return is_space_at(p, i + 1)
}

@(private)
flush_pending :: proc(p: ^Parser, count: int) -> bool {
	for c in p.pending[:count] {
		emit_raw(p, tape.Token{c.lo, c.n, .Plain, .Comment, tape.HASH_COMMENT}) or_return
	}
	remove_range(&p.pending, 0, count)
	return true
}

@(private)
flush_foot :: proc(p: ^Parser, col: int) -> bool {
	kept := 0
	for c, i in p.pending {
		if int(c.col) >= col {
			if !emit_raw(p, tape.Token{c.lo, c.n, .Plain, .Comment_Foot, tape.HASH_COMMENT}) {
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

@(private)
emit :: proc(p: ^Parser, t: tape.Token) -> bool {
	if p.staging {
		if _, err := append(&p.stage, t); err != nil {
			return oom_fault(p, t.lo)
		}
		return true
	}
	return emit_now(p, t)
}

@(private)
emit_now :: proc(p: ^Parser, t: tape.Token) -> bool {
	if len(p.pending) > 0 && t.role != .Comment_Inline && t.role != .Comment_Foot && t.kind != .End {
		flush_pending(p, len(p.pending)) or_return
	}
	return emit_raw(p, t)
}

@(private = "file")
scalar_tail :: #force_inline proc "contextless" (t: tape.Token) -> u64 {
	if t.kind > .Plain {
		return 0
	}
	if t.kind == .Number {
		return u64(number_is_quoted(Number_Spelling(t.spelling & tape.NUMBER_KIND)))
	}
	return u64(t.spelling & tape.SPELLING_QUOTED != 0)
}

@(private)
emit_raw :: proc(p: ^Parser, tok_in: tape.Token) -> bool #no_bounds_check {
	t := tok_in
	#partial switch t.role {
	case .Comment, .Comment_Inline, .Comment_Foot, .Directive:
		return call_sink(p, t)
	case .Anchor:
		p.pend_anch = len(p.anchors)
		a := Anchor {
			name_lo = t.lo + 1,
			name_n  = t.n - 1,
			lo      = t.lo + u64(t.n),
			base    = p.expanded,
			log_lo  = len(p.log),
			open    = true,
		}
		if _, err := append(&p.anchors, a); err != nil {
			return oom_fault(p, t.lo)
		}
		return call_sink(p, t)
	}
	if !p.allow_complex_keys && t.role == .Key && (t.kind == .Array || t.kind == .Object) {
		return fault(p, t.lo, .Bad_Char, .Complex_Key)
	}
	if !p.replaying && t.role <= .Key {
		if p.resolve_scalars {
			if p.tag.n == 0 && t.spelling & tape.SPELLING_DECODE == 0 {
				if t.kind == .Plain {
					if p.dialect == .Core {
						if t.n == 0 || RESOLVABLE_LEAD[p.src[t.lo]] {
							t = resolve_plain_fast(p, t)
						} else {
							t.kind = .String
						}
					} else if p.dialect == .Json {
						t = resolve_plain_json_fast(p, t)
					} else {
						t.kind = .String
					}
				}
			} else if t.kind == .Plain || t.kind == .String {
				if p.dialect == .Failsafe {
					p.tag.n = 0
					t.kind = .String
				} else {
					resolved, ok := resolve_emitted_scalar(p, t)
					if !ok {
						return false
					}
					t = resolved
				}
			}
		} else if p.tag.n != 0 && (t.kind == .Plain || t.kind == .String) {
			if p.dialect == .Failsafe {
				p.tag.n = 0
			} else {
				resolved, ok := resolve_emitted_scalar(p, t)
				if !ok {
					return false
				}
				t = resolved
			}
		}
	}
	if t.role == .Key && merge_starts(p, t) {
		if !p.replaying {
			p.last_end = t.lo + u64(t.n) + scalar_tail(t)
		}
		return merge_hold(p, t)
	}
	if p.needs_log && t.kind != .End {
		log_this := (p.pend_anch >= 0 || len(p.open) > 0) if !p.holding else (p.pend_anch >= p.hold_anch_lo || len(p.open) > p.hold_open_n)
		if log_this {
			if _, err := append(&p.log, t); err != nil {
				return oom_fault(p, t.lo)
			}
		}
	}
	if t.role == .Tag || t.role == .Alias {
		if t.role == .Tag {
			p.tag = Prop{t.lo, t.n}
		}
		return call_sink(p, t)
	}
	switch t.kind {
	case .Array, .Object:
		p.saw_node = true
		p.tag.n = 0
		if p.tdepth >= p.max_depth {
			return depth_fault(p, t.lo)
		}
		p.open_roots += 1
		if p.merge_keys && !p.holding {
			if !keys_open(&p.keys, t.kind == .Object, u32(len(p.merge_runs))) {
				return oom_fault(p, t.lo)
			}
		}
		p.tdepth += 1
		if len(p.open) > 0 && p.tdepth > p.open[len(p.open) - 1].peak {
			p.open[len(p.open) - 1].peak = p.tdepth
		}
		if p.pend_anch >= 0 {
			if _, err := append(&p.open, Open_Anchor{p.pend_anch, p.tdepth, p.tdepth}); err != nil {
				return oom_fault(p, t.lo)
			}
			p.pend_anch = -1
		}
	case .End:
		if p.merge_keys && !p.holding {
			if f := p.keys.frames[len(p.keys.frames) - 1]; f.runs_hi > f.runs_lo {
				merge_apply(p, f) or_return
			}
			keys_close(&p.keys)
		}
		if p.needs_log {
			log_end := (len(p.open) > 0) if !p.holding else (len(p.open) > p.hold_open_n)
			if log_end {
				if _, err := append(&p.log, t); err != nil {
					return oom_fault(p, t.lo)
				}
			}
		}
		if len(p.open) > 0 && p.open[len(p.open) - 1].depth == p.tdepth {
			oa := pop(&p.open)
			if len(p.open) > 0 && oa.peak > p.open[len(p.open) - 1].peak {
				p.open[len(p.open) - 1].peak = oa.peak
			}
			p.anchors[oa.anchor].rel_depth = oa.peak - (oa.depth - 1)
			complete_anchor(p, oa.anchor)
		}
		p.tdepth -= 1
		p.open_roots -= 1
		if p.open_roots == 0 && !p.replaying {
			p.root_close = t.lo + u64(t.n)
		}
	case .Null, .False, .True, .Number, .Bytes, .String, .Plain:
		p.saw_node = true
		if t.role == .Key && p.merge_keys && !p.holding {
			if _, ok := key_enter(&p.keys, t, p.src); !ok {
				return oom_fault(p, t.lo)
			}
		}
		if p.pend_anch >= 0 {
			complete_anchor(p, p.pend_anch)
			p.pend_anch = -1
		}
		if p.open_roots == 0 && !p.replaying {
			p.root_close = t.lo + u64(t.n) + scalar_tail(t)
		}
	}
	if !p.replaying {
		p.last_end = t.lo + u64(t.n) + scalar_tail(t)
	}
	return call_sink(p, t)
}

@(private = "file")
resolve_plain_fast :: #force_inline proc "contextless" (p: ^Parser, t_in: tape.Token) -> tape.Token #no_bounds_check {
	return resolve_plain_lexical(p, t_in, false)
}

@(private = "file")
resolve_plain_json_fast :: #force_inline proc "contextless" (p: ^Parser, t_in: tape.Token) -> tape.Token #no_bounds_check {
	if t_in.n == 0 { t := t_in; t.kind = .String; return t }
	return resolve_plain_lexical(p, t_in, true)
}

@(private = "file")
resolve_plain_lexical :: #force_inline proc "contextless" (p: ^Parser, t_in: tape.Token, $JSON: bool) -> tape.Token #no_bounds_check {
	t := t_in
	span := p.src[t_in.lo:][:t_in.n]
	class: Class
	strict, has_exp, has_point: bool
	int_d, frac_d: u64
	when JSON {
		class, _, int_d, frac_d, has_exp = classify_json_lexical(span)
		strict = true
	} else {
		class, _, strict, int_d, frac_d, has_exp, has_point = classify_number_lexical(span)
	}
	#partial switch class {
	case .Null, .True, .False:
		t.kind = .Null if class == .Null else (.True if class == .True else .False)
		if t.role == .Key { t.spelling |= tape.SPELLING_DECODE }
	case .Inf:     t.kind, t.spelling = .Number, u16(Number_Spelling.Inf)
	case .Nan:     t.kind, t.spelling = .Number, u16(Number_Spelling.Nan)
	case .Hex:     t.kind, t.spelling = .Number, u16(Number_Spelling.Hex)
	case .Octal:   t.kind, t.spelling = .Number, u16(Number_Spelling.Octal)
	case .Decimal:
		t.kind = .Number
		nk := Number_Spelling.Plain if strict else .Decimal
		sp := tape.number_spelling(u16(nk), int_d, frac_d)
		if has_exp { sp |= tape.NUMBER_EXP }
		if has_point { sp |= tape.NUMBER_POINT }
		t.spelling = sp
	case .Text:
		t.kind = .String
	}
	return t
}

// Resolves scalar `t_in` (`.Plain` or `.String` before resolution) against any pending `p.tag` and the active YAML 1.2
// schema dialect (`p.dialect`) into its final typed `tape.Token` (`.Null`, `.False`, `.True`, `.Number`, `.Bytes`, or
// `.String`) and spelling.
@(private)
resolve_emitted_scalar :: proc(p: ^Parser, t_in: tape.Token) -> (t: tape.Token, ok: bool) #no_bounds_check {
	t = t_in
	if p.dialect == .Failsafe {
		p.tag.n = 0
		t.kind = .String
		return t, true
	}
	ct := Core_Type.None
	has_tag := p.tag.n != 0
	if has_tag {
		tag := string(p.src[p.tag.lo:][:p.tag.n])
		p.tag.n = 0
		handle, suffix := tag_parts(tag)
		head := tag_head(handle)
		for h in p.handles {
			if h.handle == handle {
				head = h.prefix
			}
		}
		ct = core_type(head, suffix)
	}
	if t_in.kind == .String && (ct == .None || ct == .Str) {
		t.kind = .String
		return t, true
	}

	raw_head := u64(1 if (t_in.kind == .String && t_in.spelling & tape.SPELLING_QUOTED != 0) else 0)
	fault_at := t_in.lo - raw_head

	if ct == .Str {
		t.kind = .String
		return t, true
	}

	stack: [512]u8 = ---
	text: []u8
	heap_buf: []u8
	defer if heap_buf != nil {
		delete(heap_buf, p.scratch)
	}
	span := p.src[t_in.lo:][:t_in.n]
	if t_in.spelling & tape.SPELLING_DECODE != 0 {
		need := decode_room(p.src, t_in, nil)
		if need <= len(stack) {
			s, dok := decode_scalar_bytes(span, t_in.spelling, stack[:])
			if !dok {
				return t, fault(p, fault_at, .Bad_Char, .Tag_Mismatch)
			}
			text = transmute([]u8)s
		} else {
			mem, merr := runtime.mem_alloc_non_zeroed(need, 1, p.scratch)
			if merr != nil {
				return t, oom_fault(p, fault_at)
			}
			heap_buf = mem
			s, dok := decode_scalar_bytes(span, t_in.spelling, heap_buf)
			if !dok {
				return t, fault(p, fault_at, .Bad_Char, .Tag_Mismatch)
			}
			text = transmute([]u8)s
		}
	} else {
		text = span
	}

	if ct == .Binary {
		_, bok := base64_valid(text)
		if !bok {
			return t, fault(p, fault_at, .Bad_Char, .Tag_Mismatch)
		}
		t.kind = .Bytes
		t.spelling |= tape.SPELLING_DECODE
		return t, true
	}

	class: Class
	integer, strict, has_exp, has_point: bool
	int_d, frac_d: u64
	if p.dialect == .Core {
		class, integer, strict, int_d, frac_d, has_exp, has_point = classify_number_lexical(text)
	} else {
		class, integer, int_d, frac_d, has_exp = classify_json_lexical(text)
		strict = true
	}
	if ct != .None {
		if !holds(ct, class, integer) {
			return t, fault(p, fault_at, .Bad_Char, .Tag_Mismatch)
		}
	}

	st := style_of(t_in.spelling)
	switch {
	case ct == .Null || (!has_tag && ct == .None && t_in.kind == .Plain && class == .Null):
		t.kind = .Null
		if t.role == .Key {
			t.spelling |= tape.SPELLING_DECODE
		} else {
			t.spelling &~= tape.SPELLING_DECODE
		}
		return t, true
	case ct == .Bool || (!has_tag && ct == .None && t_in.kind == .Plain && (class == .True || class == .False)):
		t.kind = .True if class == .True else .False
		if t.role == .Key {
			t.spelling |= tape.SPELLING_DECODE
		} else {
			t.spelling &~= tape.SPELLING_DECODE
		}
		return t, true
	case ct == .Int || ct == .Float || (!has_tag && ct == .None && t_in.kind == .Plain && class >= .Decimal):
		t.kind = .Number
		forced := ct == .Float && (class == .Hex || class == .Octal || class == .Decimal && integer)
		switch st {
		case .Block:
			nk := Number_Spelling.Block_Forced_Float if forced else .Block_Num
			indent_bits := t_in.spelling & (STYLE_EXPLICIT | 0xC7C0)
			t.spelling = u16(nk) | indent_bits
		case .Single, .Double:
			nk: Number_Spelling
			if forced {
				nk = .Quoted_Forced_Float
			} else {
				#partial switch class {
				case .Decimal: nk = .Quoted_Decimal
				case .Hex:     nk = .Quoted_Hex
				case .Octal:   nk = .Quoted_Octal
				case .Inf:     nk = .Quoted_Inf
				case .Nan:     nk = .Quoted_Nan
				}
			}
			t.spelling = u16(nk) | (t_in.spelling & STYLE_MASK)
		case .Plain:
			#partial switch class {
			case .Inf:
				t.spelling = u16(Number_Spelling.Inf)
			case .Nan:
				t.spelling = u16(Number_Spelling.Nan)
			case .Hex:
				t.spelling = u16(Number_Spelling.Forced_Float if forced else Number_Spelling.Hex)
			case .Octal:
				t.spelling = u16(Number_Spelling.Forced_Float if forced else Number_Spelling.Octal)
			case .Decimal:
				nk := Number_Spelling.Forced_Float if forced else (.Plain if strict else .Decimal)
				sp := tape.number_spelling(u16(nk), int_d, frac_d)
				if has_exp {
					sp |= tape.NUMBER_EXP
				}
				if has_point {
					sp |= tape.NUMBER_POINT
				}
				t.spelling = sp
			}
		}
		return t, true
	}

	t.kind = .String
	return t, true
}

@(private)
anchor_name :: #force_inline proc "contextless" (p: ^Parser, a: Anchor) -> string #no_bounds_check {
	return string(p.src[a.name_lo:][:a.name_n])
}

@(private)
complete_anchor :: proc "contextless" (p: ^Parser, i: int) #no_bounds_check {
	a := &p.anchors[i]
	a.open = false
	a.size = max(p.pos, a.lo) - a.lo + p.expanded - a.base
	a.log_hi = len(p.log)
}

@(private)
sink_give :: #force_inline proc(p: ^Parser, t: tape.Token) -> bool {
	if p.sink != nil && !p.sink(p.sink_data, t) {
		if u8(p.fail) == 0 {
			p.fail = hook.walk_result(t.lo + u64(t.n), hook.WALK_STOPPED)
		}
		return false
	}
	return true
}

@(private)
call_sink :: #force_inline proc(p: ^Parser, t: tape.Token) -> bool {
	if p.holding {
		return merge_take(p, t)
	}
	return sink_give(p, t)
}

@(private)
flush_stage :: proc(p: ^Parser, key: int, role := tape.Role.Value) -> bool {
	p.staging = false
	patched := key < 0 && role == .Value
	for t, i in p.stage {
		x := t
		if !patched && i >= max(key, 0) && x.role <= .Key {
			x.role = .Key if key >= 0 else role
			patched = true
		}
		emit_now(p, x) or_return
	}
	clear(&p.stage)
	return true
}
