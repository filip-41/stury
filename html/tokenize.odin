package html

import "base:intrinsics"
import "base:runtime"
import spell "../core/spell"
import core "../core"
import kernel "../core/kernel"

// HTML's tokenizer: the states of the WHATWG standard's section 13.2.5 (states.odin), the character references
// (refs.odin), and the input stream's preprocessing. It reads UTF-8. A token's text is a span of the source, read
// through `decode`, so a token costs no copy.

// The kinds of HTML text a read takes: a whole document, or a fragment, whose top-level nodes have no `html` element
// around them.
Spec :: enum u8 {
	Document,
	Fragment,
}

// Run-time options for a read. The zero value is the default.
Options :: struct {
	// The deepest nesting a tree may have, 0 for `core.MAX_DEPTH`.
	max_depth:         u32,
	// A text value that is `true`, `false` or exactly a JSON number reads as a boolean or a number, where every
	// non-empty value is a string by default. An empty one is a null either way. Read by `core.kind`, not by the tree.
	infer:             bool,
	// Read as a browser with scripting enabled reads: a `noscript` element's content is raw text.
	scripting:         bool,
	// A fragment's context element, by its local name, in `context_namespace`. Empty is `body`. The tree reads the
	// name only as its tag and the foreign names it matches, so two names the tree treats alike read alike.
	context_name:      string,
	context_namespace: Namespace,
}

// What a read of the tree takes from `Options`, which a handle holds in its option bytes.
@(private)
Read :: struct {
	max_depth: u32,
	infer:     bool,
	scripting: bool,
	fragment:  Context,
}

// A fragment's context element as the tree reads it: its namespace, its tag, and the index of its entry in
// FOREIGN_NAMES.
@(private)
Context :: struct {
	ns:      Namespace,
	tag:     Tag,
	name:    u8,
}

#assert(len(FOREIGN_NAMES) <= 256)

// The read `opts` asks for.
@(private)
read_of :: proc "contextless" (opts: Options) -> Read {
	name := opts.context_name if opts.context_name != "" else "body"
	n := u32(min(len(name), int(max(u32))))
	return {
		max_depth = opts.max_depth,
		infer = opts.infer,
		scripting = opts.scripting,
		fragment = {ns = opts.context_namespace, tag = tag_of(transmute([]u8)name, Span{n = n}), name = u8(foreign_of(raw_data(name), n))},
	}
}

// The namespaces of HTML's elements.
Namespace :: enum u8 {
	Html,
	Svg,
	Math,
}

