package json

import "core:bytes"
import scan_pkg "scan"
import index_pkg "scan/index"

// How an input is cut into records (`Record_Opts.framing`). The iterator checks the framing only: whatever the
// caller runs on a record's bytes (`validate`, `build`, `unmarshal`, `scan`) checks the record.
//
//	.None          the input is one record from its first byte that is not whitespace, unless it is whitespace
//	               only.
//	.NDJSON        a line of JSON whitespace only (spaces, tabs, CRs), or none, is
//	               not a record. A record includes its line's leading spaces and excludes the line break and a
//	               CR before it.
//	.JSON_Seq      RFC 7464: one or more `0x1E`, then a record: from the first byte that is neither `0x1E`
//	               nor whitespace up to the next `0x1E` or the input's end, the line feed that ends a JSON
//	               text included. Separators with only whitespace after them are no record, as the CLI's
//	               --seq reads them, and jq's. A number with no whitespace after it may be cut short (RFC 7464
//	               §2.4), and is `.Truncated` with `Fault.Cut_Number` on `err`, at its end. Whitespace before the
//	               first `0x1E` is stepped over. Any other byte there is `.Bad_Char` on `err`.
//	.Root_Entries  each element of the root array, or each member of the root object (`key` is its key as
//	               written, quotes included, and the key and colon are checked here), cut at the root's commas
//	               outside strings and brackets. An empty entry between commas is yielded for the caller's check to
//	               refuse. A scalar root has no entries: it is checked whole, and its fault is `err`. The root
//	               holds each entry, so a check that must refuse what `validate` refuses of the whole takes
//	               one level off `max_depth`.
//	.Concatenated  jq's input: texts one after another, with whitespace between them or none. An array or object
//	               runs to the bracket that closes it outside strings, a string to its closing quote, and anything
//	               else (a number, a literal, a stray byte) to the first whitespace, quote or bracket, with a `]`,
//	               `}`, `,` or `:` right after it, which a read then refuses. So adjacent numbers or literals need
//	               whitespace between them, and `[1]2` is two texts. A text that never closes runs to the input's
//	               end. Ends are found from strings and brackets alone: a malformed text is cut where they say,
//	               and its read refuses it.
//
// A UTF-8 BOM is the input's, not a record's: one at the input's first byte is stepped over, and a record
// that starts with one past it is `.Bad_Char` on `err`, since `validate` on the record alone would step over
// it.
Framing :: enum u8 {
	None,
	NDJSON,
	JSON_Seq,
	Root_Entries,
	Concatenated,
}

// How a read of records takes its input: each record read under `read`, the input cut under `framing`.
//
// `max_record_bytes` caps what one record may hold, 0 for no cap: past it the iterator's `err` is `.Limit_Format`
// with `Fault.Record_Too_Long`, at the first byte of what it caps. Under `.NDJSON` that is a line, a blank one
// included, with its bytes before the line feed; under the other framings a record, an entry with its key. It also
// bounds the window a `Record_Reader` holds under `.NDJSON`, `.JSON_Seq` and `.Concatenated`.
Record_Opts :: struct {
	using read:       Read_Opts,
	framing:          Framing,
	max_record_bytes: int,
}

// One record: its JSON text, its member's key under `.Root_Entries` of an object (nil otherwise), and the
// offset of `bytes` from the input's first byte. The slices are the caller's source.
//
// What a read of `bytes` (`validate`, `scan`, `build`, `unmarshal`) reports is an offset into `bytes`, not into
// the input. To say where it is in the input, add `at`. To render an error with `render_error`, pass `bytes` and
// the offset as it is. The input also works, with `at` added to the offset.
Record :: struct {
	bytes: []byte,
	key:   []byte,
	at:    u64,
}

// A pull over an input's records (`next_record`). Its `state` is the iterator's own; `err` is the framing
// fault that ended it, as an offset from the input's first byte.
Records :: struct {
	using state: Records_State,
	err:         Maybe(Error),
}

