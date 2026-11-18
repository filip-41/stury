// The token write: a text made call by call, with no type and no document. A nested format (JSON) takes containers, keys
// and values. A flat format (delimited text) takes cells and the end of a record.
package write

import "base:runtime"
import "core:io"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "../spell"
import core ".."
import "../typed"

// One value of a token write: a string, a byte string, a number by its value or by its text, or `.Null`, `.False` or
// `.True` of the tree. A nil value is `.Null`. A text format writes a byte string as the string of its RFC 4648 base64.
Scalar :: union {
	string,
	typed.Bytes,
	core.Number,
	Number_Literal,
	Tree_Part,
	Tagged_Text,
}

// A number by its text, which must be a JSON number, written as it is.
Number_Literal :: struct {
	text: string,
}

// A string by its text and the type its format tags it with, as a TOML datetime is: a format with tags writes it as the
// type's own literal, and the text must be one of that type, else `.Bad_Raw`. An empty tag is the type the text spells,
// a `typed.Datetime`'s. A format with none, or a tag the format has no type of, writes the string. `meaning` is the
// tag's meaning when a node of a document holds it: a format writes that meaning as its own tag where the text is a
// value of it, and the string elsewhere.
Tagged_Text :: struct {
	text, tag: string,
	meaning:   core.Tag_Meaning,
}

// A format's token spelling, which `core.Services.tokens` points at. `tree` is the nested format's punctuation. `value`
// writes one scalar, or one cell of a flat format, and a key is a string. A `Number_Literal` that reaches it through
// `value` is a JSON number. A format with a `line` is flat.
Token_Spelling :: struct {
	tree:   Tree,
	start:  proc(t: ^Tokens, as: core.As) -> core.Typed_Error_Kind, // sets `state` and `out`
	value:  proc(t: ^Tokens, v: Scalar) -> core.Typed_Error_Kind,
	line:   proc(t: ^Tokens) -> core.Typed_Error_Kind, // ends a record
	// Writes a flat format's line of field `names` above its records, or nothing in a layout that has none.
	names:  proc(t: ^Tokens, names: []string) -> core.Typed_Error_Kind,
	stop:   proc(t: ^Tokens), // frees `state`
	// Turns the finished text into the format's own: a format whose grammar fixes an order the calls cannot know
	// writes the calls as a text it reads back and lays that out here. It receives the bytes the calls made, which it
	// frees, and a refusal is `end`'s own. Only a write to a buffer reaches it.
	end:    proc(t: ^Tokens, bytes: []u8) -> ([]u8, core.Typed_Refusal),
	// Writes a value by a plan the format built as one record, with no frame: a value, or a row with its line end and,
	// for the first, the header. A refusal's kind and path go to `err`, and the kind is returned.
	record: proc(t: ^Tokens, plan: ^typed.Plan, value: rawptr, err: ^core.Typed_Refusal) -> core.Typed_Error_Kind,
	// Lays the text out itself while `state` is set: the container, key and comma punctuation of `tree` is not written,
	// `layout` is called at each step instead, and `value` writes the scalars and the keys, whose separators it writes
	// too. A `state` that stays nil writes `tree` as it is.
	layout: proc(t: ^Tokens, step: Layout_Step) -> core.Typed_Error_Kind,
	// Writes `text` as a comment of `role` where `comment` puts it, after the comma or line that a tree's item owes. Nil
	// for a format with no comments.
	comment: proc(t: ^Tokens, role: core.Role, text: string) -> core.Typed_Error_Kind,
	// Writes a whole value in place of the calls, as a markup format does, whose element write reads the facts of the
	// value's nodes and those an update kept on a value it put in place of one.
	built:   Markup_Put,
}

// The steps of a laid-out write. `Close` comes after the level is popped, and `Key` before `value` writes the name.
Layout_Step :: enum u8 {
	Open_Object,
	Open_Array,
	Close,
	Key,
}

// A token write's state. It holds `core.MAX_DEPTH` levels with no allocation and is not copied after `tokens_init`. A
// misuse or a failed output is kept in `err`, and every later call returns it and writes nothing.
Tokens :: struct {
	out:    ^Out, // `base`, or the output of a flat format's `state`
	opts:   core.Write_Options,
	spell:  ^Token_Spelling,
	state:  rawptr, // a format's own, set by `start`
	site:   core.Site, // where the text will stand in a document, for a format that indents or styles by place
	words:  core.Write_Words, // the reasons the format's refusals give
	base:   Out,
	spill:  [ROOM_MAX]u8,
	object: [core.MAX_DEPTH]bool, // per open level, whether it is an object
	spec:   u8, // the format's spec
	notes:  bool, // the spec holds comments and the spelling writes them
	top:    int, // the open levels
	inline: int, // the output offset just past the text of the last one-line inline comment, 0 after any other write
	mark:   int, // the output offset where the open record began, or a format's own mark in a nested text
	first:  bool, // nothing is written yet in the open container or record
	led:    bool, // a comment has written the comma that the next item owes
	keyed:  bool, // a key is written and its value is owed
	done:   bool, // the root value is whole
	err:    core.Typed_Error_Kind,
}

