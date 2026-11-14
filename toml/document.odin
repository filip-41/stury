package toml

import "base:runtime"
import "core:math"
import spell "../core/spell"
import core "../core"
import engine "../core/build"

// TOML's handles, one per spec, which only `as` names. A handle's readers are `READERS` with the services of its spec.
// The two specs share one walk, which reads the spec as a flag, so their services are the same procedures. The tables
// hold pointers to the other tables, so they are set at startup and never written after.
@(private)
HANDLES := [Spec]core.Readers {
	.Toml_1_0 = core.with_services(READERS, &SERVICES[.Toml_1_0]),
	.Toml_1_1 = core.with_services(READERS, &SERVICES[.Toml_1_1]),
}

// The reasons the writer gives a refusal that names none.
@(private)
WRITE_WORDS :: core.Write_Words{"TOML has no spelling for null or for a key a table repeats", "TOML writes a whole document"}

@(private)
SERVICES := [Spec]core.Services {
	.Toml_1_0 = handle_services(.Toml_1_0),
	.Toml_1_1 = handle_services(.Toml_1_1),
}

@(private)
handle_services :: proc "contextless" ($S: Spec) -> core.Services {
	return {
		build    = build_handle,
		validate = edit_validate,
		scan     = scan_text,
		write    = document_write,
		words    = WRITE_WORDS,
		edit     = &EDIT,
		plans    = rawptr(plan_as),
		reads    = reads_of(S),
		tokens   = &TOKENS,
		records  = &FRAMING,
		docs     = record_docs(S),
	}
}

// The readers of a TOML document of either spec: the leaves, with no services. A document an entry point builds holds
// this table, and so does every plan.
@(private, rodata)
READERS := core.Readers {
	text         = token_text,
	key_equals   = spelling_key_equals,
	number       = token_number,
	close_end    = close_end,
	format       = rules_of,
	tag_key      = "toml",
	floats_apart = true,
	holds        = core.COMMENT_FACTS + {.Tag, .Style},
	fact         = spelling_fact,
	tag_fits     = tag_fits,
	tag_meaning  = tag_name_meaning,
}

// TOML's fault table, which names the format whatever the spec.
@(private)
rules_of :: proc "contextless" () -> ^core.Rules {
	return &RULES
}

// The number grammar a token's `spelling` records: a decimal that is also a JSON number, a decimal written with a plus
// sign or underscores, a hex, octal or binary integer, and the two words.
Number_Spelling :: enum u16 {
	Plain   = 0,
	Decimal = 2,
	Hex     = 4,
	Octal   = 6,
	Binary  = 8,
	Inf     = 10,
	Nan     = 12,
}

// Returns the `Number_Spelling` in a token's `spelling`.
@(private)
number_spelling_of :: #force_inline proc "contextless" (spelling: u16) -> Number_Spelling {
	return Number_Spelling(spelling & core.NUMBER_KIND_MASK)
}

// TOML lays out its tables itself, so its writer takes no layout option.
CAPABILITIES :: core.Capabilities {
	writes = {.Ascii, .Sort_Keys, .Respell_Strings},
	framings = {.Concatenated, .Entries},
	specs = Spec,
}

// The handle of a TOML text of `spec` read with `opts`, which reaches every service of the format.
as :: proc "contextless" (spec: Spec, opts := Options{}) -> core.As {
	return {readers = &HANDLES[spec] if spec <= max(Spec) else nil, spec = u8(spec), max_depth = opts.max_depth}
}

// The handle of `spec` read with `opts`, over `READERS`, which holds no services.
@(private)
bound_as :: proc "contextless" (spec: Spec, opts := Options{}) -> core.As {
	return {readers = &READERS, spec = u8(spec), max_depth = opts.max_depth}
}

@(private)
options_of :: #force_inline proc "contextless" (as: core.As) -> Options {
	return {max_depth = as.max_depth}
}

// TOML's `Readers.text`, exported so a caller that knows the format calls it without the table. A bare key and a
// datetime return their span, and a quoted string or key is decoded into `buf`, which holds the span's length at most.
// A container returns false.
token_text :: proc(v: ^core.Token_View, t: core.Token, buf: []u8) -> (s: string, ok: bool) {
	if t.kind > .Plain {
		return "", false
	}
	return decode(v.src[t.lo:t.lo + u64(t.n)], t.spelling, buf)
}

