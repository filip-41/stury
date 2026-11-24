package tape

import "base:intrinsics"
import "stury:lib/base/spell"

// A token is one piece of a text as a format's walk reads it: a value, a key, a fact or the end of a container. Walks
// hand tokens to hooks in text order, and a document stores them as its nodes.

// The type of a token.
Kind :: enum u8 {
	Null,
	False,
	True,
	Number,
	Bytes,
	String,
	Plain,
	Array,
	Object,
	End, // closes the innermost container, never stored in a document
}

// Scalars come before containers, and containers before `End`, so a hook tells them apart with one compare.
#assert(Kind.Plain < Kind.Array && Kind.Array < Kind.Object && Kind.Object < Kind.End)

// A token's place in its container. Group facts with other roles.
Role :: enum u8 {
	Value,
	Key,
	Comment, // before the value that follows it
	Comment_Inline, // on the line where the value before it ends
	Comment_Foot, // after the last value or in an empty container, on that container
	Tag,
	Anchor,
	Alias,
	Instruction, // before the value that follows it
	Instruction_Foot, // after the last value or in an empty container, on that container
	Doctype,
	Directive,
	Attribute,
}

// Facts come after `Key`, so a hook tells a fact from a value or key with one compare.
#assert(Role.Value < Role.Key && Role.Key < Role.Comment)

// A token from a walk, also stored as a document node.
Token :: struct {
	lo:       u64,
	// Byte length. In a document a container's is its subtree's node count instead, so its next sibling is `i + n`.
	n:        u32,
	kind:     Kind,
	role:     Role,
	// The format's detail. In a document a container's is its child count instead, saturated at `MAX_CHILDREN`, with
	// its `CONTAINER_STYLE` and `CONTAINER_PARTIAL`.
	spelling: u16,
}

Node :: Token

// An index into `Document.nodes`. A build refuses a text that makes `NO_NODE` nodes.
Node_Index :: distinct u32

ROOT :: Node_Index(0)
NO_NODE :: Node_Index(max(u32))

MAX_CHILDREN :: u16(0x1FFF)

// In a container's spelling, how the format wrote it, as CBOR's definite or indefinite length, YAML's flow or block
// and TOML's inline table, in bits a walk sets on the token that opens it and on the `End` that closes it, which a
// document keeps beside the count. A build takes them from the `End`, which is in hand, rather than read the node back.
CONTAINER_STYLE :: u16(0x6000)

// In a container's spelling in a document, a container a path read kept only part of. Its `n` covers the children kept,
// and its count is every child it has. With its count saturated and no entry in `Document.counts` its count is not
// known, as for one passed unread, which keeps none, and one a stop left open.
CONTAINER_PARTIAL :: u16(0x8000)

// A container's true child count, where `spelling` saturated.
Child_Count :: struct {
	node:  Node_Index,
	count: u32,
}

// Bits 0 to 10 of a text's spelling mean the same in every format, and bits 11 to 15 are a format's own.
SPELLING_DECODE :: u16(1)
SPELLING_QUOTED :: u16(2)
// In a key's spelling, beside `SPELLING_DECODE`, the key holds no bytes of the text: `n` is 0 and `lo` is its place,
// which the format's decode writes out, as a delimited row's cell past its header is named by its position.
SPELLING_PLACED :: u16(8)
// In a text's spelling, beside `SPELLING_DECODE`, the text holds bytes a tolerance took, so its decode may be longer
// than its span, as `text_room` says.
SPELLING_LAX :: u16(4)
// In a quoted text's spelling, its bytes are all below 0x80 and hold no escape. A walk sets it on every such text it
// reads, but a text made otherwise may lack it, so its absence proves nothing.
SPELLING_ASCII :: u16(16)
// A text's decoded length is its `n` less its escape credit, the source bytes its escapes save. Only a hook with
// `.Credits` is given a credit, and a document stores none. A text whose credit does not fit, or that the walk did not
// account, has neither credit bit, which proves nothing about its length. A number uses the same bits for its digit
// counts, kind and form, so a reader checks the token's kind first.
SPELLING_CREDIT_EXACT :: u16(1 << 5)
SPELLING_CREDIT :: u16(0x1F << 6) // a credit of at most 31