// Starts a write in the format `as` names, as `opts` says, into a buffer from `allocator` or to `stream`. A format with no
// token writer is `.Unsupported`, and an `as` the format cannot write is its own refusal. The kind is also kept in `t`.
// A format that binds its spelling at compile time gives it as `spell`, and then `as` need hold no services. `site` says
// where the text will stand, which a format's `start` and `value` read from `t.site`: a text that stands at a column,
// in a flow collection or after a key is laid out for that place. The zero site is a whole text.
tokens_init :: proc(t: ^Tokens, as: core.As, opts := core.Write_Options{}, allocator := context.allocator, stream := io.Stream{}, spell: ^Token_Spelling = nil, site := core.Site{}) -> core.Typed_Error_Kind {
	// The spill and the levels are not zeroed: a level is read only below `top`.
	t.opts, t.spell, t.state, t.top, t.mark, t.inline, t.first, t.keyed, t.done, t.err = opts, nil, nil, 0, 0, 0, true, false, false, .None
	t.spec, t.led, t.site = as.spec, false, site
	services := core.services_of(as)
	t.words = services.words if services != nil else {}
	init(&t.base, &t.spill, allocator, stream)
	t.out = &t.base
	t.spell = spell
	if t.spell == nil {
		if services == nil || services.tokens == nil {
			return refuse(t, .Unsupported)
		}
		t.spell = (^Token_Spelling)(services.tokens)
	}
	t.notes = t.spell.comment != nil && as.readers != nil && .Comment in as.readers.holds
	if t.spell.start != nil {
		return refuse(t, t.spell.start(t, as))
	}
	return .None
}

// Ends the text and returns it as `finish` does. A JSON text must be one value with every container closed, and a flat
// text must have no cells waiting for their record's end, else the end is `.Out_Of_Order`.
tokens_finish :: proc(t: ^Tokens) -> (bytes: []u8, err: core.Typed_Refusal) {
	if t.spell != nil && !(t.first if t.spell.line != nil else t.done) {
		refuse(t, .Out_Of_Order)
	}
	bytes, err = finish(t.out, {kind = t.err if t.out.err == .None else .None})
	if t.spell != nil && t.spell.stop != nil {
		t.spell.stop(t)
	}
	if err.kind == .None && bytes != nil && t.spell != nil && t.spell.end != nil {
		bytes, err = t.spell.end(t, bytes)
	}
	err = core.worded(err, t.words)
	return
}

open_object :: proc(t: ^Tokens) -> core.Typed_Error_Kind {return open(t, true)}

open_array :: proc(t: ^Tokens) -> core.Typed_Error_Kind {return open(t, false)}

// Closes the innermost container. A close with none open, or between a key and its value, is `.Out_Of_Order`.
close :: proc(t: ^Tokens) -> core.Typed_Error_Kind {
	if t.err != .None || t.spell.line != nil {
		return refuse(t, .Unsupported)
	}
	if t.top == 0 || t.keyed || t.led {
		return refuse(t, .Out_Of_Order)
	}
	t.top -= 1
	if laid(t) {
		refuse(t, t.spell.layout(t, .Close))
	} else {
		if !t.first {
			put_line(t.out, t.opts, t.top)
		}
		put_text(t.out, t.spell.tree[.Close_Object if t.object[t.top] else .Close_Array])
	}
	t.first, t.done = false, t.top == 0
	return refuse(t, t.out.err)
}

// Writes a member's name and its colon. Only an object that owes a key takes it.
key :: proc(t: ^Tokens, name: string) -> core.Typed_Error_Kind {
	if !lead(t, .Key) {
		return t.err
	}
	if laid(t) {
		refuse(t, t.spell.layout(t, .Key))
	}
	if refuse(t, t.spell.value(t, name)) != .None {
		return t.err
	}
	if !laid(t) {
		put_text(t.out, t.spell.tree[.Colon])
		if t.opts.pretty {
			put_text(t.out, t.spell.tree[.After_Colon])
		}
	}
	t.keyed = true
	return refuse(t, t.out.err)
}