// Whether the decoded text of key `t` is `name`. A key longer than the stack buffer decodes on the heap.
@(private)
spelling_key_equals :: proc "contextless" (v: ^core.Token_View, t: core.Token, name: string) -> bool {
	Key :: struct {
		span:     []u8,
		spelling: u16,
	}
	span := v.src[t.lo:t.lo + u64(t.n)]
	key := Key{span, t.spelling}
	return spell.buffered_equals(len(span), name, &key, proc "contextless" (c: rawptr, buf: []u8) -> (string, bool) {
		k := (^Key)(c)
		return decode(k.span, k.spelling, buf)
	})
}

// TOML's `Readers.number`, the value of the number token `t`: a JSON number for a decimal, the digits' value for a hex,
// octal or binary integer, and a `Float` of infinity or NaN for the two words.
token_number :: proc(v: ^core.Token_View, t: core.Token) -> (core.Number, bool) {
	if t.kind != .Number || t.role != .Value {
		return {}, false
	}
	lo, hi := t.lo, t.lo + u64(t.n)
	switch number_spelling_of(t.spelling) {
	case .Plain:
		n, ok := spell.number_strict(v.src, lo, hi)
		return signed_zero(n, v.src[lo:hi]), ok
	case .Decimal:
		n, ok := decimal_number(v.src[lo:hi])
		return signed_zero(n, v.src[lo:hi]), ok
	case .Hex, .Octal, .Binary:
		return prefixed_number(v.src[lo + 2:hi], t.spelling & core.NUMBER_KIND_MASK), true
	case .Inf:
		inf := math.inf_f64(-1 if v.src[lo] == '-' else 1)
		return {transmute(u64)inf, .Float}, true
	case .Nan:
		return {transmute(u64)math.nan_f64(), .Float}, true
	}
	return {}, false
}

// An integer written `-0` is 0, where JSON's `-0` is a negative zero.
@(private)
signed_zero :: proc "contextless" (n: core.Number, text: []u8) -> core.Number {
	if n.kind != .Float || n.bits != 1 << 63 {
		return n
	}
	for b in text {
		if b == '.' || b | 0x20 == 'e' {
			return n
		}
	}
	return {0, .Int}
}

// The number a decimal spells with a plus sign or underscores: the same digits without them.
@(private)
decimal_number :: proc(text: []u8) -> (core.Number, bool) {
	stack: [128]u8
	buf := stack[:]
	heap: []u8
	if len(text) > len(stack) {
		heap = make([]u8, len(text))
		if heap == nil {
			return {}, false
		}
		buf = heap
	}
	defer delete(heap)
	w := 0
	for b in text {
		if b != '_' && !(b == '+' && w == 0) {
			buf[w] = b
			w += 1
		}
	}
	return spell.number_strict(buf[:w], 0, u64(w))
}

// The integer a hex, octal or binary run of digits spells, which the walk has judged to fit 63 bits.
@(private)
prefixed_number :: proc "contextless" (digits: []u8, form: u16) -> core.Number {
	base := u64(16) if form == NUMBER_HEX else 8 if form == NUMBER_OCTAL else 2
	value: u64
	for b in digits {
		if b != '_' {
			d, _ := digit_in_base(b, base)
			value = value * base + d
		}
	}
	return {value, .Int}
}

// `build_text` as `Services.build` takes it. A repeated key is a fault of the grammar, so there is no repeat to refuse.
@(private)
build_handle :: proc(src: []u8, as: core.As, _: bool, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	return build_text(src, as, allocator)
}