// The parse errors of an HTML text. The tokenizer's come first, by the names the standard gives them, `-` read as `_`,
// then the tree construction's, which the standard does not name. A read reports each and goes on.
Detail :: enum u8 {
	None,
	Abrupt_Closing_Of_Empty_Comment,
	Abrupt_Doctype_Public_Identifier,
	Abrupt_Doctype_System_Identifier,
	Absence_Of_Digits_In_Numeric_Character_Reference,
	Cdata_In_Html_Content,
	Character_Reference_Outside_Unicode_Range,
	Control_Character_In_Input_Stream,
	Control_Character_Reference,
	Disallowed_Processing_Instruction_Target,
	Duplicate_Attribute,
	End_Tag_With_Attributes,
	End_Tag_With_Trailing_Solidus,
	Eof_Before_Tag_Name,
	Eof_In_Cdata,
	Eof_In_Comment,
	Eof_In_Doctype,
	Eof_In_Processing_Instruction,
	Eof_In_Script_Html_Comment_Like_Text,
	Eof_In_Tag,
	Incorrectly_Closed_Comment,
	Incorrectly_Opened_Comment,
	Invalid_Character_Sequence_After_Doctype_Name,
	Invalid_First_Character_Of_Processing_Instruction_Target,
	Invalid_First_Character_Of_Tag_Name,
	Invalid_Processing_Instruction_Target,
	Missing_Attribute_Value,
	Missing_Doctype_Name,
	Missing_Doctype_Public_Identifier,
	Missing_Doctype_System_Identifier,
	Missing_End_Tag_Name,
	Missing_Quote_Before_Doctype_Public_Identifier,
	Missing_Quote_Before_Doctype_System_Identifier,
	Missing_Semicolon_After_Character_Reference,
	Missing_Whitespace_After_Doctype_Public_Keyword,
	Missing_Whitespace_After_Doctype_System_Keyword,
	Missing_Whitespace_Before_Doctype_Name,
	Missing_Whitespace_Between_Attributes,
	Missing_Whitespace_Between_Doctype_Public_And_System_Identifiers,
	Nested_Comment,
	Noncharacter_Character_Reference,
	Noncharacter_In_Input_Stream,
	Non_Void_Html_Element_Start_Tag_With_Trailing_Solidus,
	Null_Character_Reference,
	Surrogate_Character_Reference,
	Surrogate_In_Input_Stream,
	Unexpected_Character_After_Doctype_System_Identifier,
	Unexpected_Character_In_Attribute_Name,
	Unexpected_Character_In_Unquoted_Attribute_Value,
	Unexpected_Equals_Sign_Before_Attribute_Name,
	Unexpected_Null_Character,
	Unexpected_Solidus_In_Tag,
	Unknown_Named_Character_Reference,
	Missing_Doctype,
	Bad_Doctype,
	Unexpected_Doctype,
	Unexpected_Start_Tag,
	Unexpected_End_Tag,
	Unexpected_Text,
	Unclosed_Element,
	Misnested_Tag,
	Encoding, // `Bad_Char`: a byte order mark or a `meta` names an encoding other than UTF-8, at the label
	Constructed, // `Frozen`: a node the tree construction implied, moved or copied, which no bytes of the source spell where it stands
	Split, // `Frozen`: a text the tree construction joined across a tag
	Reordered, // `Frozen`: a reorder of an element's children
	Not_Name, // `Frozen`: a rename of `#text`, or to a name HTML does not read as written
	Text_Markup, // `Frozen`: a text run or a raw text element given an element or an array
	Nested_Array, // `Frozen`: an array set as the document, which has one root element
	Comment_Body, // `Frozen`: a comment body HTML does not read back as written
	Attribute_Body, // `Frozen`: an attribute body that is not one attribute HTML reads as written
	No_Place, // `Frozen`: a fact or a member on a node that has no place for it
	Void, // `Frozen`: content given a void element
	Reread, // `Bad_Result`: an edited text whose tree is not the edited tree
}