// Writes `text` as a comment of `role`: `.Comment` before the next key, value or container, `.Comment_Inline` on the
// line of the item last written, and `.Comment_Foot` after the last item of the innermost open container, or after the
// root once it is whole. A format with no comments, and any other role, is `.Unsupported`, and a comment between a key
// and its value, or a role with no item to stand by, is `.Out_Of_Order`.
comment :: proc(t: ^Tokens, text: string, role := core.Role.Comment) -> core.Typed_Error_Kind {
	if t.err != .None {
		return t.err
	}
	if t.spell.line != nil || !t.notes || role != .Comment && role != .Comment_Inline && role != .Comment_Foot {
		return refuse(t, .Unsupported)
	}
	root := t.top == 0
	switch {
	case t.keyed, role == .Comment && root && t.done, role == .Comment_Inline && (root && !t.done || !root && t.first), role == .Comment_Foot && root && !t.done:
		return refuse(t, .Out_Of_Order)
	}
	if role == .Comment && !root && !laid(t) {
		if !t.first && !t.led {
			put_text(t.out, t.spell.tree[.Comma])
		}
		put_line(t.out, t.opts, t.top)
		t.led = !t.first
	}
	if role == .Comment_Foot && !root && !laid(t) && !t.first {
		put_line(t.out, t.opts, t.top)
	}
	refuse(t, t.spell.comment(t, role, text))
	t.inline = 0
	if role == .Comment_Inline && strings.index_byte(text, '\n') < 0 {
		ended := t.out.cursor > 0 && t.out.buf[t.out.cursor - 1] == '\n'
		t.inline = t.out.flushed + t.out.cursor - (1 if ended else 0)
	}
	return refuse(t, t.out.err)
}

// The bytes written since the last inline comment's text, and whether that comment is in the buffer with at most its
// line end after it, so that a next inline comment on the item joins it.
inline_tail :: proc(t: ^Tokens) -> (tail: int, joins: bool) {
	tail = t.out.flushed + t.out.cursor - t.inline
	return tail, t.inline > t.out.flushed && tail <= 1
}

// The value calls write a JSON value, or a cell of a flat format. A string that is not UTF-8 is `.Invalid_Utf8`, and a float
// that is infinite or not a number is `.Non_Finite`. Null is an empty cell.
value_string :: proc(t: ^Tokens, s: string) -> core.Typed_Error_Kind {return value(t, s)}

value_int :: proc(t: ^Tokens, x: i64) -> core.Typed_Error_Kind {return value(t, core.Number{u64(x), .Int})}

value_uint :: proc(t: ^Tokens, x: u64) -> core.Typed_Error_Kind {return value(t, core.Number{x, .Uint})}

value_float :: proc(t: ^Tokens, x: f64) -> core.Typed_Error_Kind {return value(t, core.Number{transmute(u64)x, .Float})}

value_bool :: proc(t: ^Tokens, b: bool) -> core.Typed_Error_Kind {return value(t, Tree_Part.True if b else .False)}

value_null :: proc(t: ^Tokens) -> core.Typed_Error_Kind {return value(t, Tree_Part.Null)}

// A byte string, written as the format spells one: a text format writes the string of its base64, see `bytes_text`.
value_bytes :: proc(t: ^Tokens, b: []u8) -> core.Typed_Error_Kind {return value(t, typed.Bytes(b))}

// A string with the type its format tags it with, see `Tagged_Text`.
value_tagged :: proc(t: ^Tokens, text, tag: string) -> core.Typed_Error_Kind {return value(t, Tagged_Text{text = text, tag = tag})}

// Ends the record of a flat format with the layout's line end. A JSON write is `.Unsupported`, and a record that wrote
// no byte is `.Unwritable` as `marshal` refuses it.
end_record :: proc(t: ^Tokens) -> core.Typed_Error_Kind {
	if t.err != .None || t.spell.line == nil {
		return refuse(t, .Unsupported)
	}
	if kind := t.spell.line(t); kind != .None {
		return refuse(t, kind)
	}
	t.first, t.mark = true, t.out.flushed + t.out.cursor
	return refuse(t, t.out.err)
}

@(private)
Item :: enum {
	Scalar,
	Key,
	Container,
}

@(private)
open :: proc(t: ^Tokens, object: bool) -> core.Typed_Error_Kind {
	if !lead(t, .Container) {
		return t.err
	}
	if laid(t) {
		refuse(t, t.spell.layout(t, .Open_Object if object else .Open_Array))
	} else {
		put_text(t.out, t.spell.tree[.Open_Object if object else .Open_Array])
	}
	t.object[t.top] = object
	t.top += 1
	t.first = true
	return refuse(t, t.out.err)
}