@(private)
Records_State :: struct {
	// The bytes framed, a prefix of the input, and the next one to read.
	src:     []byte,
	pos:     int,
	framing: Framing,
	// `.Root_Entries`: whether the root is open, where its entries end (its close bracket, or a piece's last
	// comma), whether it is an object, and whether the next entry is yielded even when empty, which it is
	// where a comma precedes or follows it. `.Concatenated`: whether the text at `pos` is being read, and in
	// `commas` how far its end has been looked for.
	opened:  bool,
	end:     int,
	keyed:   bool,
	owed:    bool,
	commas:  index_pkg.Comma_Cursor,
	// `src` is a window of a stream with more to follow (`Record_Reader`). A `.Concatenated` text that `src`
	// ends before its end leaves the iterator `starved`, at the text's first byte, for a longer `src`.
	more:    bool,
	starved: bool,
	// `src` is a later window of its stream, whose first byte is not the stream's, where a byte order mark is
	// stepped over.
	resumed: bool,
	// `.Concatenated`: the text at `pos` was handed out open (`next_record_open`), for the caller's read to end
	// (`end_record`), or, `passed`, handed out and to be passed over where its brackets end it.
	awaiting: bool,
	passed:   bool,
	// `Record_Opts.max_record_bytes`, max(int) for none.
	cap:     int,
}

// The records of `src` under `opts.framing` and `opts.max_record_bytes`; no other field is read. Allocates
// nothing, and `destroy` empties it, as every format's records are released. A negative cap is `.Bad_Option` on
// `err`.
@(require_results)
records :: proc(src: []byte, opts := Record_Opts{}) -> Records {
	it := Records{src = src, framing = opts.framing, cap = record_cap(opts)}
	if opts.max_record_bytes < 0 {
		it.err = Error{kind = .Bad_Option}
	}
	return it
}

@(private)
record_cap :: #force_inline proc(opts: Record_Opts) -> int {
	return opts.max_record_bytes if opts.max_record_bytes > 0 else max(int)
}

@(private)
record_too_long :: proc(it: ^Records, at: int) {
	it.err = Error{kind = .Limit_Format, detail = u8(Fault.Record_Too_Long), offset = u64(at)}
}

@(private)
records_destroy :: proc(it: ^Records) {
	it^ = {}
}

// The next record, or false at the end or on a fault in `it.err`. From a `Record_Reader`, also false on a
// failure of its reader in `read_err`.
next_record :: proc {
	next_slice_record,
	next_reader_record,
}

// `next_record` for a caller that reads each record itself and lets its read end the text. Under `.Concatenated`
// an array, object or string is handed out open: `rec.bytes` runs from its first byte to the end of the bytes
// framed so far, and the read of it, which may stop before their end (`.Trailing`), goes to `end_record`. Any
// other text, and every record of the other framings, is the one `next_record` yields. Asked again with no
// `end_record`, the open text ends where its brackets say, as `next_record` ends it.
next_record_open :: proc {
	next_open_slice_record,
	next_open_reader_record,
}

// Ends the text `next_record_open` handed out open, where `read`, what the caller's read of `rec.bytes` reported,
// says: at its `.Trailing` offset, or at the end of `rec.bytes` when nil. The text is the record `next_record`
// yields for it, less the whitespace after it.
//
//	- `cut`: the read ran into the end of the bytes framed (`.Truncated` there) while more of the stream follows.
//	  The records then want the next window (`record_carry`), and the text is handed out again from its first byte.
//	- Any other fault is the text's: `rec.bytes` is what was handed out, and past it the records go on where the
//	  text's brackets end it, as `next_record` would. A caller that passes over a faulty text by rules of its own
//	  (`record_skip`) reads no more of the stream than its read did, though the text never closes.
//	- No text open: `rec` is empty and `cut` false.
end_record :: proc {
	end_slice_record,
	end_reader_record,
}