// An HTML text's rules, indexed by `Detail`.
@(rodata)
RULES := core.Rules{"html", {
	{},
	{"abrupt_closing_of_empty_comment", "Empty comment closed by `>`"},
	{"abrupt_doctype_public_identifier", "DOCTYPE public identifier closed by `>`"},
	{"abrupt_doctype_system_identifier", "DOCTYPE system identifier closed by `>`"},
	{"absence_of_digits_in_numeric_character_reference", "Numeric character reference without digits"},
	{"cdata_in_html_content", "CDATA section outside foreign content"},
	{"character_reference_outside_unicode_range", "Character reference past U+10FFFF"},
	{"control_character_in_input_stream", "Control character"},
	{"control_character_reference", "Character reference to a control character"},
	{"disallowed_processing_instruction_target", "Processing instruction target `xml` or `xml-stylesheet`"},
	{"duplicate_attribute", "Attribute written twice"},
	{"end_tag_with_attributes", "End tag with attributes"},
	{"end_tag_with_trailing_solidus", "End tag closed by `/>`"},
	{"eof_before_tag_name", "Text ends before a tag name"},
	{"eof_in_cdata", "Text ends inside a CDATA section"},
	{"eof_in_comment", "Text ends inside a comment"},
	{"eof_in_doctype", "Text ends inside a DOCTYPE"},
	{"eof_in_processing_instruction", "Text ends inside a processing instruction"},
	{"eof_in_script_html_comment_like_text", "Text ends inside `<!--` in a script"},
	{"eof_in_tag", "Text ends inside a tag"},
	{"incorrectly_closed_comment", "Comment closed by `--!>`"},
	{"incorrectly_opened_comment", "Markup declaration that is no comment, DOCTYPE or CDATA section"},
	{"invalid_character_sequence_after_doctype_name", "Text after a DOCTYPE name that is no PUBLIC or SYSTEM"},
	{"invalid_first_character_of_processing_instruction_target", "Processing instruction target starts with no letter"},
	{"invalid_first_character_of_tag_name", "Tag name starts with no letter"},
	{"invalid_processing_instruction_target", "Character not allowed in a processing instruction target"},
	{"missing_attribute_value", "Attribute `=` before `>`"},
	{"missing_doctype_name", "DOCTYPE without a name"},
	{"missing_doctype_public_identifier", "PUBLIC without an identifier"},
	{"missing_doctype_system_identifier", "SYSTEM without an identifier"},
	{"missing_end_tag_name", "End tag `</>`"},
	{"missing_quote_before_doctype_public_identifier", "DOCTYPE public identifier without a quote"},
	{"missing_quote_before_doctype_system_identifier", "DOCTYPE system identifier without a quote"},
	{"missing_semicolon_after_character_reference", "Character reference without `;`"},
	{"missing_whitespace_after_doctype_public_keyword", "No whitespace after PUBLIC"},
	{"missing_whitespace_after_doctype_system_keyword", "No whitespace after SYSTEM"},
	{"missing_whitespace_before_doctype_name", "No whitespace before the DOCTYPE name"},
	{"missing_whitespace_between_attributes", "No whitespace between attributes"},
	{"missing_whitespace_between_doctype_public_and_system_identifiers", "No whitespace between the DOCTYPE identifiers"},
	{"nested_comment", "`<!--` inside a comment"},
	{"noncharacter_character_reference", "Character reference to a noncharacter"},
	{"noncharacter_in_input_stream", "Noncharacter"},
	{"non_void_html_element_start_tag_with_trailing_solidus", "`/>` on an element that is not void"},
	{"null_character_reference", "Character reference to U+0000"},
	{"surrogate_character_reference", "Character reference to a surrogate"},
	{"surrogate_in_input_stream", "Surrogate"},
	{"unexpected_character_after_doctype_system_identifier", "Text after the DOCTYPE system identifier"},
	{"unexpected_character_in_attribute_name", "`\"`, `'` or `<` in an attribute name"},
	{"unexpected_character_in_unquoted_attribute_value", "`\"`, `'`, `<`, `=` or a backtick in an unquoted attribute value"},
	{"unexpected_equals_sign_before_attribute_name", "`=` before an attribute name"},
	{"unexpected_null_character", "U+0000"},
	{"unexpected_solidus_in_tag", "`/` inside a tag"},
	{"unknown_named_character_reference", "Unknown named character reference"},
	{"missing_doctype", "Document without a DOCTYPE"},
	{"bad_doctype", "DOCTYPE other than `<!DOCTYPE html>`"},
	{"unexpected_doctype", "DOCTYPE after the start of the document"},
	{"unexpected_start_tag", "Start tag where its element cannot go"},
	{"unexpected_end_tag", "End tag of no element open where it stands"},
	{"unexpected_text", "Text where only whitespace can go"},
	{"unclosed_element", "Element left open by the tag that closed its parent"},
	{"misnested_tag", "Formatting element closed out of order"},
	{"encoding", "Encoding other than UTF-8"},
	{"constructed", "Node is implied, moved or copied by the tree construction"},
	{"split", "Text is joined across a tag by the tree construction"},
	{"reordered", "An element's children keep their order"},
	{"not_name", "An element's name is a lower-case HTML name, and `#text` is no element"},
	{"text_markup", "Text holds no element and no array"},
	{"nested_array", "An element holds no array: an array is the elements of one name"},
	{"comment_body", "A comment does not start with `>` or `->`, hold `<!--`, `-->` or `--!>`, or end in `<!-`"},
	{"attribute_body", "An attribute fact is one attribute with a lower-case name"},
	{"no_place", "This node has no place for the fact or the member"},
	{"void", "A void element holds no content"},
	{"reread", "The edited text reads as another tree"},
}}