@(private)
value :: proc(t: ^Tokens, v: Scalar) -> core.Typed_Error_Kind {
	if !lead(t, .Scalar) {
		return t.err
	}
	if x, literal := v.(Number_Literal); literal {
		if _, is_number := number_of_text(x.text); !is_number {
			return refuse(t, .Bad_Raw)
		}
	}
	refuse(t, t.spell.value(t, v))
	t.first, t.done = false, t.top == 0
	return refuse(t, t.out.err)
}

// Checks that an item may come next and writes what goes before it: the comma, and in pretty text the line. Returns false
// with the refusal in `t.err`. A flat format takes only cells, and its `value` writes their separators.
@(private)
lead :: proc(t: ^Tokens, item: Item) -> bool {
	if t.err != .None {
		return false
	}
	if t.spell.line != nil {
		return item == .Scalar || refuse(t, .Unsupported) == .None
	}
	object := t.top > 0 && t.object[t.top - 1]
	switch {
	case item == .Key && (!object || t.keyed), item != .Key && object != t.keyed, t.top == 0 && t.done:
		refuse(t, .Out_Of_Order)
	case item == .Container && t.top == core.MAX_DEPTH:
		refuse(t, .Too_Deep)
	case t.keyed:
		t.keyed = false
	case:
		if t.top > 0 && !laid(t) {
			if !t.first && !t.led {
				put_text(t.out, t.spell.tree[.Comma])
			}
			put_line(t.out, t.opts, t.top)
		}
		t.first, t.led = false, false
	}
	return t.err == .None
}

// Whether the format lays the text out itself.
@(private)
laid :: #force_inline proc "contextless" (t: ^Tokens) -> bool {
	return t.state != nil && t.spell.layout != nil
}

// Keeps the first refusal and returns it.
@(private)
refuse :: proc(t: ^Tokens, kind: core.Typed_Error_Kind) -> core.Typed_Error_Kind {
	if t.err == .None {
		t.err = kind
	}
	return t.err
}

// Returns the RFC 4648 base64 text of `b`, in `stack` when it fits and else in `context.temp_allocator`, with false when
// that is refused.
bytes_text :: proc(b: []u8, stack: []u8) -> (text: string, ok: bool) {
	n := spell.base64_room(len(b))
	buf := stack
	if n > len(stack) {
		made, err := make([]u8, n, context.temp_allocator)
		if err != nil {
			return "", false
		}
		buf = made
	}
	return string(buf[:spell.base64_text(buf, b)]), true
}

// Returns the base64 text of byte string `node`, as `bytes_text` does for its payload.
node_bytes_text :: proc(doc: ^core.Document, node: core.Node_Index, stack: []u8) -> (text: string, ok: bool) {
	joined: []u8
	if int(node) < len(doc.nodes) && doc.nodes[node].spelling & core.SPELLING_DECODE != 0 {
		made, err := make([]u8, core.text_room(doc, node), context.temp_allocator)
		if err != nil {
			return "", false
		}
		joined = made
	}
	payload, found := core.doc_bytes(doc, node, joined)
	if !found {
		return "", false
	}
	return bytes_text(payload, stack)
}

// Returns the decimal digits of number `node` as its format spells them, in `stack` when they fit and else in
// `context.temp_allocator`, with false when the node is no number or an allocation is refused.
node_number_text :: proc(doc: ^core.Document, node: core.Node_Index, stack: []u8) -> (text: string, ok: bool) {
	if s, fit := core.doc_number_text(doc, node, stack); fit {
		return s, true
	}
	if core.kind(doc, node) != .Number {
		return "", false
	}
	for room := 4 * len(stack); room <= NUMBER_TEXT_MAX; room *= 2 {
		buf, err := make([]u8, room, context.temp_allocator)
		if err != nil {
			return "", false
		}
		if s, fit := core.doc_number_text(doc, node, buf); fit {
			return s, true
		}
	}
	return "", false
}

@(private)
NUMBER_TEXT_MAX :: 1 << 26

