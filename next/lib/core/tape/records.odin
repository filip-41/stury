package tape

import "base:runtime"

// A text that holds a list of records, which a format's records read hands on one at a time, each as it closes.

// How a text holds its records.
Framing :: enum u8 {
	// One value per line (NDJSON). A line of white space alone holds no record. A record whose line holds more than one
	// value, or a value that runs on past its line, is refused, and the records go on at the next line.
	Lines,
	// RFC 7464 JSON text sequences: each record is led by ASCII RS (0x1E). Empty or white-space-only RS spans hold no
	// record. Bytes before the first RS are refused as unframed, and a top-level number with no white space after it is
	// refused as potentially truncated. A fault in one record leaves the records going on at the next RS.
	Seq,
	// The elements of the root array, or of the array `Records.path` reaches. A fault ends the records, as the text
	// holds no list past it, and a value of another kind ends them with `Bad_Option{"framing"}`.
	Elements,
	// The members of the root object, or of the object `Records.path` reaches. Each member's value is a record, with its
	// key in `Record.key`. Every member is a record, repeated keys too. A fault ends the records, and a value of another
	// kind ends them with `Bad_Option{"framing"}`, as under `.Elements`.
	Members,
	// Values one after another with nothing between them, as a CBOR sequence (RFC 8742) or concatenated JSON texts. A
	// fault ends the records, as the text holds no place where the next value starts, unless `records_skip` skips past
	// it where the framing allows.
	Concatenated,
}

// One record: its bytes in the text, and why it does not read, nil when it does. Its bytes run from its first byte
// that is no white space to its line's end less a CR under `.Lines`, to the next 0x1E or text end under `.Seq`, and to
// its value's end under the other framings. Every offset, those of `err` included, counts from the text's first byte.
// Under `.Members` `key` is the member's key, a token of role `.Key` that `key_raw` reads, and under the other framings
// it is the zero token, whose role is `.Value`.
Record :: struct {
	lo, hi: u64,
	err:    Error,
	key:    Token,
}

// A record that did not read, returned by `records_skip` or collected into `Records.quarantine`. `text` is its bytes
// in the current window (`r.src[lo:hi]`), and `lo`, `hi` are its whole-text offsets.
Bad_Record :: struct {
	lo, hi: u64,
	err:    Error,
	text:   []u8,
}

// The records layer's `Rules` (detail 1 = `too_long`).
@(rodata)
RECORDS_RULES := Rules{"records", {
	{},
	{"too_long", "Record is longer than the limit"},
}}

// The `Too_Wide` fault for a record or unread streaming window exceeding `Records.max_bytes`, placed at `at`.
record_too_long :: #force_inline proc "contextless" (at: u64) -> Fault {
	return {at = at, rules = &RECORDS_RULES, kind = .Too_Wide, detail = 1}
}

// Where the records of a text are, in their framing.
Records_At :: enum u8 {
	Start, // before the first record, or before the container holding them
	Open, // in the container holding them, before the first
	After, // in the container holding them, after a record
	Done,
}