// The states a read starts in, or that a hook switches it to after a start tag: data, RCDATA (`title`, `textarea`),
// RAWTEXT (`style`, `xmp`, `iframe`, `noembed`, `noframes`), script data, PLAINTEXT and a CDATA section.
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
Token_Kind :: enum u8 {
	Text, // `data` is the characters
	Start_Tag, // `name`, `attrs` and `.Self_Closing`
	End_Tag, // `name`, and attributes and `.Self_Closing` the standard reports as errors
	Comment, // `data`
	Doctype, // `name`, `public_id`, `system_id` and `.Force_Quirks`
	Instruction, // a processing instruction: `name` is its target, `data` the rest
	Error, // a parse error, `detail`, at byte `lo`
}

@(private)
Token_Flag :: enum u8 {
	Self_Closing,
	Force_Quirks,
}

// How `decode` reads a span: which state the tokenizer read its characters in.
@(private)
Mode :: enum u8 {
	Data, // text of the data state: character references, U+0000 kept
	Text, // text of the data state as a tree reads it in HTML content: character references, U+0000 dropped
	Rcdata, // text of the RCDATA state: character references, U+0000 as U+FFFD
	Raw, // RAWTEXT, script data, PLAINTEXT, comments and DOCTYPE identifiers: U+0000 as U+FFFD
	Verbatim, // CDATA sections and processing instructions: U+0000 kept
	Name, // tag, attribute and DOCTYPE names: ASCII upper case lowered, U+0000 as U+FFFD
	Value, // attribute values: character references read as in an attribute, U+0000 as U+FFFD
}

// What a span holds that `decode` must change. A span with none reads as its source bytes.
@(private)
Span_Flag :: enum u8 {
	Ref, // an `&`
	Nul, // U+0000
	Upper, // an ASCII capital letter, in a `.Name` span
	Cr, // a carriage return, read as a line feed, and CR LF as one
	Invalid, // ill-formed UTF-8, read as U+FFFD per maximal subpart
	Missing, // a DOCTYPE field the text did not give, distinct from an empty one
}

@(private)
Span_Flags :: bit_set[Span_Flag; u8]

// `n` source bytes from `lo`, read as `mode` says.
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

// A token, valid during the hook's call. `lo` and `hi` are the source bytes it covers. The spans a kind does not use
// are zero.
@(private)
Html_Token :: struct {
	lo, hi:               u64,
	name, data:           Span,
	public_id, system_id: Span,
	attrs:                []Attribute,
	kind:                 Token_Kind,
	flags:                bit_set[Token_Flag; u8],
	detail:               Detail,
}

// A hook's answer to a token. `.Rcdata` to `.Plaintext` switch the tokenizer to that state after a start tag, as the
// tree construction does, and imply `.Html`. `.Foreign` says the adjusted current node is now outside the HTML
// namespace, where `<![CDATA[` opens a CDATA section, and `.Html` that it is back in it.
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

// Reads `src` from byte `from`, an input stream in UTF-8, as HTML tokens from state `start`, and hands each to `on`,
// parse errors included. `last_start_tag` is the tag an end tag in `start` must match before any start tag is read, and
// `in_foreign` says the adjusted current node starts outside the HTML namespace. Returns where the read ended,
// `.No_Memory` when a tag's attributes outgrew `allocator` and `.Too_Wide` at a span longer than 4 GiB, and whether
// `on` stopped it. A byte order mark is a character here: the encoding layer reads from past it.
@(private)
tokenize :: proc(src: []u8, h: ^$H, $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, start := Content.Data, last_start_tag := "", from := u64(0), in_foreign := false, allocator := context.allocator) -> (hi: u64, fault: Maybe(core.Fault), stopped: bool) {
	t: Tokenizer(H)
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
	case .Data:
		r = st_data(p, end, &t, on)
	case .Rcdata:
		r = st_rcdata(p, end, &t, on)
	case .Rawtext:
		r = st_rawtext(p, end, &t, on)
	case .Script_Data:
		r = st_script(p, end, &t, on)
	case .Plaintext:
		r = st_plaintext(p, end, &t, on)
	case .Cdata_Section:
		r = st_cdata(p, end, &t, on)
	}
	delete(t.heap, t.allocator)
	delete(t.hash, t.allocator)
	return core.result_of(r, &RULES)
}