// Writes number node `node` as its decimal digits as JSON spells them, or as its span when `own` says the writing
// format reads it. A text number whose spelling the writing format's `forms` hold keeps it, see `put_spelled`. An
// infinity or a NaN is written with tree `T`'s word, and is `.Non_Finite` when `T` has none, unless `jq_numbers` writes
// it as jq does: a NaN as null, an infinity as the largest double of its sign.
put_number_node :: proc(out: ^Out, doc: ^core.Document, node: core.Node_Index, $T: Tree, own := false, forms := Number_Forms{}, jq_numbers := false) -> core.Typed_Error_Kind {
	if .Int_64 in forms && !own {
		return put_number_node_int_64(out, doc, node, T, forms - {.Int_64}, jq_numbers)
	}
	t := doc.nodes[node]
	span := string(core.span(doc, node))
	if own || doc.readers.number_text == nil && (t.kind != .Number || t.spelling & core.NUMBER_KIND_MASK == 0) {
		put_text(out, span)
		return .None
	}
	if forms != {} && !doc.readers.binary && put_spelled(out, span, forms) {
		return .None
	}
	kind: core.Typed_Error_Kind
	if doc.readers.number_text != nil {
		stack: [64]u8
		text, ok := node_number_text(doc, node, stack[:])
		if !ok {
			return .No_Memory
		}
		put_text(out, text)
		kind = .None if text != "" else .Non_Finite
	} else {
		kind = put_decimal(out, span, t.spelling)
	}
	if kind != .Non_Finite || T[.Nan] == "" && !jq_numbers {
		return kind
	}
	f, is_float := core.float_value(doc, node)
	if !is_float {
		return .Non_Finite
	}
	if T[.Nan] == "" {
		put_text(out, "null" if f != f else "1.7976931348623157e+308" if f > 0 else "-1.7976931348623157e+308")
		return .None
	}
	put_text(out, T[.Nan] if f != f else T[.Inf] if f > 0 else T[.Neg_Inf])
	return .None
}

// The number spellings past a JSON decimal that a format's grammar has and its writer keeps from a source that spells a
// number so, and `Int_64` for a format whose integers hold 64 bits: a hex, octal or binary integer (`0xFF`, `0o17`, `0b101`), a leading plus (`+1`), a point with no digit
// before it (`.5`) and one with no digit after it (`5.`).
Number_Form :: enum u8 {
	Hex,
	Octal,
	Binary,
	Plus,
	Lead_Point,
	Bare_Point,
	Int_64, // the format's integers are signed 64 bits, see `put_int_64_text`
}
Number_Forms :: bit_set[Number_Form; u8]

// Writes number text `lit` in a spelling of `forms` and returns true, or writes nothing and returns false when `forms`
// lacks one of its forms or it has a form no format here shares: underscores, leading zeros, a word, or a sign on a
// prefixed integer. A prefixed integer is written with a lowercase prefix and without underscores, as every grammar of
// a base reads it, and any other text as it stands.
@(private)
put_spelled :: proc(out: ^Out, lit: string, forms: Number_Forms) -> bool {
	if len(lit) == 0 {
		return false
	}
	p := 0
	if lit[0] == '+' || lit[0] == '-' {
		if lit[0] == '+' && .Plus not_in forms {
			return false
		}
		p = 1
	}
	if p == 0 && len(lit) > 2 && lit[0] == '0' {
		base: Number_Form
		switch lit[1] {
		case 'x', 'X':
			base = .Hex
		case 'o':
			base = .Octal
		case 'b':
			base = .Binary
		case:
			return put_spelled_decimal(out, lit, p, forms)
		}
		if base not_in forms {
			return false
		}
		put_byte(out, '0')
		put_byte(out, lit[1] | 0x20)
		for c in transmute([]u8)lit[2:] {
			if c != '_' {
				put_byte(out, c)
			}
		}
		return true
	}
	return put_spelled_decimal(out, lit, p, forms)
}

// `put_spelled` for a decimal whose digits start at `p`.
@(private)
put_spelled_decimal :: proc(out: ^Out, lit: string, p: int, forms: Number_Forms) -> bool {
	whole := p
	for whole < len(lit) && lit[whole] - '0' < 10 {
		whole += 1
	}
	if whole - p > 1 && lit[p] == '0' {
		return false
	}
	k := whole
	if k < len(lit) && lit[k] == '.' {
		k += 1
		frac := k
		for k < len(lit) && lit[k] - '0' < 10 {
			k += 1
		}
		if whole == p && .Lead_Point not_in forms || k == frac && .Bare_Point not_in forms || whole == p && k == frac {
			return false
		}
	} else if whole == p {
		return false
	}
	if k < len(lit) && lit[k] | 0x20 == 'e' {
		k += 1
		if k < len(lit) && (lit[k] == '+' || lit[k] == '-') {
			k += 1
		}
		exp := k
		for k < len(lit) && lit[k] - '0' < 10 {
			k += 1
		}
		if k == exp {
			return false
		}
	}
	if k != len(lit) {
		return false
	}
	put_text(out, lit)
	return true
}

// `put_number_node` for a format whose integers are signed 64 bits: the number is spelled as the format's other forms say,
// then checked by `put_int_64_text`.
@(private)
put_number_node_int_64 :: #force_no_inline proc(out: ^Out, doc: ^core.Document, node: core.Node_Index, $T: Tree, forms: Number_Forms, jq_numbers: bool) -> core.Typed_Error_Kind {
	spill: [ROOM_MAX]u8 = ---
	digits: Out
	init(&digits, &spill, context.temp_allocator)
	text, err := finish(&digits, {kind = put_number_node(&digits, doc, node, T, false, forms, jq_numbers)})
	if err.kind != .None {
		return err.kind
	}
	return put_int_64_text(out, string(text))
}

