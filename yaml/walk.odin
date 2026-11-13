// The walk of a YAML text. A document is read by one pass that judges every byte and sends its tokens to the
// hook as it goes, the way the other formats' walks do. An alias is not a token kind: the walk sends the alias as a
// fact and then the tokens of the node it names, read back from a log of the anchored node's tokens.
package yaml

import "base:runtime"
import core "../core"

// The version of the language a text is read as. A `%YAML 1.1` directive is accepted and the text is read with the
// 1.2 rules.
Spec :: enum u8 {
	Yaml_1_2,
}

// Run-time options for a walk.
Options :: struct {
	// The deepest nesting a text may have, 0 for `MAX_DEPTH`.
	max_depth:   u32,
	// The most bytes the aliases of one document may read again, each alias its anchor's node with the aliases in it,
	// 0 for the larger of `ALIAS_FLOOR` and `ALIAS_RATIO` times the text's length.
	alias_limit: u64,
	// Applies `<<` merge keys: a `<<` member whose value is a mapping, an alias to one or a sequence of those adds their
	// members the host mapping lacks, an earlier source before a later one. Without it `<<` is an ordinary key.
	merge_keys:  bool,
}

// The alias limit of a text with no `alias_limit`, which a small text's limit does not fall below, and the multiple
// of a larger text's length.
ALIAS_FLOOR :: 1 << 20
ALIAS_RATIO :: 10

// The `core.Fault.detail` values a YAML text's faults use.
Detail :: enum u8 {
	None,
	Cut_Utf8, // `Truncated`, where the text ends inside a UTF-8 sequence
	Invalid_Utf8, // `Bad_Char`, at the lead byte of an ill-formed sequence
	Control_Char, // `Bad_Char`, a character YAML does not allow in a text
	Expected_Line_End, // `Bad_Char`, text after a node where the line must end
	Duplicate_Directive, // `Bad_Char`, a second `%YAML` directive or a handle declared twice
	Bad_Directive, // `Bad_Char`, a directive that does not follow its grammar
	Bad_Version, // `Bad_Char`, a `%YAML` major version other than 1
	Expected_Document_Start, // `Bad_Char`, directives without a `---` after them
	Unexpected_Content, // `Bad_Char`, text after the document's node that is not a marker
	Duplicate_Property, // `Bad_Char`, two tags or two anchors on one node
	Bad_Tag, // `Bad_Char`, a tag that does not follow the grammar
	Undeclared_Handle, // `Bad_Char`, a tag handle no `%TAG` directive declared
	Bad_Anchor, // `Bad_Char`, an anchor or alias without a name
	Undefined_Alias, // `Bad_Char`, an alias to a name no anchor holds
	Alias_Cycle, // `Bad_Char`, an alias inside the node of its own anchor
	Alias_Limit, // `Too_Wide`, aliases that add more tokens than the limit
	Open_String, // `Truncated`, a quoted scalar the text never closes
	Bad_Codepoint, // `Bad_Escape`, an escape of a surrogate or a value past U+10FFFF
	Marker_In_Scalar, // `Bad_Char`, a document marker inside a quoted scalar or a flow collection
	Bad_Indent, // `Bad_Char`, a line indented too little or too much
	Tab_Indent, // `Bad_Char`, a tab in the indentation of a block
	Bad_Block_Header, // `Bad_Char`, a block scalar header that does not follow the grammar
	Block_In_Line, // `Bad_Char`, a block collection that starts on the line of a node that cannot hold one
	Multiline_Key, // `Bad_Char`, an implicit key that spans lines
	Key_Too_Long, // `Bad_Char`, an implicit key longer than 1024 bytes
	Bad_Start, // `Bad_Char`, a character that cannot start a node
	Expected_Colon, // `Bad_Char`, a mapping key without its `:`
	Expected_Value, // `Bad_Char`, a flow collection entry that is empty
	Expected_Comma, // `Bad_Char`, text where a comma or a close was expected
	Open_Collection, // `Truncated`, a flow collection the text never closes
	Alias_Property, // `Bad_Char`, a tag or an anchor on an alias
	Extra_Document, // `Bad_Char`, a second document where a text is read as one
	No_Document, // `Truncated`, a text with no document where one is wanted
	Complex_Key, // `Bad_Char`, a key that is a collection, which a document does not hold
	Tag_Mismatch, // `Bad_Char`, a scalar whose text is not of the core type its tag names
}