// Returns the bytes `decode` may write for `s`: an ill-formed byte or U+0000 widens to three, and no character
// reference is shorter than its value.
@(private)
decode_room :: proc "contextless" (s: Span) -> int {
	return int(s.n) * 3
}

// The tag a start tag's name is compared with, held where `last_start_tag` or the source keeps it.
@(private)
Tokenizer :: struct($H: typeid) {
	h:          ^H,
	base:       [^]u8, // the source's first byte, position 0
	tok:        Html_Token, // the tag, comment, DOCTYPE or processing instruction being read
	text_lo:    u64, // where the pending text run starts
	text_hi:    u64, // where it ends if the markup after it makes a token
	lo:         u64, // where the span being read starts
	mark:       u64, // the temporary buffer's start, or where a comment's or instruction's data may end
	judged:     u64, // input stream errors are reported for characters from here
	text_flags: Span_Flags,
	flags:      Span_Flags, // the span being read
	text_mode:  Mode,
	content:    Content, // the text state the tokenizer is in
	back:       Back, // the text state a failed end tag returns to
	ret:        Return, // the state a character reference returns to
	quote:      u8, // the quote a DOCTYPE identifier ends at
	in_foreign: bool, // the adjusted current node is outside the HTML namespace
	kept:       bool, // the current attribute is no duplicate, so its value is stored
	wide:       bool, // a span was longer than 4 GiB
	oom:        bool, // a tag's attributes outgrew the allocator
	last_set:   bool,
	last_plain: bool, // the last start tag's name has no U+0000 or ill-formed UTF-8, so an end tag can match it
	last:       []u8,
	attr_n:     int,
	attrs:      []Attribute, // `inline` or `heap`
	heap:       []Attribute,
	hash:       []u32, // 1 + an index of `attrs`, by name, once a tag has more than `ATTRS_INLINE` attributes
	allocator:  runtime.Allocator,
	inline:     [ATTRS_INLINE]Attribute,
}

// The attributes a tag holds before they move to the heap. Up to this many are compared one by one for duplicates,
// and past it a hash table finds them.
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

// The tokenizer's states are built for the lowest CPU tier.
@(private)
STATE_TIER :: kernel.Tier(0)
@(private)
STATE_FEATURES :: kernel.FEATURES[STATE_TIER]

// Byte classes. `C_JUDGE` is every byte whose character the input stream judges or that a span must mark: CR, the
// controls other than tab, LF, FF and U+0000, DEL and every byte past ASCII.
@(private)
C_WS :: 0x01
@(private)
C_UPPER :: 0x02
@(private)
C_LOWER :: 0x04
@(private)
C_DIGIT :: 0x08
@(private)
C_HEX :: 0x10 // A to F and a to f
@(private)
C_JUDGE :: 0x20
@(private)
C_TAG_END :: 0x40 // `/`, `>` and U+0000
@(private)
C_ATTR_END :: 0x80 // `=`, `"`, `'` and `<`

@(private)
C_ALPHA :: C_UPPER | C_LOWER
@(private)
C_ALNUM :: C_ALPHA | C_DIGIT

@(private, rodata)
CLASS := [256]u8 {
	0x00            = C_TAG_END,
	0x01 ..= 0x08   = C_JUDGE,
	'\t'            = C_WS,
	'\n'            = C_WS,
	0x0B            = C_JUDGE,
	0x0C            = C_WS,
	'\r'            = C_WS | C_JUDGE,
	0x0E ..= 0x1F   = C_JUDGE,
	' '             = C_WS,
	'"'             = C_ATTR_END,
	'\''            = C_ATTR_END,
	'/'             = C_TAG_END,
	'0' ..= '9'     = C_DIGIT,
	'<'             = C_ATTR_END,
	'='             = C_ATTR_END,
	'>'             = C_TAG_END,
	'A' ..= 'F'     = C_UPPER | C_HEX,
	'G' ..= 'Z'     = C_UPPER,
	'a' ..= 'f'     = C_LOWER | C_HEX,
	'g' ..= 'z'     = C_LOWER,
	0x7F            = C_JUDGE,
	0x80 ..= 0xFF   = C_JUDGE,
}