// Writes number text `lit` for a format whose integers are signed 64 bits and which has floats: an integer past them is
// `.Unwritable`, naming it, and an integer `-0`, whose sign a 64-bit integer cannot keep, is the float `-0.0`. Any other
// number is written as it stands.
put_int_64_text :: proc(out: ^Out, lit: string) -> core.Typed_Error_Kind {
	magnitude, negative, integer := integer_magnitude(lit)
	switch {
	case !integer:
	case magnitude > u64(max(i64)) + u64(negative):
		out.what = strings.concatenate({lit, " is an integer past 64 bits"}, context.temp_allocator)
		return .Unwritable
	case negative && magnitude == 0:
		put_text(out, "-0.0")
		return .None
	}
	put_text(out, lit)
	return .None
}

// Writes unsigned `n` as `put_int_64_text` writes an integer: past `max(i64)` it is `.Unwritable`.
put_int_64_unsigned :: proc(out: ^Out, n: u64) -> core.Typed_Error_Kind {
	stack: [32]u8
	return put_int_64_text(out, string(stack[:spell.u64_text(raw_data(stack[:]), n)]))
}

// The magnitude of integer text `lit`, a decimal or a prefixed integer with underscores, saturated at `max(u64)`, and
// whether it is negative. `integer` is false for any other text.
@(private)
integer_magnitude :: proc(lit: string) -> (magnitude: u64, negative, integer: bool) {
	i := 0
	if len(lit) > 0 && (lit[0] == '+' || lit[0] == '-') {
		negative, i = lit[0] == '-', 1
	}
	base := u64(10)
	if i + 1 < len(lit) && lit[i] == '0' {
		switch lit[i + 1] | 0x20 {
		case 'x':
			base, i = 16, i + 2
		case 'o':
			base, i = 8, i + 2
		case 'b':
			base, i = 2, i + 2
		}
	}
	if i == len(lit) {
		return 0, false, false
	}
	for ; i < len(lit); i += 1 {
		c := lit[i]
		if c == '_' {
			continue
		}
		d := u64(c - '0') if c - '0' < 10 else u64((c | 0x20) - 'a' + 10) if (c | 0x20) - 'a' < 6 else 99
		if d >= base {
			return 0, false, false
		}
		if magnitude > (max(u64) - d) / base {
			magnitude = max(u64)
		} else {
			magnitude = magnitude * base + d
		}
	}
	return magnitude, negative, true
}

// Returns the text of node `node`, in `buf` when it fits and else in a copy made with `allocator`.
node_text :: #force_inline proc(doc: ^core.Document, node: core.Node_Index, buf: []u8, allocator: runtime.Allocator) -> (string, core.Typed_Error_Kind) {
	if text, ok := core.text(doc, node, buf); ok {
		return text, .None
	}
	text, ok := core.text_clone(doc, node, allocator)
	return text, .None if ok else .No_Memory
}

// Whether the collection at `node` holds a fact inside it: one of a node below it, or a foot comment of its own.
holds_inner_fact :: proc(doc: ^core.Document, node: core.Node_Index) -> bool {
	for f in core.subtree_facts(doc, node) {
		if f.node != node || f.role == .Comment_Foot {
			return true
		}
	}
	return false
}

// A member of an object node as a document writer lays it out: its key, its value and the key's text.
Node_Member :: struct {
	key, value: core.Node_Index,
	name:       string,
}

// Returns the members of the object at `node`, each name decoded in place or copied with `allocator`, in name order when
// `sort` says so, a repeated name keeping its place. A name the object repeats is `.Unwritable` when `unique` says so.
node_members :: proc(doc: ^core.Document, node: core.Node_Index, sort, unique: bool, allocator: runtime.Allocator) -> ([]Node_Member, core.Typed_Error_Kind) {
	members := make([dynamic]Node_Member, allocator)
	seen: map[string]struct{}
	it := core.pairs(doc, node)
	for key, value in core.pair_next(&it) {
		name, failed := node_text(doc, key, nil, allocator)
		if failed != .None {
			return nil, failed
		}
		if unique && len(members) < LINEAR_KEYS {
			for m in members {
				if m.name == name {
					return nil, .Unwritable
				}
			}
		} else if unique {
			if seen == nil {
				seen = make(map[string]struct{}, allocator)
				for m in members {
					seen[m.name] = {}
				}
			}
			if name in seen {
				return nil, .Unwritable
			}
			seen[name] = {}
		}
		if _, failed := append(&members, Node_Member{key, value, name}); failed != nil {
			return nil, .No_Memory
		}
	}
	if sort {
		slice.stable_sort_by(members[:], proc(a, b: Node_Member) -> bool {return a.name < b.name})
	}
	return members[:], .None
}