// Reads `src` into a document that holds the handle `handle`: the text is read into the table tree once, and the tree
// is replayed twice, to size the document and to write it. A repeated key is a fault of the grammar, so a build has no
// duplicate policy to refuse.
@(private)
build_text :: proc(src: []u8, handle: core.As, allocator: runtime.Allocator) -> (core.Document, core.Document_Error) {
	p: Parser
	defer parser_destroy(&p)
	if e := parse_text(&p, src, handle); e.kind != .None {
		return {}, e
	}
	count: engine.Count
	counted: core.Hook_Regs
	sizing, writing: Replay
	defer delete(sizing.frames)
	defer delete(writing.frames)
	replay(&p, &sizing, &count, &counted, engine.builder_hook_count)
	b := engine.builder_start(src, handle, false, allocator, count.nodes, count.deepest, count.facts)
	if len(b.doc.nodes) == 0 {
		return engine.builder_end(&b, engine.BUILDER_REGS, nil)
	}
	regs := engine.BUILDER_REGS
	verdict: u64
	if count.facts > 0 {
		verdict = replay(&p, &writing, &b, &regs, engine.builder_hook)
	} else {
		verdict = replay(&p, &writing, &b, &regs, engine.builder_hook_plain)
	}
	hi, fault, _ := core.result_of(verdict, &RULES)
	b.root_close = hi
	b.doc.spelled_tags = p.datetimes
	return engine.builder_end(&b, regs, fault)
}

// The handle's `validate`, and the check an edit list makes of a text of its own spec.
@(private)
edit_validate :: proc "contextless" (src: []u8, as: core.As) -> Maybe(core.Fault) {
	return validate_text(src, Spec(as.spec), options_of(as))
}

// Reads `src` into the table tree `p`, which judges every byte of the text, under the handle `handle`.
@(private)
parse_text :: proc(p: ^Parser, src: []u8, handle: core.As) -> core.Document_Error {
	if handle.spec > u8(max(Spec)) {
		return {kind = .Bad_Spec}
	}
	if !parser_init(p, src, Spec(handle.spec) == .Toml_1_1, depth_limit(options_of(handle))) {
		return {kind = .No_Memory}
	}
	if !parse(p, 0) {
		_, fault, _ := core.result_of(p.fail, &RULES)
		f := fault.?
		if f.kind == .No_Memory {
			return {kind = .No_Memory}
		}
		return {kind = .Walk, at = f.at, inner = f}
	}
	return {}
}

// TOML's `Services.scan`. The text is parsed whole before the first token, so every read judges every byte. A read of
// one path that gives no stream replays the tree through the scan's hook, which builds only what the path reaches. A
// read of several paths or a stream of answers builds the document and answers from it, in the order it holds them.
@(private)
scan_text :: proc(src: []u8, handle: core.As, paths: []core.Path, read: core.Path_Options, state: rawptr, on: proc(state: rawptr, a: core.Token_Answer) -> bool, allocator: runtime.Allocator) -> (doc: core.Document, err: core.Path_Error) {
	if on != nil || len(paths) != 1 {
		whole, built := build_text(src, handle, allocator)
		return engine.scan_built(&whole, built, paths, read, state, on, allocator)
	}
	p: Parser
	defer parser_destroy(&p)
	if e := parse_text(&p, src, handle); e.kind != .None {
		return {}, core.path_error(e)
	}
	// The scan's room as words, which an uninitialized declaration leaves unwritten where a struct's padding would not.
	room: [size_of(engine.Scan) / 8]u64 = ---
	h := (^engine.Scan)(rawptr(&room))
	frames: [core.MAX_DEPTH]u64 = ---
	if e := engine.scan_start(h, src, handle, paths, read, false, allocator, min(core.reserve_depth(handle.max_depth, len(src)), core.MAX_DEPTH), frames[:]); e.kind != .None {
		return {}, e
	}
	if h.many != nil {
		engine.scan_free(h, allocator)
		_, _ = engine.builder_end(&h.b, engine.BUILDER_REGS, nil)
		whole, built := build_text(src, handle, allocator)
		return engine.scan_built(&whole, built, paths, read, state, on, allocator)
	}
	regs := engine.BUILDER_REGS
	replayed: Replay
	defer delete(replayed.frames)
	hi, fault, _ := core.result_of(replay(&p, &replayed, h, &regs, engine.scan_hook), &RULES)
	err = engine.scan_end(h, regs, hi, fault, &doc)
	doc.spelled_tags = p.datetimes
	return
}