// The stop sets of the states that read runs, each the bytes its state acts on and every byte `C_JUDGE` holds but
// CR's own entry. `classes` sorts a byte into a set by its two nibbles. Data and RCDATA stop at `&`, `<`, CR and
// U+0000, RAWTEXT and script data at `<`, CR and U+0000, PLAINTEXT at CR and U+0000, the escaped script states and
// comments at `-`, `<`, CR and U+0000, a CDATA section at `]`, CR and U+0000, a bogus comment at `>`, CR and U+0000, a quoted
// attribute value at its quote, `&`, CR and U+0000, and an instruction's data at `?`, `>` and CR.
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

// Returns the first byte from `p` in `table`'s set, or `end`. Reads 64-byte blocks, the last one padded.
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
		b := kernel.load_padded(STATE_TIER, q[:live], 0)
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
	case .Data:
		return .Data
	case .Rcdata:
		return .Rcdata
	case .Rawtext, .Script_Data, .Plaintext:
		return .Raw
	case .Cdata_Section:
		return .Verbatim
	}
	return .Data
}

@(private)
span_of :: #force_inline proc "contextless" (t: ^Tokenizer($H), lo, hi: u64, mode: Mode, flags: Span_Flags) -> Span {
	t.wide ||= hi - lo > u64(max(u32))
	return {lo = lo, n = u32(hi - lo), mode = mode, flags = flags}
}

// The result of a read that must end at `q`: out of memory, a span too wide, or the hook stopped it.
@(private)
halt :: proc "contextless" (t: ^Tokenizer($H), q: [^]u8) -> u64 {
	if t.oom {
		return core.fault_at(0, .No_Memory)
	}
	if t.wide {
		return core.fault_at(at(t, q), .Too_Wide)
	}
	return core.fault_at(at(t, q), .None, core.STOPPED)
}

// Reports parse error `d` at `q` and returns whether the hook stopped the read.
@(private)
report :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, q: [^]u8, d: Detail) -> bool {
	e := Html_Token{kind = .Error, lo = at(t, q), hi = at(t, q), detail = d}
	return on(t.h, &e) == .Stop
}

// Hands the pending text run up to `hi` to the hook, then starts the next at `next`. Returns whether the hook stopped.
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
	// Text can reopen formatting elements at an integration point, which leaves foreign content.
	#partial switch on(t.h, &text) {
	case .Stop:
		return true
	case .Foreign:
		t.in_foreign = true
	case .Html:
		t.in_foreign = false
	}
	return false
}

// Hands the pending text and then `t.tok`, which ends before `q`, to the hook, and switches to the state the hook
// names, the data state by default. Returns whether the read must end: the hook stopped it or a span was too wide.
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
	case .Stop:
		return true
	case .Rcdata:
		t.content, t.text_mode, t.in_foreign = .Rcdata, .Rcdata, false
	case .Rawtext:
		t.content, t.text_mode, t.in_foreign = .Rawtext, .Raw, false
	case .Script_Data:
		t.content, t.text_mode, t.in_foreign = .Script_Data, .Raw, false
	case .Plaintext:
		t.content, t.text_mode, t.in_foreign = .Plaintext, .Raw, false
	case .Foreign:
		t.in_foreign = true
	case .Html:
		t.in_foreign = false
	}
	return false
}

// Ends the read at the text's end, the pending text running to `hi`. A stop at the end is the end.
@(private)
finish :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, end: [^]u8, hi: u64) -> u64 {
	flush(t, on, hi, at(t, end))
	if t.wide {
		return core.fault_at(at(t, end), .Too_Wide)
	}
	return core.fault_at(at(t, end), .None)
}

// Hands `t.tok` to the hook at the text's end and ends the read.
@(private)
emit_at_end :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, end: [^]u8) -> u64 {
	if emit(t, on, end) {
		return halt(t, end)
	}
	return finish(t, on, end, at(t, end))
}