// Objects with fewer members than this check for a repeated name by comparing names in turn.
@(private)
LINEAR_KEYS :: 16

// The tree a markup format's typed write makes a value in, which its element write reads: JSON's punctuation and words,
// and a float that is a whole number with `.0`.
MARKUP_TREE :: Tree {
	.Open_Object  = "{",
	.Close_Object = "}",
	.Open_Array   = "[",
	.Close_Array  = "]",
	.Comma        = ",",
	.Colon        = ":",
	.After_Colon  = " ",
	.Null         = "null",
	.True         = "true",
	.False        = "false",
	.Point_Zero   = ".0",
	.Inf          = "",
	.Neg_Inf      = "",
	.Nan          = "",
	.Heads        = "",
	.Bytes_Tag    = "",
}

// Returns the text a markup format spells scalar `node` with, in `stack`, at least 64 bytes, when it fits and else in
// `context.temp_allocator`: a string's text, a number's digits as its format spells them, `true` or `false`, and a byte
// string's base64. Any other node is `.Unwritable`.
scalar_text :: proc(doc: ^core.Document, node: core.Node_Index, stack: []u8) -> (string, core.Typed_Error_Kind) {
	#partial switch core.kind(doc, node) {
	case .String, .Plain:
		return node_text(doc, node, stack, context.temp_allocator)
	case .Number:
		spill: [ROOM_MAX]u8 = ---
		digits: Out
		init(&digits, &spill, context.temp_allocator)
		text, err := finish(&digits, {kind = put_number_node(&digits, doc, node, MARKUP_TREE)})
		return string(text), err.kind
	case .True:
		return "true", .None
	case .False:
		return "false", .None
	case .Bytes:
		text, ok := node_bytes_text(doc, node, stack)
		return text, .None if ok else .No_Memory
	}
	return "", .Unwritable
}

// Returns the text of scalar value `v` as `scalar_text` does a node's, with a built number as its shortest digits in
// the spelling of tree `T`.
value_scalar_text :: proc(v: core.Value, stack: []u8, $T: Tree) -> (text: string, kind: core.Typed_Error_Kind) {
	#partial switch x in v {
	case core.Node_Ref:
		return scalar_text(x.doc, x.node, stack)
	case string:
		return x, .None
	case core.Number_View:
		return core.view_text(x), .None
	case f64:
		n, _ := core.number(x)
		size := number_text(raw_data(stack), n, T) or_return
		return string(stack[:size]), .None
	case bool:
		return "true" if x else "false", .None
	}
	return "", .Unwritable
}

// Returns the text a markup format spells token scalar `v` with, in `stack`, at least 512 bytes, when it fits and else in
// `context.temp_allocator`, and whether it is null.
token_scalar_text :: proc(v: Scalar, stack: []u8) -> (text: string, null: bool, kind: core.Typed_Error_Kind) {
	switch x in v {
	case string:
		return x, false, .None
	case Tagged_Text:
		return x.text, false, .None
	case typed.Bytes:
		b, ok := bytes_text(cast([]u8)x, stack)
		return b, false, .None if ok else .No_Memory
	case core.Number:
		n := number_text(raw_data(stack), x, MARKUP_TREE) or_return
		return string(stack[:n]), false, .None
	case Number_Literal:
		return x.text, false, .None
	case Tree_Part:
		tree := MARKUP_TREE
		return tree[x], x == .Null, .None
	}
	return "", true, .None
}

// Writes a markup format's typed or token string `s`: a quote, the bytes and a NUL, which no string a markup format
// spells holds.
put_marked :: proc(out: ^Out, _: [^]u8, s: string, _: ^core.Write_Options) -> core.Typed_Error_Kind {
	if strings.index_byte(s, 0) >= 0 {
		return .Unwritable
	}
	put_byte(out, '"')
	put_text(out, s)
	put_byte(out, 0)
	return .None
}

// The byte that starts a comment in a markup text `put_markup` reads: no string or bare scalar of the text holds it.
@(private = "file")
MARKUP_COMMENT :: '\x01'

// Writes comment `text` of `role` into a markup text `put_markup` reads, which puts it on the value it stands by.
put_marked_comment :: proc(out: ^Out, role: core.Role, text: string) -> core.Typed_Error_Kind {
	put_byte(out, MARKUP_COMMENT)
	put_byte(out, '0' + u8(role))
	return put_marked(out, nil, text, nil)
}