// Whether the text of scalar `t` is not its bytes in the text, so that `Format.decode` or `Format.same_text` reads it.
// A number's spelling holds its number kind in the bit a text's holds this in, so a number reads as its bytes, except
// a key, which a format spells through `same_text` whatever its number kind.
text_decodes :: #force_inline proc "contextless" (t: Token) -> bool {
	return t.spelling & SPELLING_DECODE != 0 if t.kind != .Number else t.role == .Key
}

// The spelling of a text whose escapes save `credit` bytes. It is 0 for no credit and `SPELLING_DECODE` alone for one
// that does not fit.
credit_spelling :: #force_inline proc "contextless" (credit: u32) -> u16 {
	if credit == 0 do return 0
	if credit > u32(SPELLING_CREDIT >> 6) do return SPELLING_DECODE
	return SPELLING_DECODE | SPELLING_CREDIT_EXACT | u16(credit << 6)
}

// The spelling of a text with its credit left out, for a hook that stores a token a walk gave it a credit with.
without_credit :: #force_inline proc "contextless" (spelling: u16) -> u16 {
	return spelling &~ (SPELLING_CREDIT_EXACT | SPELLING_CREDIT)
}

// The escape credit in a text's spelling. A reader checks `SPELLING_CREDIT_EXACT` first.
spelling_credit :: #force_inline proc "contextless" (spelling: u16) -> u32 {
	return u32((spelling & SPELLING_CREDIT) >> 6)
}

// A rule of a format a read may let a text break, each with one fixed reading. A rule a format has no instance of is
// never broken there, so the same set applies to every format.
Tolerance :: enum u8 {
	// Ill-formed UTF-8 in a string or key. Each maximal subpart of an ill-formed sequence reads as U+FFFD.
	Invalid_Utf8,
	// `NaN`, `Infinity` and either with a sign, in a format whose numbers have no such words, read as those IEEE values.
	Non_Finite,
	// A `\u` escape of a surrogate half that no other half pairs with. It reads as U+FFFD.
	Lone_Surrogate,
	// A record of a table with more or fewer cells than the first. Its cells past the header's are named by their
	// 1-based column, and the cells it lacks are absent.
	Ragged,
	// A quote inside a cell that no quote opens, in a format that quotes whole cells. It reads as the byte it is.
	Bare_Quote,
	// A markup reference to an entity whose text was not read: an external entity, or an undeclared one in a text whose
	// declarations were not read whole. It reads as its own text, `&name;`.
	Unread_Entity,
}

Tolerances :: bit_set[Tolerance; u8]

NUMBER_KIND :: u16(0xF) // in a number's spelling, the format's number kind, 0 for its plain decimal
NUMBER_EXP :: u16(1 << 14) // in a number's spelling, the number has an exponent
NUMBER_POINT :: u16(1 << 15) // in a number's spelling, a point with no digit after it (`5.`), which makes a float

// The spelling of a number token. Bits 0 to 3 hold the format's number kind (0 for its plain decimal), bits 4 to 8 the
// integer digits and bits 9 to 13 the fraction digits, each count saturated at 31.
number_spelling :: #force_inline proc "contextless" (kind: u16, int_digits, frac_digits: u64) -> u16 {
	return kind | u16(min(int_digits, 31)) << 4 | u16(min(frac_digits, 31)) << 9
}

// The integer and fraction digit counts in a number token's spelling, each saturated at 31.
number_digits :: #force_inline proc "contextless" (spelling: u16) -> (int_digits, frac_digits: int) {
	return int(spelling >> 4 & 31), int(spelling >> 9 & 31)
}