// The state of a read of the records of a text that every format keeps: what is read, and how far. A format's records
// hold it as their first field, with what their walk learns from record to record after it. Each batch reads the next
// records into slices the caller gives, as many as they hold, but a validate, which keeps there only the records that
// do not read and counts every record in `index`. Once a batch fills fewer than it was given room for the records have
// ended, and `err` says why, nil at the text's end.
//
// The records of a text in pieces are read a window at a time, under the framings a format's records read so:
// `Options.pieces` is the read's, the window the records open with is the text's first, and `records_window` gives each
// next window. A batch reads the records the window holds whole and fills fewer than it was given room for once the
// window holds no more, or once the records have ended. It then sets the pieces' `more`, `at` and `keep`, as a read of
// a window does: a record the window's end cut is kept from its first byte, and its framing goes on in the next window
// where this one stopped. Each record's offsets are the whole text's, a scan's documents hold the bytes they read
// (`.Held`), and a find's answers are spans of the window it was read in.
Records :: struct {
	src:      []u8,
	opts:     Options,
	framing:  Framing,
	at:       Records_At,
	// When true, batch reads automatically skip past faulting records where the framing supports `records_skip` (such
	// as JSON `.Concatenated`), reporting them in `out` (and in `quarantine` when set) and continuing.
	skip_bad: bool,
	// Under `.Elements` and `.Members`, the steps from the root to the container whose elements or members are the
	// records, which it borrows, empty for the root. Each is a `Name` or an `Index` from the start. A `Name` takes the
	// members of its key as `Options.dups` says, and the policies a path read refuses are refused. Under `.First` it
	// takes the first, and under `.Group` each in document order, whose records follow one another. Under `.Last` it
	// takes each in turn, as the records are given before the object holding them closes: a member met once a record
	// was given ends the records with `.Duplicate_Key` at its key, and none given is taken back. A text the path reaches
	// no value in holds no records.
	path:       []Step,
	err:        Error,
	pos:        u64, // where the next record is looked for
	index:      u64, // the records read
	key:        Token, // the key of the member being read under `.Members`
	block:      Record_Block, // what the documents of the last batch of a scan are in
	// Maximum bytes a single record (or unread streaming window past the last whole record) may span; 0 for no limit.
	// Exceeding it ends the records with `record_too_long` (`Fault_Kind.Too_Wide`, code `records.too_long`).
	max_bytes:  u64,
	// Optional bad-record sink: when non-nil, `records_find` and `records_scan` route faulting records here instead of
	// emitting them into `out`/`answers`/`docs` (so every returned entry is valid), and `records_validate` mirrors its
	// faulting records here too.
	quarantine: ^[dynamic]Bad_Record,
	// Set by a format whose framing supports skipping past a faulting record (`records_skip`).
	skip:       proc(r: ^Records) -> (Bad_Record, bool),
	// Set by a format whose records hold memory past a batch, which frees it.
	release:    proc(r: ^Records),
	// Set by `Reads.records` for records it made, which `destroy_records` frees from `allocator`: their reads.
	reads:      ^Records_Reads,
	allocator:  runtime.Allocator,
}

// The batch reads of the records of one spec of a format, as its own records reads read them.
@(private)
Records_Reads :: struct {
	validate: proc(r: ^Records, out: []Record, allocator: runtime.Allocator) -> int,
	find:     proc(r: ^Records, path: []Step, out: []Record, answers: []Span_Answer, read: Read_Options, allocator: runtime.Allocator) -> int,
	scan:     proc(r: ^Records, demand: ^Demand, out: []Record, docs: []Document, read: Read_Options, allocator: runtime.Allocator) -> int,
}

// Reads the next records of `r`, which `Reads.records` made, judging each as `Reads.validate` judges its bytes alone,
// and keeps in `out` those that do not read. Returns how many it filled.
records_validate :: proc(r: ^Records, out: []Record, allocator := context.allocator) -> int {
	return 0 if r == nil || r.reads == nil else r.reads.validate(r, out, allocator)
}

// Reads the next records of `r`, which `Reads.records` made, into `out`, and for each the first value `path` reaches
// in it into the same place of `answers`, or `.Missing` with no span for a record a fault refuses. Returns how many it
// filled.
records_find :: proc(r: ^Records, path: []Step, out: []Record, answers: []Span_Answer, read := Read_Options{}, allocator := context.allocator) -> int {
	return 0 if r == nil || r.reads == nil else r.reads.find(r, path, out, answers, read, allocator)
}

// Reads the next records of `r`, which `Reads.records` made, into `out`, and for each the document of its nodes the
// paths of `demand` reach into the same place of `docs`, an empty document for a record a fault refuses, whose every
// path answers `.Missing` with no node. Returns how many it filled. The documents are valid until the next call or
// `destroy_records`, as `Record_Block` says.
records_scan :: proc(r: ^Records, demand: ^Demand, out: []Record, docs: []Document, read := Read_Options{}, allocator := context.allocator) -> int {
	return 0 if r == nil || r.reads == nil else r.reads.scan(r, demand, out, docs, read, allocator)
}