// A YAML text's rules, indexed by `Detail`. Every fault the walk returns points to this table.
@(rodata)
RULES := core.Rules{"yaml", {
	{},
	{"cut_utf8", "Unfinished UTF-8 sequence"},
	{"invalid_utf8", "Invalid UTF-8"},
	{"control_char", "Character YAML does not allow"},
	{"expected_line_end", "Expected the end of the line"},
	{"duplicate_directive", "Directive given twice"},
	{"bad_directive", "Invalid directive"},
	{"bad_version", "Unsupported YAML version"},
	{"expected_document_start", "Expected --- after directives"},
	{"unexpected_content", "Unexpected text after the document"},
	{"duplicate_property", "Two tags or two anchors on one node"},
	{"bad_tag", "Invalid tag"},
	{"undeclared_handle", "Tag handle not declared"},
	{"bad_anchor", "Anchor or alias without a name"},
	{"undefined_alias", "Alias to an anchor that is not defined"},
	{"alias_cycle", "Alias inside its own anchor"},
	{"alias_limit", "Aliases expand past the limit"},
	{"open_string", "Unfinished quoted scalar"},
	{"bad_codepoint", "Escape of a value that is no Unicode scalar"},
	{"marker_in_scalar", "Document marker inside a scalar or collection"},
	{"bad_indent", "Invalid indentation"},
	{"tab_indent", "Tab in indentation"},
	{"bad_block_header", "Invalid block scalar header"},
	{"block_in_line", "Block collection cannot start on this line"},
	{"multiline_key", "Implicit key spans lines"},
	{"key_too_long", "Implicit key is longer than 1024 bytes"},
	{"bad_start", "Character cannot start a node"},
	{"expected_colon", "Expected : after a key"},
	{"expected_value", "Expected a value"},
	{"expected_comma", "Expected a comma or a close"},
	{"open_collection", "Unfinished flow collection"},
	{"alias_property", "Alias with a tag or an anchor"},
	{"extra_document", "More than one document"},
	{"no_document", "No document"},
	{"complex_key", "A collection as a key is not supported"},
	{"tag_mismatch", "Scalar is not of the type its tag names"},
}}

// The state of a walk with hook `H`: the hook's registers, where a `Skip` has the walk pass tokens, and the log that
// takes every token first, nil for none.
@(private)
Walk_State :: struct($H: typeid) {
	h:     ^H,
	regs:  core.Hook_Regs,
	mode:  u8, // 0 none, 1 passing the comments and properties before a skipped key's value, 2 passing a container
	depth: u32,
	log:   ^Token_Log,
	held:  ^Held, // a cursor's walk, which a `Stop` holds instead of ending, nil for a walk with no cursor
}

// The tokens a walk sent, and where each container among them opens, in the order they were sent.
@(private)
Token_Log :: struct {
	tokens: [dynamic]core.Token,
	opens:  [dynamic]int,
}

