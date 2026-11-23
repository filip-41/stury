package tape

import "base:runtime"
import "stury:lib/base/spell"

// A format is a text format stury reads, with a `Format` per spec. Its facts say which fact kinds it holds beyond
// plain values, its caps what else it can do, and its readers turn a node into an Odin value.

// A format capability other than a fact it holds.
Cap :: enum u8 {
	// A value of its text walks alone from its first byte, as it walks inside the text, so a read can pass an element
	// and walk it again once its array's count picks it. A format without it, whose values read by what came before
	// them (a YAML block value, an HTML element in its insertion mode, a TOML table's body), keeps the nodes instead.
	Rewalk,
}

Caps :: bit_set[Cap; u32]

// The stable id of one spec of a format, stored in saved documents. Unique across the linked formats.
Format_Id :: distinct u16

// Options of a read of any format.
Options :: struct {
	budget:   Budget,
	// The policy for the members of an object that repeat a key, which every read honours or refuses. A build keeps one
	// member of each key under `.First` and `.Last`, fails on a repeat under `.Refuse`, and keeps every member under
	// the others. A path read takes the member `.First`, `.Last` or `.Group` says, the format's own for `.Default`, and
	// refuses `.All` and `.Refuse`, as it takes one member of a key. Under `.Last` an answer through a key is known only
	// at the close of the object holding it, so a path read that should stop at the first matching key uses `.First`.
	// A validate refuses `.Refuse`, as it does not compare keys.
	dups:     Duplicates,
	// The rules a text may break, each read as `Tolerance` says. A spec whose grammar holds a rule has it already.
	tolerate: Tolerances,
	// A text that arrives in pieces, of which the read takes the next window, nil for a whole text.
	pieces:   ^Pieces,
	// Threads a build of a whole text may run on beside the caller's, nil for the caller's alone. The document is the
	// one a build on one thread gives, and so is its error.
	runner:   ^Runner,
}

// A spec of a format (e.g. JSON, JSONC and JSON5 are three), in rodata, holding what a document of it needs to be
// read. `Reads` holds the reads of its texts.
Format :: struct {
	name:  string,
	id:    Format_Id,
	facts:  Facts, // the fact kinds it holds
	caps:   Caps,
	dups:   Duplicates, // its own policy for repeated keys, which `.Default` takes, never `.Default`
	// The bytes of a scalar token's authored span before and after the token's own, as a string's quotes.
	bounds: proc "contextless" (src: []u8, t: Token) -> (head, tail: u8),
	// The text of a scalar node whose spelling has `SPELLING_DECODE`, decoded into `buf`, false only when `buf` is
	// shorter than `room` gives. A scalar with no `SPELLING_DECODE` reads as its bytes in the text.
	decode: proc "contextless" (src: []u8, t: Node, buf: []u8) -> (s: string, ok: bool),
	// The bytes that always hold the decode of scalar `t`, which may pass its span (a CBOR integer key's digits, an
	// entity, a tolerated byte read as U+FFFD).
	room: proc "contextless" (src: []u8, t: Node) -> int,
	// The value of a number node.
	number: proc "contextless" (src: []u8, t: Node) -> spell.Number,
	// Whether scalar `t` of `src` and scalar `o` of `other` read as the same text, whatever their kinds.
	same_text: proc "contextless" (src: []u8, t: Token, other: []u8, o: Token) -> bool,
	// A hash of the text scalar `t` of `src` reads as, `text_hash` of that text, so two scalars `same_text` holds for
	// hash alike. A scalar with no `SPELLING_DECODE` hashes as its bytes in the text.
	key_hash: proc "contextless" (src: []u8, t: Token) -> u32,
	// The byte just past the close of the container node `at` of `doc`, which a document stores no node for. False for
	// one other than the root of a `.Held` document, which holds no byte between its nodes.
	close_end: proc "contextless" (doc: ^Document, at: Node_Index) -> (end: u64, ok: bool),
}

// The reads of one spec of a format, for a caller that picks the format at run time. They are not on `Format`: the
// handle holds what reading a document needs, so a program that reads no text through it links no read of any spec.
Reads :: struct {
	validate: proc(f: ^Format, src: []u8, opts: Options, allocator: runtime.Allocator) -> Error,
	build: proc(f: ^Format, src: []u8, opts: Options, allocator: runtime.Allocator) -> (Document, Error),
	find: proc(f: ^Format, src: []u8, path: []Step, read: Read_Options, opts: Options, allocator: runtime.Allocator) -> (Span_Answer, Error),
	scan: proc(f: ^Format, src: []u8, demand: ^Demand, read: Read_Options, opts: Options, allocator: runtime.Allocator) -> (Document, Error),
	// Makes the records of `src` framed as `framing`, in `allocator`, which `destroy_records` frees.
	records: proc(f: ^Format, src: []u8, framing: Framing, opts: Options, allocator: runtime.Allocator) -> (^Records, runtime.Allocator_Error),
}