// Skips past the faulting record that ended `r` so the next batch call resumes at the following record, returning the
// skipped record and true. Returns false (leaving `r.err` untouched) when `r` did not end on a skippable fault or its
// format/framing has no recovery boundary (such as `.Elements`/`.Members`, CBOR, TOML, XML, or `Too_Wide`).
records_skip :: proc(r: ^Records) -> (bad: Bad_Record, ok: bool) {
	if r == nil || r.skip == nil {
		return
	}
	return r.skip(r)
}

// Gives the records `r` of a text in pieces the window `src`, which starts at the pieces' `from`, at or before their
// `keep`, and ends at or after their `at`, else the window is refused with `Piece_Gap`.
records_window :: proc "contextless" (r: ^Records, src: []u8) -> Error {
	if r == nil || r.opts.pieces == nil {
		return Bad_Option{"pieces"}
	}
	p := r.opts.pieces
	piece_window(p, src) or_return
	r.src = piece_src(src, p.from)
	return nil
}

// Frees what the records `r` hold, the documents of their last batch of a scan with them, and the records themselves
// when `Reads.records` made them. A format's records opened directly are freed so too.
destroy_records :: proc(r: ^Records) {
	if r == nil {
		return
	}
	record_block_free(&r.block)
	if rel := r.release; rel != nil {
		r.release = nil
		rel(r)
	}
	if r.reads != nil {
		free(r, r.allocator)
	}
}

// Shared bump-block state embedded by `Record_Block` and per-worker typed result blocks (`typed.Worker_Block`).
Bump_Block :: struct {
	chunk: []u8,
	used:  int,
	last:  int, // where the last allocation starts, which grows in place (-1 for none)
}

// The memory the documents of a batch of a scan of records are in, which the next batch reuses: a document a batch
// gives is valid until the next batch or `destroy_records`, its free does nothing, and a caller that keeps it clones
// it. Its chunks come from the allocator the first batch was given. A batch that outgrew the chunk sizes the next
// batch's first chunk to what it used, allocated lazily on first take.
Record_Block :: struct {
	using bump: Bump_Block,
	spent:      int, // the bytes of the chunks outgrown in this batch, which `outgrown` holds
	want:       int, // deferred single-chunk size for the next batch after outgrowing
	outgrown:   [dynamic][]u8,
	backing:    runtime.Allocator,
}

// Frees the chunks of `b` and leaves it zero.
@(private = "file")
record_block_free :: proc(b: ^Record_Block) {
	if b.backing.procedure == nil {
		return
	}
	for c in b.outgrown {
		runtime.mem_free_with_size(raw_data(c), len(c), b.backing)
	}
	delete(b.outgrown)
	if b.chunk != nil {
		runtime.mem_free_with_size(raw_data(b.chunk), len(b.chunk), b.backing)
	}
	b^ = {}
}

// The allocator of the documents of the next batch of `b`, whose last batch's documents it frees. `caller` gives the
// chunks when `b` has none.
record_block_batch :: proc(b: ^Record_Block, caller: runtime.Allocator) -> runtime.Allocator {
	if b.backing.procedure == nil {
		b.backing = caller
		b.outgrown.allocator = caller
	}
	if len(b.outgrown) > 0 {
		want := b.spent + b.used
		if want < 0 {
			want = max(int)
		}
		for c in b.outgrown {
			runtime.mem_free_with_size(raw_data(c), len(c), b.backing)
		}
		clear(&b.outgrown)
		if b.chunk != nil {
			runtime.mem_free_with_size(raw_data(b.chunk), len(b.chunk), b.backing)
		}
		b.chunk, b.spent, b.want = nil, 0, want
	}
	b.used, b.last = 0, -1
	return bump_allocator(b, record_block_grow)
}

@(private = "file")
RECORD_CHUNK :: 64 * 1024