// The text ends inside a tag, which is dropped.
@(private)
eof_in_tag :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, end: [^]u8) -> u64 {
	if report(t, on, end, .Eof_In_Tag) {
		return halt(t, end)
	}
	return finish(t, on, end, t.text_hi)
}

// The text ends inside a processing instruction, which is dropped. The error sits at the target's end once the target
// is read, as the html5lib tests place it.
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

// The text ends inside escaped script data, all of it characters.
@(private)
eof_in_script_comment :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, end: [^]u8) -> u64 {
	if report(t, on, end, .Eof_In_Script_Html_Comment_Like_Text) {
		return halt(t, end)
	}
	return finish(t, on, end, at(t, end))
}

// The text ends inside a comment, whose data runs from `t.lo` to `t.mark`.
@(private)
eof_in_comment :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, end: [^]u8) -> u64 {
	if report(t, on, end, .Eof_In_Comment) {
		return halt(t, end)
	}
	t.tok.data = span_of(t, t.lo, t.mark, .Raw, t.flags)
	return emit_at_end(t, on, end)
}

// The text ends inside a DOCTYPE, which is emitted with the force-quirks flag.
@(private)
eof_in_doctype :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, end: [^]u8) -> u64 {
	t.tok.flags += {.Force_Quirks}
	if report(t, on, end, .Eof_In_Doctype) {
		return halt(t, end)
	}
	return emit_at_end(t, on, end)
}

// Sets the DOCTYPE's force-quirks flag and reports error `d` at `p`, after judging the character there first when the
// state consumes it. Returns whether the hook stopped the read.
@(private)
doctype_error :: proc "contextless" (t: ^Tokenizer($H), $on: proc "contextless" (h: ^H, t: ^Html_Token) -> Token_Action, p, end: [^]u8, d: Detail, consumes: bool) -> bool {
	t.tok.flags += {.Force_Quirks}
	return consumes && judge_first(t, on, p, end) || report(t, on, p, d)
}

// Judges the character at `p` before a state reports its own error there, as the input stream reports a character's
// errors when it is consumed. Returns whether the hook stopped the read.
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

// Starts a comment whose `<` is at byte `lo` and whose data starts at `p`.
@(private)
open_comment :: #force_inline proc "contextless" (t: ^Tokenizer($H), lo: u64, p: [^]u8) {
	t.tok = Html_Token{kind = .Comment, lo = lo}
	t.lo = at(t, p)
	t.flags = {}
}

// Whether the temporary buffer, the letters from `t.mark` to `q`, is `script`.
@(private)
is_script :: #force_inline proc "contextless" (t: ^Tokenizer($H), q: [^]u8) -> bool {
	return at(t, q) - t.mark == 6 && fold_equal(t.base[t.mark:], transmute([]u8)string("script"))
}

// Starts a DOCTYPE identifier whose quote is at `p`.
@(private)
open_id :: #force_inline proc "contextless" (t: ^Tokenizer($H), p: [^]u8) {
	t.quote = p[0]
	t.lo = at(t, p) + 1
	t.flags = {}
}

// Reads a DOCTYPE identifier from `p` to its quote, a `>` or the text's end, and returns where it stopped.
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

// Judges the character at `q`, whose first byte `C_JUDGE` holds. Returns its length and adds what decoding it needs to
// `flags`. A control or a noncharacter is reported the first time a state consumes it, so a reconsumed character is
// reported once.
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

// The code point of the well-formed `n`-byte UTF-8 sequence at `q`.
@(private)
code_point :: #force_inline proc "contextless" (q: [^]u8, n: int) -> u32 {
	switch n {
	case 2:
		return u32(q[0] & 0x1F) << 6 | u32(q[1] & 0x3F)
	case 3:
		return u32(q[0] & 0x0F) << 12 | u32(q[1] & 0x3F) << 6 | u32(q[2] & 0x3F)
	case 4:
		return u32(q[0] & 0x07) << 18 | u32(q[1] & 0x3F) << 12 | u32(q[2] & 0x3F) << 6 | u32(q[3] & 0x3F)
	}
	return u32(q[0])
}