// A table has no bracket bytes of its own, so its end is the end of its last scalar, and an empty one ends where its
// token does. A scalar, which a path that meets it as no container names, ends where its bytes do.
@(private)
close_end :: proc(doc: ^core.Document, i: core.Node_Index) -> u64 {
	if i == core.ROOT && doc.root_close != 0 {
		return doc.root_close
	}
	n := doc.nodes[i]
	if n.kind <= .Plain {
		_, hi := core.scalar_ends(n)
		return hi
	}
	if n.n <= 1 {
		return n.lo
	}
	last := doc.nodes[int(i) + int(n.n) - 1]
	if last.kind > .Plain {
		return last.lo
	}
	_, hi := core.scalar_ends(last)
	return hi
}

@(private, rodata)
DATETIME_TAGS := [core.Tag_Meaning]string {
	.Own            = "",
	.Datetime       = "datetime",
	.Local_Datetime = "datetime-local",
	.Local_Date     = "date-local",
	.Local_Time     = "time-local",
	.Binary         = "",
}

// The readers' `tag_meaning`: a tag an edit gives a value is a span that holds the datetime type's name.
@(private)
tag_name_meaning :: proc(_: ^core.Document, _: core.Node_Index, tag: string) -> core.Tag_Meaning {
	return tag_datetime(tag)
}

// The datetime type tag `tag` names, `.Own` for a tag that is no TOML type.
@(private)
tag_datetime :: proc(tag: string) -> core.Tag_Meaning {
	for name, d in DATETIME_TAGS {
		if d != .Own && name == tag {
			return d
		}
	}
	return .Own
}

// The datetime type `text` is, whole, `.Own` for a text that is no datetime.
@(private)
text_datetime :: proc(text: string) -> core.Tag_Meaning {
	src := transmute([]u8)text
	if len(src) < 5 || !datetime_starts(src, 0) {
		return .Own
	}
	end, kind, verdict := scan_datetime(src, 0, true)
	return kind if verdict == 0 && end == len(src) else .Own
}

// The readers' `tag_fits`: a value keeps a datetime's tag when it is a string whose text is a datetime, as the type
// that text is.
@(private)
tag_fits :: proc(_: string, v: core.Value) -> (string, bool) {
	buf: [64]u8
	text, is_text := core.value_text(v, buf[:])
	d := text_datetime(text) if is_text && core.value_kind(v) == .String else .Own
	return DATETIME_TAGS[d], d != .Own
}

@(private, rodata)
STRING_STYLES := [Style]string {
	.Basic             = "basic",
	.Literal           = "literal",
	.Multiline         = "multiline",
	.Multiline_Literal = "multiline_literal",
}

// `Tag` is a datetime's type. `Style` is how a string, a number or a collection is written: a string's quoting, `bare`
// for a key written without quotes, for a number `integer`, `float`, `hex`, `octal`, `binary`, `inf` or `nan`, and for
// a table or an array below the root the word `Form` names.
@(private)
spelling_fact :: proc(doc: ^core.Document, i: core.Node_Index, name: core.Fact_Kind) -> (core.Fact_Value, bool) {
	t := doc.nodes[i]
	#partial switch name {
	case .Tag:
		if t.kind == .String && t.role == .Value {
			if d := datetime_of(t.spelling); d != .Own {
				return {text = DATETIME_TAGS[d], meaning = d}, true
			}
		}
	case .Style:
		switch t.kind {
		case .String:
			if t.spelling & core.SPELLING_DECODE != 0 {
				return {text = STRING_STYLES[style_of(t.spelling)]}, true
			}
			if t.role == .Key {
				return {text = "bare"}, true
			}
		case .Number:
			switch number_spelling_of(t.spelling) {
			case .Plain, .Decimal:
				for b in doc.src[t.lo:t.lo + u64(t.n)] {
					if b == '.' || b | 0x20 == 'e' {
						return {text = "float"}, true
					}
				}
				return {text = "integer"}, true
			case .Hex:
				return {text = "hex"}, true
			case .Octal:
				return {text = "octal"}, true
			case .Binary:
				return {text = "binary"}, true
			case .Inf:
				return {text = "inf"}, true
			case .Nan:
				return {text = "nan"}, true
			}
		case .Array, .Object:
			#partial switch form_of(doc, u32(i)) {
			case .Inline:
				return {text = "flow"}, true
			case .Dotted:
				return {text = "dotted"}, true
			case .Header, .Implicit, .Tables:
				return {text = "block"}, true
			}
		case .Null, .False, .True, .Bytes, .Plain, .End:
		}
	}
	return {}, false
}