// Returns the sink that gives tokens to hook `on` and applies its `Skip` and `Stop`.
@(private)
hook_sink :: proc "contextless" ($H: typeid, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> Token_Sink {
	return proc "contextless" (data: rawptr, t: core.Token) -> bool {
		w := (^Walk_State(H))(data)
		container := t.kind == .Array || t.kind == .Object
		if w.log != nil {
			context = runtime.default_context()
			if container {
				append(&w.log.opens, len(w.log.tokens))
			}
			append(&w.log.tokens, t)
		}
		switch w.mode {
		case 1:
			if t.role > .Key {
				return true
			}
			w.mode = 2 if container else 0
			w.depth = 1
			return true
		case 2:
			if container {
				w.depth += 1
			} else if t.kind == .End {
				w.depth -= 1
				if w.depth == 0 {
					w.mode = 0
				}
			}
			return true
		}
		a: core.Action
		w.regs, a = on(w.h, w.regs, t)
		switch a {
		case .Stop:
			if w.held == nil {
				return false
			}
			hold_from(w.held, t)
		case .Skip:
			if container {
				w.mode, w.depth = 2, 1
			} else if t.role == .Key {
				w.mode = 1
			}
		case .Next, .Keep:
		}
		return true
	}
}

// Reads the document of a text that starts at `lo`, past one BOM at its first byte, with hook `on`. Returns `hi`, the
// byte after the document: after its `...` line, or at the next document's `---`, or the text's end. A text with no
// document, only comments and blank lines, has no tokens and `hi` is its end. When the hook stops the walk, `hi` is one
// past the token it stopped on.
//
// A document's root is its node, with no token of its own. A block collection is an `Array` or `Object` whose `End`
// has no bytes, a flow collection one that starts at its bracket and whose `End` is the closing bracket. A mapping's
// entries are a key and a value. A scalar is a `Plain` or a `String` (quoted and block scalars) whose span is its
// source bytes with their quotes or header. An empty node is a `Plain` of no bytes. A comment is a `Plain` of its span
// with the role its position gives it. A tag, an anchor and an alias are `Plain` facts before their node, the alias
// followed by the tokens of the node it names. `regs` nil starts from zero registers and keeps none. With a `cursor`,
// a stop saves where the walk stood there for `walk_resume`.
walk :: proc "contextless" (src: []u8, lo: u64, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor = nil) -> (hi: u64, fault: Maybe(core.Fault)) {
	return walk_noting(src, lo, opts, h, regs, on, cursor, nil)
}

// `walk`, which sets `typed^` when a key of the document resolves to no string.
@(private)
walk_noting :: proc "contextless" (src: []u8, lo: u64, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor, typed: ^bool) -> (hi: u64, fault: Maybe(core.Fault)) {
	if cursor != nil {
		hi, fault, _ = walk_saving(src, lo, opts, h, regs, on, cursor, nil)
		return
	}
	context = runtime.default_context()
	w := Walk_State(H){h = h}
	if regs != nil {
		w.regs = regs^
	}
	p: Parser
	parser_init(&p, src, opts, hook_sink(H, on), &w)
	defer parser_destroy(&p)
	p.pos = core.text_start(src, lo)
	p.ls = p.pos
	if p.pos >= u64(len(src)) {
		return u64(len(src)), nil
	}
	_, ok := read_document(&p)
	if ok {
		p.fail = core.fault_at(p.pos, .None)
	}
	if regs != nil {
		regs^ = w.regs
	}
	if typed != nil {
		typed^ = p.typed
	}
	hi, fault, _ = core.result_of(p.fail, &RULES)
	return
}

// `Cursor` holds where a walk a hook stopped stands, for `walk_resume` to continue it: the text's address and length,
// and the walk's state on the default heap. The walk reads on past the token it stopped on up to the next place its
// state is whole, past a block node or before a flow entry or close, and holds the tokens it read on the way, which
// the resume gives first. A stop inside an alias holds the rest of the node the alias names, and a stop in a
// mapping's merged members holds the rest of them. A fault the walk met past the stop comes after the held tokens, so
// a cursor resumes after any token. A walk that ends or faults frees what its cursor holds, and `cursor_destroy`
// frees a cursor no resume ended.
Cursor :: struct {
	src:  [^]u8,
	n:    u64,
	held: ^Held,
}

// What a cursor holds past a stop: the parser at the place the walk paused, the tokens read between the stop and the
// pause, and the hook's registers. `ended` is set once the parser read past the document's end or faulted before a
// pause, its result then in `parser.fail`.
@(private)
Held :: struct {
	parser:  Parser,
	queue:   [dynamic]core.Token,
	regs:    core.Hook_Regs,
	stop_at: u64, // one past the token the hook stopped on
	stopped: bool,
	ended:   bool,
}

// Whether `cursor` holds a stop that `walk_resume` continues, false once the walk it fills ended or faulted.
can_resume :: #force_inline proc "contextless" (cursor: ^Cursor) -> bool {
	return cursor.held != nil
}