// Starts tag `kind` whose `<` is at byte `lo` and whose name starts at `p`.
@(private)
open_tag :: #force_inline proc "contextless" (t: ^Tokenizer($H), kind: Token_Kind, lo: u64, p: [^]u8) {
	t.tok = Html_Token{kind = kind, lo = lo}
	t.attr_n = 0
	t.lo = at(t, p)
	t.flags = {}
}

// Ends the tag's name before `q`.
@(private)
end_name :: #force_inline proc "contextless" (t: ^Tokenizer($H), q: [^]u8) {
	t.tok.name = span_of(t, t.lo, at(t, q), .Name, t.flags)
}

// Hands the tag, whose `>` is at `q`, to the hook. Returns whether the read must end.
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

// Whether the end tag name from `t.lo` to `q`, ASCII letters, is an appropriate end tag: the last start tag's name.
@(private)
appropriate :: #force_inline proc "contextless" (t: ^Tokenizer($H), q: [^]u8) -> bool {
	n := int(at(t, q) - t.lo)
	if !t.last_set || !t.last_plain || n != len(t.last) {
		return false
	}
	return fold_equal(t.base[t.lo:], t.last)
}

// Whether `a` and `b`, of one length, are equal with ASCII letters folded.
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

// Starts an attribute whose name starts at `p`.
@(private)
open_attr :: #force_inline proc "contextless" (t: ^Tokenizer($H), p: [^]u8) {
	t.lo = at(t, p)
	t.flags = {}
}

// Ends the current attribute's name before `q` and adds the attribute to the tag unless it repeats a name, which is
// reported. Returns whether the read must end.
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

// Sets the current attribute's value to the bytes from `t.lo` to `q`.
@(private)
end_value :: #force_inline proc "contextless" (t: ^Tokenizer($H), q: [^]u8) {
	if t.kept {
		t.attrs[t.attr_n - 1].value = span_of(t, t.lo, at(t, q), .Value, t.flags)
	}
}

// Whether a tag attribute already has `name`.
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

// Doubles the room for attributes, and the hash table once it is in use. Returns false when out of memory, which ends
// the read with `.No_Memory`.
@(private)
grow_attrs :: #force_no_inline proc "contextless" (t: ^Tokenizer($H)) -> bool {
	bigger, ok := regrow(t.attrs, t.heap, 2 * len(t.attrs), t.allocator)
	if !ok {
		t.oom = true
		return false
	}
	t.heap = bigger
	t.attrs = bigger
	return t.attr_n <= ATTRS_INLINE || rehash(t)
}

// Builds the hash table of the tag's attributes, twice the room of `attrs`. Returns false when out of memory.
@(private)
rehash :: #force_no_inline proc "contextless" (t: ^Tokenizer($H)) -> bool {
	room := 2 * len(t.attrs)
	if len(t.hash) != room {
		ok: bool
		t.hash, ok = fresh_hash(t.hash, room, t.allocator)
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

// Returns `n` attributes from `allocator` that start with `kept`, and frees `heap`, or false when out of memory.
@(private)
regrow :: proc "contextless" (kept, heap: []Attribute, n: int, allocator: runtime.Allocator) -> ([]Attribute, bool) {
	context = runtime.default_context()
	bigger, err := make([]Attribute, n, allocator)
	if err != nil {
		return nil, false
	}
	copy(bigger, kept)
	delete(heap, allocator)
	return bigger, true
}

// Frees `old` and returns a zeroed table of `n` slots from `allocator`, or false when out of memory.
@(private)
fresh_hash :: proc "contextless" (old: []u32, n: int, allocator: runtime.Allocator) -> ([]u32, bool) {
	context = runtime.default_context()
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

// Whether names `a` and `b` decode to the same characters.
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

// FNV-1a over a name's characters.
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

// The next character of name `s` from its byte `i^`, lowered, U+0000 and ill-formed UTF-8 read as U+FFFD, or -1 at its
// end. Steps `i^` over it.
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