// The records go on from offset `to`, the caller having read up to it by other means (as `each_record`'s pieces
// over a window, or past a faulty text by rules of its own): the next record is read from `to`, even one handed
// out open there already, and a framing fault in `err` is passed over. A `to` before where the records stand reads
// them again from there, within a `Record_Reader`'s window (`record_window`).
record_skip :: proc {
	skip_slice_records,
	skip_reader_records,
}

@(private, require_results)
next_slice_record :: proc(it: ^Records) -> (rec: Record, ok: bool) {
	if it.err != nil {
		return
	}
	switch it.framing {
	case .None:
		rec, ok = next_text(it)
	case .NDJSON:
		rec, ok = next_ndjson(it)
	case .JSON_Seq:
		rec, ok = next_json_seq(it)
	case .Root_Entries:
		rec, ok = next_entry(it)
	case .Concatenated:
		rec, ok = next_concatenated(it)
	}
	if ok && (rec.at > 0 || it.resumed) && scan_pkg.bom_len(rec.bytes) > 0 {
		it.err = Error{kind = .Bad_Char, offset = rec.at}
		return {}, false
	}
	return
}

@(private, require_results)
next_open_slice_record :: proc(it: ^Records) -> (rec: Record, ok: bool) {
	if it.framing != .Concatenated || it.err != nil || it.opened || it.awaiting {
		return next_slice_record(it)
	}
	src := it.src
	if it.pos == 0 && !it.resumed {
		it.pos = scan_pkg.bom_len(src)
	}
	it.pos = scan_pkg.skip_space(src, it.pos)
	if it.pos == len(src) {
		it.starved = it.more
		return
	}
	lo := it.pos
	switch src[lo] {
	case '[', '{', '"':
		it.awaiting = true
		return {bytes = src[lo:], at = u64(lo)}, true
	case 0xEF: // a byte order mark, which `next_slice_record` refuses past the start
		return next_slice_record(it)
	}
	hi := scalar_end(src, lo)
	if hi < 0 || hi - lo > it.cap {
		return next_slice_record(it)
	}
	it.pos = hi
	return {bytes = src[lo:hi], at = u64(lo)}, true
}

@(private)
end_slice_record :: proc(it: ^Records, read: Maybe(Error)) -> (rec: Record, cut: bool) {
	if !it.awaiting {
		return
	}
	it.awaiting = false
	src, lo := it.src, it.pos
	hi := len(src)
	if e, bad := read.?; bad {
		if e.kind == .Truncated && int(e.offset) == hi - lo && it.more {
			it.starved = true
			return {}, true
		}
		if e.kind != .Trailing || int(e.offset) > hi - lo {
			await_brackets(it)
			return {bytes = src[lo:], at = u64(lo)}, false
		}
		hi = lo + int(e.offset)
	}
	it.pos = hi
	hi = scan_pkg.skip_space_back(src, lo, hi)
	if hi - lo > it.cap {
		record_too_long(it, lo)
		return
	}
	return {bytes = src[lo:hi], at = u64(lo)}, false
}

// The open text at `pos`, handed out already, is passed over to where its brackets end it, as `next_record` ends a
// text.
@(private = "file")
await_brackets :: proc(it: ^Records) {
	it.awaiting, it.opened, it.passed, it.commas = false, true, true, index_pkg.comma_cursor(it.pos)
}

@(private)
skip_slice_records :: proc(it: ^Records, to: u64) {
	it.pos = int(to)
	it.awaiting, it.opened, it.passed, it.starved = false, false, false, false
	it.err = nil
}

@(private)
next_text :: proc(it: ^Records) -> (rec: Record, ok: bool) {
	src := it.src
	if it.pos > 0 {
		return
	}
	it.pos = len(src)
	lo := scan_pkg.skip_space(src, scan_pkg.bom_len(src))
	if lo == len(src) {
		return
	}
	if len(src) - lo > it.cap {
		record_too_long(it, lo)
		return
	}
	return {bytes = src[lo:], at = u64(lo)}, true
}

