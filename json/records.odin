package json

import "core:bytes"
import scan_pkg "scan"
import index_pkg "scan/index"
import "scan/walk"

// How an input is cut into records. The iterator checks the framing only: whatever the caller runs on a
// record's bytes (`validate`, `build`, `unmarshal`, `scan`) checks the record.
//
//	.NDJSON        a line of JSON whitespace only (spaces, tabs, CRs), or none, is
//	               not a record. A record includes its line's leading spaces and excludes the line break and a
//	               CR before it.
//	.JSON_Seq      RFC 7464: one or more `0x1E`, then a record: from the first byte that is neither `0x1E`
//	               nor whitespace up to the next `0x1E` or the input's end, the line feed that ends a JSON
//	               text included. Separators with only whitespace after them are no record, as the CLI's
//	               --seq reads them, and jq's. A number with no whitespace after it may be cut short (RFC 7464
//	               §2.4), and is `.Truncated` on `err`, at its end. Whitespace before the first `0x1E` is
//	               stepped over. Any other byte there is `.Bad_Char` on `err`.
//	.Root_Entries  each element of the root array, or each member of the root object (`key` is its key as
//	               written, quotes included, and the key and colon are checked here), cut at the root's commas
//	               outside strings and brackets. An empty entry between commas is yielded for the caller's check to
//	               refuse. A scalar root has no entries: it is checked whole, and its fault is `err`. The root
//	               holds each entry, so a check that must refuse what `validate` refuses of the whole takes
//	               one level off `max_depth`.
//
// A UTF-8 BOM is the input's, not a record's: one at the input's first byte is stepped over, and a record
// that starts with one past it is `.Bad_Char` on `err`, since `validate` on the record alone would step over
// it.
Framing :: enum u8 {
	NDJSON,
	JSON_Seq,
	Root_Entries,
}

// One record: its JSON text, its member's key under `.Root_Entries` of an object (nil otherwise), and the
// offset of `bytes` from the input's first byte. The slices are the caller's source.
//
// What a read of `bytes` (`validate`, `scan`, `build`, `unmarshal`) reports is an offset into `bytes`, not into
// the input. To say where it is in the input, add `at`. To render an error with `render_error`, pass `bytes` and
// the offset as it is. The input also works from `records`, with `at` added to the offset; from `records_from`
// it is gone, so `bytes` (valid until the next `next_record`) is the text to pass.
Record :: struct {
	bytes: []byte,
	key:   []byte,
	at:    u64,
}

// A pull over an input's records (`next_record`). The fields are the iterator's own but `err`: the framing
// fault that ended it, as an offset from the input's first byte.
Records :: struct {
	// The bytes framed now, the input's offset of their first, and the next one to read.
	src:     []byte,
	base:    u64,
	pos:     int,
	framing: Framing,
	// `.Root_Entries`: whether the root is open, where its entries end (its close bracket, or a piece's last
	// comma), whether it is an object, and whether the next entry is yielded even when empty, which it is
	// where a comma precedes or follows it.
	opened:  bool,
	end:     int,
	keyed:   bool,
	owed:    bool,
	commas:  index_pkg.Comma_Cursor,
	err:     Maybe(Error),
}

// The records of `src`. Allocates nothing.
@(require_results)
records :: proc(src: []byte, framing: Framing) -> Records {
	return {src = src, framing = framing}
}

// The next record, or false at the end or on a fault in `it.err`. From a `Record_Reader` it is valid until the next
// call, and also false on a failure of the reader in `read_err`.
next_record :: proc {
	next_slice_record,
	next_reader_record,
}

@(private, require_results)
next_slice_record :: proc(it: ^Records) -> (rec: Record, ok: bool) {
	if it.err != nil {
		return
	}
	switch it.framing {
	case .NDJSON:
		rec, ok = next_ndjson(it)
	case .JSON_Seq:
		rec, ok = next_json_seq(it)
	case .Root_Entries:
		rec, ok = next_entry(it)
	}
	if ok && rec.at > 0 && scan_pkg.bom_len(rec.bytes) > 0 {
		it.err = Error{kind = .Bad_Char, offset = rec.at}
		return {}, false
	}
	return
}

@(private)
next_ndjson :: proc(it: ^Records) -> (rec: Record, ok: bool) {
	src := it.src
	if it.pos == 0 && it.base == 0 {
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
		if end > start && src[end - 1] == '\r' {
			end -= 1
		}
		p := start
		for p < end && walk.is_space(src[p]) {
			p += 1
		}
		if p < end {
			return {bytes = src[start:end], at = it.base + u64(start)}, true
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
	if it.pos == 0 && it.base == 0 {
		it.pos = scan_pkg.bom_len(src)
	}
	for it.pos < len(src) && walk.is_space(src[it.pos]) {
		it.pos += 1
	}
	if it.pos >= len(src) {
		return
	}
	if src[it.pos] != 0x1E {
		it.err = Error{kind = .Bad_Char, offset = it.base + u64(it.pos)}
		return
	}
	start := it.pos
	for start < len(src) {
		// A record's first byte is above a space. The separators and whitespace are not.
		c := src[start]
		if c != 0x1E && (c > ' ' || !walk.is_space(c)) {
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
	rec = {bytes = src[start:it.pos], at = it.base + u64(start)}
	if scan_pkg.seq_truncated_number(rec.bytes) {
		it.err = Error{kind = .Truncated, offset = it.base + u64(it.pos)}
		return {}, false
	}
	return rec, true
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
	for lo < hi && walk.is_space(src[lo]) {
		lo += 1
	}
	for hi > lo && walk.is_space(src[hi - 1]) {
		hi -= 1
	}
	if lo == hi && !it.owed {
		// The root is empty.
		return
	}
	key: []byte
	if it.keyed && lo < hi {
		key, lo = entry_key(it, lo, hi)
		if key == nil {
			return
		}
	}
	return {bytes = src[lo:hi], key = key, at = it.base + u64(lo)}, true
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
	p := lo + len(key)
	for p < hi && walk.is_space(src[p]) {
		p += 1
	}
	if p == hi || src[p] != ':' {
		// Past the key there is only space before the entry's comma or the root's close.
		for p < it.end && walk.is_space(src[p]) {
			p += 1
		}
		entry_fault(it, p, .Bad_Char)
		return nil, 0
	}
	p += 1
	for p < hi && walk.is_space(src[p]) {
		p += 1
	}
	return key, p
}

@(private)
entry_fault :: proc(it: ^Records, p: int, kind: Error_Kind) {
	it.err = Error{kind = kind, offset = it.base + u64(p)}
	it.pos = it.end + 1
}

// Find the root: its open bracket, and its close as the last byte that is not space. A scalar root, or a
// container that does not end in its close, is checked whole, which yields no entry.
@(private)
open_root :: proc(it: ^Records) -> bool {
	src := it.src
	it.opened = true
	p := scan_pkg.bom_len(src)
	for p < len(src) && walk.is_space(src[p]) {
		p += 1
	}
	z := len(src) - 1
	for z > p && walk.is_space(src[z]) {
		z -= 1
	}
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