// A markup format's write of a built value as `opts` say, to `stream` or into new bytes from `allocator`.
Markup_Put :: proc(v: core.Value, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator) -> ([]u8, core.Typed_Refusal)

// A markup format's write of the text a typed write made in `MARKUP_TREE`, for a text that holds no comment.
Markup_Tree_Put :: proc(tree: string, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator) -> ([]u8, core.Typed_Refusal)

// A markup format's `marshal`: the typed write makes `value` in `MARKUP_TREE` with `put_marked`'s strings, which `put`
// writes as `put_markup` reads it. A format with a `direct` write takes a text with no comment from it, with no value
// built.
marshal_markup :: proc(plan: ^typed.Plan, value: rawptr, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, omits: ^typed.Omits, put: Markup_Put, direct: Markup_Tree_Put = nil) -> ([]u8, core.Typed_Refusal) {
	flat := opts
	flat.pretty, flat.sort_keys = false, false
	tree, err := marshal_as(plan, value, flat, {}, context.allocator, MARKUP_TREE, put_marked, put_marked, omits)
	if err.kind != .None {
		return nil, err
	}
	defer delete(tree)
	if direct != nil && strings.index_byte(string(tree), MARKUP_COMMENT) < 0 {
		return direct(string(tree), opts, stream, allocator)
	}
	return put_markup(string(tree), opts, stream, allocator, put)
}

// Reads `s`, made in `MARKUP_TREE` with `put_marked`'s strings, into a built value in an arena of its own and gives it
// to `put`. A bare scalar is its text, and `null` is nil. A comment is written on the value it stands by: a lead one
// on the next value, an inline one on the value last written and a foot one on the innermost open container, or on
// the root when none is open. A lead one in an empty container is that container's foot one.
put_markup :: proc(s: string, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, put: Markup_Put) -> ([]u8, core.Typed_Refusal) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {
		return nil, {kind = .No_Memory}
	}
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	root: core.Value
	open: [dynamic]core.Value
	lead: [dynamic]string
	key: string
	for i := 0; i < len(s); i += 1 {
		v: core.Value
		switch s[i] {
		case MARKUP_COMMENT:
			role := core.Role(s[i + 1] - '0')
			end := i + 3 + strings.index_byte(s[i + 3:], 0)
			text := s[i + 3:end]
			i = end
			#partial switch role {
			case .Comment:
				append(&lead, text)
			case .Comment_Foot:
				note(foot_of(&root, open[:]), role, text)
			case:
				note(last_item(open[len(open) - 1]) if len(open) > 0 else &root, role, text)
			}
			continue
		case ' ', '\t', '\n', ',', ':':
			continue
		case '}', ']':
			for text in lead {
				note(foot_of(&root, open[:]), .Comment_Foot, text)
			}
			lead = {}
			pop(&open)
			continue
		case '{':
			v = core.new_object()
		case '[':
			v = core.new_array()
		case '"':
			end := i + 1 + strings.index_byte(s[i + 1:], 0)
			text := s[i + 1:end]
			i = end
			if i + 1 < len(s) && s[i + 1] == ':' {
				key = text
				continue
			}
			v = text
		case:
			end := i
			for end < len(s) && strings.index_byte(",}] \t\n\x01", s[end]) < 0 {
				end += 1
			}
			if s[i:end] != "null" {
				v = s[i:end]
			}
			i = end - 1
		}
		at := v
		if len(lead) > 0 {
			at = core.noted(v, .Comment, lead[:])
			lead = {}
		}
		if len(open) == 0 {
			root = at
		} else if up, is_object := open[len(open) - 1].(^core.Object); is_object {
			core.object_append(up, key, at)
		} else {
			core.array_append(open[len(open) - 1].(^core.Array), at)
		}
		#partial switch _ in v {
		case ^core.Object, ^core.Array:
			append(&open, v)
		}
	}
	return put(root, opts, stream, allocator)
}

// The value a foot comment stands on while `open` are the open containers: the innermost one, or `root`.
@(private = "file")
foot_of :: proc(root: ^core.Value, open: []core.Value) -> ^core.Value {
	if len(open) < 2 {
		return root
	}
	return last_item(open[len(open) - 2])
}

@(private = "file")
note :: proc(at: ^core.Value, role: core.Role, text: string) {
	bodies, _ := core.comments(at^, role)
	all := make([]string, len(bodies) + 1)
	copy(all, bodies)
	all[len(bodies)] = text
	at^ = core.noted(at^, role, all)
}

@(private = "file")
last_item :: proc(up: core.Value) -> ^core.Value {
	if o, is_object := up.(^core.Object); is_object {
		vals := core.object_vals(o)
		return &vals[len(vals) - 1]
	}
	a := up.(^core.Array)
	return &a.items[len(a.items) - 1]
}