@(private)
next_ndjson :: proc(it: ^Records) -> (rec: Record, ok: bool) {
	src := it.src
	if it.pos == 0 && !it.resumed {
		it.pos = scan_pkg.bom_len(src)
	}
	for it.pos < len(src) {
		start := it.pos
		end := len(src)
		if k := bytes.index_byte(src[start:], '\n'); k >= 0 {
			end = start + k
			it.pos = end + 1
		} else {
			it.pos = len(src)
		}
		if end - start > it.cap {
			record_too_long(it, start)
			return
		}
		if end > start && src[end - 1] == '\r' {
			end -= 1
		}
		if scan_pkg.skip_space(src[:end], start) < end {
			return {bytes = src[start:end], at = u64(start)}, true
		}
	}
	return
}

// `src` ends at the input's end or where a run of `0x1E` starts (`batch_boundary`), never inside one. A
// record starts past the whitespace after its separators, as the CLI's --seq filter reads it, so separators
// with only whitespace after them, before the next or the end, open none.
@(private)
next_json_seq :: proc(it: ^Records) -> (rec: Record, ok: bool) {
	src := it.src
	if it.pos == 0 && !it.resumed {
		it.pos = scan_pkg.bom_len(src)
	}
	it.pos = scan_pkg.skip_space(src, it.pos)
	if it.pos >= len(src) {
		return
	}
	if src[it.pos] != 0x1E {
		it.err = Error{kind = .Bad_Char, offset = u64(it.pos)}
		return
	}
	start := it.pos
	for start < len(src) {
		// A record's first byte is above a space. The separators and whitespace are not.
		c := src[start]
		if c != 0x1E && (c > ' ' || !scan_pkg.is_space(c)) {
			break
		}
		start += 1
	}
	it.pos = len(src)
	if start == len(src) {
		return
	}
	if k := bytes.index_byte(src[start:], 0x1E); k >= 0 {
		it.pos = start + k
	}
	if it.pos - start > it.cap {
		record_too_long(it, start)
		return
	}
	rec = {bytes = src[start:it.pos], at = u64(start)}
	if scan_pkg.seq_truncated_number(rec.bytes) {
		it.err = Error{kind = .Truncated, detail = u8(Fault.Cut_Number), offset = u64(it.pos)}
		return {}, false
	}
	return rec, true
}

@(private)
next_concatenated :: proc(it: ^Records) -> (rec: Record, ok: bool) {
	src := it.src
	if it.awaiting {
		await_brackets(it)
	}
	for {
		if !it.opened {
			if it.pos == 0 && !it.resumed {
				it.pos = scan_pkg.bom_len(src)
			}
			it.pos = scan_pkg.skip_space(src, it.pos)
			if it.pos == len(src) {
				it.starved = it.more
				return
			}
			it.opened = true
			it.commas = index_pkg.comma_cursor(it.pos)
		}
		lo := it.pos
		hi := text_end(it, lo)
		if hi < 0 {
			if it.more {
				it.starved = true
				return
			}
			hi = len(src)
		}
		it.opened = false
		it.pos = hi
		if hi - lo > it.cap {
			record_too_long(it, lo)
			return
		}
		if !it.passed {
			return {bytes = src[lo:hi], at = u64(lo)}, true
		}
		it.passed = false
	}
}

// Where the `.Concatenated` text at src[lo] ends, or -1 when `src` ends first. A container's search resumes at
// its cursor and a string's at `it.commas.at`, so over a longer `src` neither reads its bytes again.
@(private = "file")
text_end :: proc(it: ^Records, lo: int) -> int {
	src := it.src
	switch src[lo] {
	case '{', '[':
		close := index_pkg.next_top_close(&it.commas, src, !it.more)
		return close + 1 if close >= 0 else -1
	case '"':
		k := max(it.commas.at, lo + 1)
		for {
			i := bytes.index_byte(src[k:], '"')
			if i < 0 {
				it.commas.at = len(src)
				return -1
			}
			k += i
			// The opening quote at `lo` ends the run of backslashes.
			n := 0
			for src[k - 1 - n] == '\\' {
				n += 1
			}
			if n % 2 == 0 {
				return k + 1
			}
			k += 1
		}
	}
	return scalar_end(src, lo)
}