// Continues the walk `cursor` holds a stop of, over the same `src`, from the token after the one it stopped on.
// `regs` is passed to the first token in place of the registers the stop saved, unless it is nil. The results are
// `walk`'s. A cursor that holds no stop, or that a walk of another text filled, is refused with `.Bad_Option`.
walk_resume :: proc "contextless" (src: []u8, cursor: ^Cursor, $S: Spec, opts := Options{}, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action)) -> (hi: u64, fault: Maybe(core.Fault)) {
	return resume_held(src, cursor, opts, h, regs, on, nil)
}

// Frees what `cursor` holds, a stop no resume ended. It is a member of `destroy`.
@(private)
cursor_destroy :: proc "contextless" (cursor: ^Cursor) {
	if cursor.held != nil {
		held_free(cursor, cursor.held)
	}
}

// `walk` with a cursor, which also says whether the text held a document from `lo`. The tokens the hook takes go to
// `log` too when it is not nil.
@(private)
walk_saving :: proc "contextless" (src: []u8, lo: u64, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), cursor: ^Cursor, log: ^Token_Log) -> (hi: u64, fault: Maybe(core.Fault), found: bool) {
	cursor_destroy(cursor)
	cursor.src, cursor.n = raw_data(src), u64(len(src))
	start := core.text_start(src, lo)
	if start >= u64(len(src)) {
		return u64(len(src)), nil, false
	}
	context = runtime.default_context()
	held: Held
	w := Walk_State(H){h = h, log = log, held = &held}
	if regs != nil {
		w.regs = regs^
	}
	p := &held.parser
	parser_init(p, src, opts, hook_sink(H, on), &w)
	p.pos = start
	p.ls = start
	ok: bool
	if found, ok = read_document(p); ok {
		p.fail = core.fault_at(p.pos, .None)
	}
	// A walk the hook stopped has sent a token, so the text holds a document.
	found ||= held.stopped
	hi, fault = held_end(cursor, &held, w.regs, regs)
	return
}

// `walk_resume`, whose tokens the hook takes go to `log` too when it is not nil.
@(private)
resume_held :: proc "contextless" (src: []u8, cursor: ^Cursor, opts: Options, h: ^$H, regs: ^core.Hook_Regs, $on: proc "contextless" (h: ^H, s: core.Hook_Regs, t: core.Token) -> (core.Hook_Regs, core.Action), log: ^Token_Log) -> (hi: u64, fault: Maybe(core.Fault)) {
	held := cursor.held
	if held == nil || cursor.src != raw_data(src) || cursor.n != u64(len(src)) {
		return 0, core.Fault{rules = &RULES, kind = .Bad_Option}
	}
	context = runtime.default_context()
	w := Walk_State(H){h = h, regs = held.regs, log = log, held = held}
	if regs != nil {
		w.regs = regs^
	}
	sink := hook_sink(H, on)
	given := 0
	for given < len(held.queue) && !held.stopped {
		sink(&w, held.queue[given])
		given += 1
	}
	remove_range(&held.queue, 0, given)
	if !held.stopped && !held.ended {
		p := &held.parser
		p.sink, p.data, p.pause, p.fail = sink, &w, false, 0
		if resume_document(p) {
			p.fail = core.fault_at(p.pos, .None)
		}
		// The next resume points the parser at its own walk.
		p.data = nil
	}
	return held_end(cursor, held, w.regs, regs)
}