// The end and spelling of the RFC 8259 number at `p`, where `p < end` and `p[0]` is `-` or a digit, or the fault and
// the byte it is at. A number ends at the first byte that cannot continue it, which the caller judges. The spelling is
// 0 unless `SPELLED`. With `HEX_REFUSED` an `x` after a leading zero is a fault, for a grammar whose hex numbers
// another reader takes.
number_scan :: #force_inline proc "contextless" (p, end: [^]u8, $SPELLED, $HEX_REFUSED: bool) -> (q: [^]u8, spelling: u64, kind: Fault_Kind) #no_bounds_check {
	q = p
	if q[0] == '-' {
		q = q[1:]
		if q >= end {
			return end, 0, .Truncated
		}
	}
	int_at := q
	if q[0] == '0' {
		q = q[1:]
		if q < end && (q[0] - '0' < 10 || HEX_REFUSED && q[0] | 0x20 == 'x') {
			return q, 0, .Bad_Number
		}
	} else {
		r := spell.digit_end(q, end)
		if r == q {
			return q, 0, .Bad_Number
		}
		q = r
	}
	int_digits := u64(intrinsics.ptr_sub(q, int_at))
	if q >= end {
		return q, u64(digit_spelling(int_digits, 0, SPELLED)), .None
	}
	frac_digits: u64
	c := q[0]
	if c == '.' {
		r := spell.digit_end(q[1:], end)
		if r == q[1:] {
			q, kind = number_fault(r, end)
			return q, 0, kind
		}
		frac_digits = u64(intrinsics.ptr_sub(r, q[1:]))
		q = r
		if q >= end {
			return q, u64(digit_spelling(int_digits, frac_digits, SPELLED)), .None
		}
		c = q[0]
	}
	if c | 0x20 == 'e' {
		q = q[1:]
		if q < end && (q[0] == '+' || q[0] == '-') {
			q = q[1:]
		}
		r := spell.digit_end(q, end)
		if r == q {
			q, kind = number_fault(r, end)
			return q, 0, kind
		}
		return r, u64(digit_spelling(int_digits, frac_digits, SPELLED) | (NUMBER_EXP when SPELLED else 0)), .None
	}
	return q, u64(digit_spelling(int_digits, frac_digits, SPELLED)), .None
}

// The spelling of the number `src[lo:hi]`, which a walk read as an RFC 8259 number.
number_respell :: proc "contextless" (src: []u8, lo, hi: u64) -> u16 {
	_, spelling, _ := number_scan(raw_data(src)[lo:], raw_data(src)[hi:], true, false)
	return u16(spelling)
}

// The token of the text of `n` bytes at `lo` of `base`, which needs no decode, as a format's option to infer its kind
// reads an untyped text, a delimited cell or a markup element's text: `true` and `false` are those kinds, an RFC 8259
// number is a `Number` with its digit counts as JSON's walk spells them, and any other text is a `String`. The first
// byte selects the check, so a text needs one load.
infer_token :: #force_inline proc "contextless" (base: [^]u8, lo: u64, n: u32) -> Token {
	t := Token{lo, n, .String, .Value, 0}
	switch base[lo] {
	case 't':
		if n == 4 && string(base[lo:][:4]) == "true" {
			t.kind = .True
		}
	case 'f':
		if n == 5 && string(base[lo:][:5]) == "false" {
			t.kind = .False
		}
	case '-', '0' ..= '9':
		end := base[lo + u64(n):]
		if q, spelling, kind := number_scan(base[lo:], end, true, false); kind == .None && q == end {
			t.kind, t.spelling = .Number, u16(spelling)
		}
	}
	return t
}

// The fault of a number whose fraction or exponent has no digit at `q`: `Truncated` at `end` when the text ends there.
number_fault :: #force_inline proc "contextless" (q, end: [^]u8) -> ([^]u8, Fault_Kind) {
	if q >= end {
		return end, .Truncated
	}
	return q, .Bad_Number
}

// A plain decimal's spelling, 0 unless `SPELLED`.
@(private)
digit_spelling :: #force_inline proc "contextless" (int_digits, frac_digits: u64, $SPELLED: bool) -> u16 {
	when SPELLED {
		return number_spelling(0, int_digits, frac_digits)
	} else {
		return 0
	}
}