// Where the `.Concatenated` text at src[lo], no array, object or string, ends, or -1 when `src` ends first.
@(private = "file")
scalar_end :: #force_inline proc(src: []byte, lo: int) -> int {
	hi := lo + 1
	for hi < len(src) && !ends_scalar(src[hi]) {
		hi += 1
	}
	if hi == len(src) {
		return -1
	}
	switch src[hi] {
	case ']', '}', ',', ':':
		hi += 1
	}
	return hi
}

// Whether `c` ends a `.Concatenated` text that is no array, object or string: whitespace, a quote or a bracket.
@(private = "file")
ends_scalar :: #force_inline proc(c: byte) -> bool {
	switch c {
	case ' ', '\t', '\n', '\r', '"', '[', ',', ']', '{', ':', '}':
		return true
	}
	return false
}

@(private)
next_entry :: proc(it: ^Records) -> (rec: Record, ok: bool) {
	if !it.opened && !open_root(it) {
		return
	}
	src := it.src
	if it.pos > it.end {
		return
	}
	lo, hi := it.pos, it.end
	if c := index_pkg.next_top_comma(&it.commas, src[:it.end]); c >= 0 {
		hi = c
		it.owed = true
	}
	it.pos = hi + 1
	lo = scan_pkg.skip_space(src[:hi], lo)
	hi = scan_pkg.skip_space_back(src, lo, hi)
	if lo == hi && !it.owed {
		// The root is empty.
		return
	}
	if hi - lo > it.cap {
		entry_fault(it, lo, .Limit_Format, Fault.Record_Too_Long)
		return
	}
	key: []byte
	if it.keyed && lo < hi {
		key, lo = entry_key(it, lo, hi)
		if key == nil {
			return
		}
	}
	return {bytes = src[lo:hi], key = key, at = u64(lo)}, true
}

// The key of the member src[lo:hi] and where its value starts, or nil on a fault in `it.err`.
@(private)
entry_key :: proc(it: ^Records, lo, hi: int) -> (key: []byte, value: int) {
	src := it.src
	if src[lo] != '"' {
		entry_fault(it, lo, .Bad_Char)
		return
	}
	k := lo + 1
	for k < hi && src[k] != '"' {
		k += 1 + int(src[k] == '\\')
	}
	key = src[lo:min(k + 1, hi)]
	if e, bad := validate(key).?; bad {
		entry_fault(it, lo + int(e.offset), e.kind)
		return nil, 0
	}
	p := scan_pkg.skip_space(src[:hi], lo + len(key))
	if p == hi || src[p] != ':' {
		// Past the key there is only space before the entry's comma or the root's close.
		entry_fault(it, scan_pkg.skip_space(src[:it.end], p), .Bad_Char)
		return nil, 0
	}
	return key, scan_pkg.skip_space(src[:hi], p + 1)
}

@(private)
entry_fault :: proc(it: ^Records, p: int, kind: Error_Kind, detail := Fault.None) {
	it.err = Error{kind = kind, detail = u8(detail), offset = u64(p)}
	it.pos = it.end + 1
}

// Find the root: its open bracket, and its close as the last byte that is not space. A scalar root, or a
// container that does not end in its close, is checked whole, which yields no entry.
@(private)
open_root :: proc(it: ^Records) -> bool {
	src := it.src
	it.opened = true
	p := scan_pkg.skip_space(src, scan_pkg.bom_len(src))
	z := scan_pkg.skip_space_back(src, p, len(src)) - 1
	if p < z && (src[p] == '[' || src[p] == '{') && src[z] == src[p] + 2 {
		it.pos, it.end, it.keyed = p + 1, z, src[p] == '{'
		it.commas = index_pkg.comma_cursor(p + 1)
		return true
	}
	it.pos, it.end = 1, 0
	if e, bad := validate(src).?; bad {
		it.err = e
	}
	return false
}