// Ends a run of the walk `held` holds: saves it in `cursor` when the hook stopped it, and else frees it and gives the
// walk's result. `regs` takes the hook's registers `last` unless it is nil.
@(private)
held_end :: proc(cursor: ^Cursor, held: ^Held, last: core.Hook_Regs, regs: ^core.Hook_Regs) -> (hi: u64, fault: Maybe(core.Fault)) {
	if regs != nil {
		regs^ = last
	}
	p := &held.parser
	if !held.stopped {
		r := p.fail
		held_free(cursor, held)
		hi, fault, _ = core.result_of(r, &RULES)
		return
	}
	held.stopped, held.regs = false, last
	if !held.ended {
		// A held token the queue could not take ended the parser as a stop would.
		if p.fail & 0xffff == core.STOPPED << 8 {
			p.fail = core.fault_at(p.fail >> 16, .No_Memory)
		}
		held.ended = p.fail & 0xffff != PAUSED << 8
	}
	if cursor.held == nil {
		cursor.held = new_clone(held^)
	}
	return held.stop_at, nil
}

// Frees the walk `held` holds, and `cursor`'s copy of it.
@(private)
held_free :: proc "contextless" (cursor: ^Cursor, held: ^Held) {
	context = runtime.default_context()
	parser_destroy(&held.parser)
	delete(held.queue)
	if cursor.held == held {
		free(held)
		cursor.held = nil
	}
}

// Holds the walk at the hook's stop on token `t`: the parser's tokens go to the queue up to its next pause.
@(private)
hold_from :: proc "contextless" (held: ^Held, t: core.Token) {
	held.stopped, held.stop_at = true, t.lo + u64(t.n)
	p := &held.parser
	p.sink, p.data, p.pause = hold_sink, held, true
}

@(private)
hold_sink :: proc "contextless" (data: rawptr, t: core.Token) -> bool {
	context = runtime.default_context()
	_, e := append(&(^Held)(data).queue, t)
	return e == nil
}

// Continues a document `read_document` paused in, from the state its parser holds.
@(private)
resume_document :: proc(p: ^Parser) -> bool {
	read_blocks(p) or_return
	return end_document(p)
}

// The walk's verdict on `src` for `spec`, after one leading BOM: every document of the stream is read and judged.
validate :: proc "contextless" (src: []u8, spec: Spec, opts := Options{}) -> core.Error {
	return core.error_of(validate_text(src, opts))
}

// The handle's `validate`.
@(private)
validate_as :: proc "contextless" (src: []u8, as: core.As) -> Maybe(core.Fault) {
	return validate_text(src, options_of(as))
}

@(private)
validate_text :: proc "contextless" (src: []u8, opts: Options) -> Maybe(core.Fault) {
	context = runtime.default_context()
	p: Parser
	parser_init(&p, src, opts, nil, nil)
	defer parser_destroy(&p)
	p.pos = core.text_start(src, 0)
	p.ls = p.pos
	for p.pos < u64(len(src)) {
		found, ok := read_document(&p)
		if !ok {
			_, fault, _ := core.result_of(p.fail, &RULES)
			return fault
		}
		if !found {
			break
		}
	}
	return nil
}

// The fault of the text from `lo` on, when what came before it was to be the text's only document: the fault of a
// later document the walk refuses, or `Extra_Document` at the start of one it reads.
@(private)
tail_fault :: proc "contextless" (src: []u8, lo: u64, opts: Options) -> Maybe(core.Fault) {
	context = runtime.default_context()
	p: Parser
	parser_init(&p, src, opts, nil, nil)
	defer parser_destroy(&p)
	p.pos = lo
	p.ls = lo
	if lo >= u64(len(src)) {
		return nil
	}
	if !peek_next(&p) {
		_, fault, _ := core.result_of(p.fail, &RULES)
		return fault
	}
	start := p.nl.pos
	found, ok := read_document(&p)
	if !ok {
		_, fault, _ := core.result_of(p.fail, &RULES)
		return fault
	}
	if found {
		return core.Fault{at = start, rules = &RULES, kind = .Bad_Char, detail = u8(Detail.Extra_Document)}
	}
	return nil
}