// Returns a bump `runtime.Allocator` for `b` (embedding `Bump_Block`), refilling via cold `$grow`.
bump_allocator :: proc "contextless" (b: ^$B, $grow: proc(b: ^B, size, align: int) -> ([]u8, runtime.Allocator_Error)) -> runtime.Allocator {
	p :: proc(data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]u8, runtime.Allocator_Error) {
		b := (^B)(data)
		#partial switch mode {
		case .Alloc, .Alloc_Non_Zeroed:
			out, err := bump_take(b, size, alignment, grow)
			if err == nil && mode == .Alloc && size > 0 {
				runtime.mem_zero(raw_data(out), size)
			}
			return out, err
		case .Resize, .Resize_Non_Zeroed:
			if old_memory == nil {
				out, err := bump_take(b, size, alignment, grow)
				if err == nil && mode == .Resize && size > 0 {
					runtime.mem_zero(raw_data(out), size)
				}
				return out, err
			}
			if size <= 0 {
				return nil, nil
			}
			align := max(alignment, 1)
			old_p, buf_p := uintptr(old_memory), uintptr(raw_data(b.chunk))
			if b.chunk != nil && old_p >= buf_p && old_p - buf_p <= uintptr(len(b.chunk)) {
				at := int(old_p - buf_p)
				if at == b.last && (old_p & uintptr(align - 1)) == 0 && size <= len(b.chunk) - at {
					// The last allocation grows or shrinks where it is.
					b.used = at + size
					#no_bounds_check if mode == .Resize && size > old_size {
						z := max(old_size, 0)
						runtime.mem_zero(&b.chunk[at + z], size - z)
					}
					#no_bounds_check return b.chunk[at:at + size], nil
				}
			}
			if size <= old_size && (old_p & uintptr(align - 1)) == 0 {
				#no_bounds_check return ([^]u8)(old_memory)[:size], nil
			}
			out, err := bump_take(b, size, alignment, grow)
			if err != nil {
				return nil, err
			}
			n := min(max(old_size, 0), size)
			if n > 0 {
				runtime.mem_copy_non_overlapping(raw_data(out), old_memory, n)
			}
			#no_bounds_check if mode == .Resize && size > n {
				runtime.mem_zero(&out[n], size - n)
			}
			return out, nil
		case .Free, .Free_All:
			return nil, nil
		case .Query_Features:
			if set := (^runtime.Allocator_Mode_Set)(old_memory); set != nil {
				set^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free, .Free_All, .Query_Features}
			}
			return nil, nil
		}
		return nil, .Mode_Not_Implemented
	}
	return {p, b}
}

// Takes `size` bytes aligned to power-of-two `alignment` from `b`, refilling via `$grow` when full.
bump_take :: #force_inline proc(b: ^$B, size, alignment: int, $grow: proc(b: ^B, size, align: int) -> ([]u8, runtime.Allocator_Error)) -> ([]u8, runtime.Allocator_Error) {
	if size <= 0 {
		return nil, nil
	}
	align := max(alignment, 1)
	if b.chunk != nil {
		base := uintptr(raw_data(b.chunk))
		u_at := ((base + uintptr(b.used) + uintptr(align - 1)) &~ uintptr(align - 1)) - base
		u_len := uintptr(len(b.chunk))
		if u_at <= u_len && uintptr(size) <= u_len - u_at {
			at := int(u_at)
			b.last, b.used = at, at + size
			// Guarded by `size > 0`, `u_at <= len(b.chunk)`, and `size <= len(b.chunk) - at`.
			#no_bounds_check return b.chunk[at:at + size], nil
		}
	}
	return grow(b, size, align)
}

// Takes `size` bytes aligned to power-of-two `alignment` from the chunk of `b`, starting a larger chunk when it has no room.
record_block_take :: #force_inline proc(b: ^Record_Block, size, alignment: int) -> ([]u8, runtime.Allocator_Error) {
	return bump_take(b, size, alignment, record_block_grow)
}

// Allocates a larger chunk for `b`, stashing the previous chunk in `outgrown` until the next batch.
@(private = "file", cold)
record_block_grow :: proc(b: ^Record_Block, size, align: int) -> ([]u8, runtime.Allocator_Error) {
	doubled := max(int) if len(b.chunk) > max(int) / 2 else 2 * len(b.chunk)
	grown := max(doubled, b.want, RECORD_CHUNK, size)
	data, err := runtime.mem_alloc_non_zeroed(grown, max(align, 64), b.backing)
	if err != nil || len(data) < size {
		if data != nil {
			runtime.mem_free_with_size(raw_data(data), len(data), b.backing)
		}
		return nil, err if err != nil else .Out_Of_Memory
	}
	if b.chunk != nil {
		if _, err = append(&b.outgrown, b.chunk); err != nil {
			runtime.mem_free_with_size(raw_data(data), len(data), b.backing)
			return nil, err
		}
		b.spent += b.used
	}
	b.chunk, b.last, b.used, b.want = data, 0, size, 0
	// Guarded by `0 < size <= len(data)` checked above.
	#no_bounds_check return b.chunk[:size], nil
}

// A text that arrives in pieces is read one piece at a time through `Options.pieces`: each read takes a window of the
// text, stops at the end of the bytes it has and leaves in its `Pieces` what the next read continues from. Offsets stay
// those of the whole text.

// The state of a read of a text in pieces, which the caller holds from the first piece to the last and frees with
// `destroy`. The caller sets `from` and `last` before each read, and the read sets the rest. It holds no pointer into a
// piece of text.
Pieces :: struct {
	// The offset in the whole text of the window's first byte, at most `keep`. The window reaches at least `at`.
	from:      u64,
	last:      bool, // the window ends the text
	// With `build` and `scan`, each read that stops at the end of its window gives the document of the value or the
	// answers so far, its open containers closed at the cut. Without it such a read gives an empty document.
	so_far:    bool,
	// Set by the read: the text ended inside its root value, or before the read could judge that it had ended, so the
	// next piece continues from here. False once a read of the last piece, or a stop, ended the read.
	more:      bool,
	at:        u64, // one past the bytes read, where the next window's new bytes start
	keep:      u64, // the lowest offset the next read needs, before which the caller may drop the text
	// The path from the root to the value the text ended inside: the key or index of each open container, then the
	// key whose value was being read. Its names are the read's, valid until its next read.
	open:      []Step,
	// With `find`, the bytes of the answer, copied out of the window it closed in, as the answer gives offsets only.
	text:      []u8,
	allocator: runtime.Allocator, // what the read holds between pieces is in, the context's when unset
	// The state the read carries from one piece to the next, which only the format's reads touch, in a block of its
	// own from the first read to `destroy`, which frees it through `release`.
	state:     rawptr,
	release:   proc(p: ^Pieces),
}

// Frees what a read of a text in pieces holds and leaves it zero.
@(private)
destroy_pieces :: proc(p: ^Pieces) {
	if p == nil {
		return
	}
	if p.state != nil {
		p.release(p)
	}
	delete(p.text, p.allocator)
	p^ = {}
}

// The error of a read whose window does not hold the bytes the read needs: it starts past `keep`, or ends before `at`.
Piece_Gap :: struct {
	keep, at: u64, // what the window had to hold
	from, to: u64, // what it held
}

// The offset past the window `src` of the text in pieces `p`, or `Piece_Gap` when the window starts past what the last
// read keeps, or ends before where it read to.
piece_window :: #force_inline proc "contextless" (p: ^Pieces, src: []u8) -> (to: u64, err: Error) {
	if p.from > u64(max(int)) || u64(len(src)) > u64(max(int)) - p.from {
		return 0, Exceeded{at = p.from, kind = .Memory}
	}
	to = p.from + u64(len(src))
	if p.from > p.keep || to < p.at {
		return to, Piece_Gap{p.keep, p.at, p.from, to}
	}
	return to, nil
}

// The bytes of the window of `src` taken at offset `from`, as a slice that its tokens' offsets in the whole text index.
// Its bytes before `from` are not to be read: a read starts at or past `keep`, which no window starts past, and a
// hook reads only tokens of that read or bytes its `keep` holds. Its base, the window's address less `from`, is
// computed in integers and only added to, with no bounds, so it may wrap below zero with no effect on an index past it.
@(require_results)
piece_src :: #force_inline proc "contextless" (src: []u8, from: u64) -> []u8 {
	return ([^]u8)(uintptr(raw_data(src)) - uintptr(from))[:from + u64(len(src))]
}
