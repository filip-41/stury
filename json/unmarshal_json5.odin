package json

// `unmarshal` of a JSON5 text, through its JSON spelling.

import "base:runtime"
import core_pkg "../core"
import "scan/walk"

// Read the JSON5 text `src` as `read_planned` reads JSON: built as a document, written in JSON's spelling with
// its comments (`marshal_document`), and that text read as JSONC with every string copied. A refusal's offset
// and key names point into `src`. `Infinity` and `NaN`, which have no JSON spelling, are `.Out_Of_Range` at
// the first of them.
// ponytail: three passes over the text and a copy of it; a native JSON5 shape walk when typed JSON5 reads matter.
@(private)
read_json5 :: proc(src: []byte, dest: rawptr, opts: Unmarshal_Opts, plan: ^Type_Plan, allocator: runtime.Allocator) -> Maybe(Unmarshal_Error) {
	// A repeat refused outranks a fault after it, as in JSON, so the build refuses it.
	refuse := Duplicates.Refuse if opts.duplicates == .Refuse else Duplicates.Default
	doc, berr := build(src, {dialect = .Json5, limits = opts.limits, duplicates = refuse})
	defer destroy(&doc)
	if e, bad := berr.?; bad {
		#partial switch e.kind {
		case .Out_Of_Memory:
			return Unmarshal_Error{kind = .Out_Of_Memory}
		case .Duplicate_Key:
			return Unmarshal_Error{kind = .Duplicate_Key, offset = e.offset}
		}
		return Unmarshal_Error{kind = .Syntax, syntax = e.kind, offset = e.offset}
	}
	text, merr := marshal_document(&doc, {})
	#partial switch merr {
	case .None:
	case .Non_Finite:
		return Unmarshal_Error{kind = .Out_Of_Range, offset = non_finite_at(&doc)}
	case:
		return Unmarshal_Error{kind = .Out_Of_Memory}
	}
	defer delete(text)
	as_json := opts
	as_json.dialect = .Jsonc
	as_json.borrow_strings = false
	err := read_planned(text, dest, as_json, plan, allocator)
	if e, refused := err.?; refused {
		return json5_error_at(src, &doc, text, e)
	}
	return nil
}

// The offset of the first number in `doc` that is `Infinity` or `NaN`.
@(private = "file")
non_finite_at :: proc(doc: ^Document) -> u64 {
	for r, i in doc.rows {
		if r.kind == .Number {
			if v, _ := get_number(doc, Node(i)); v.value - v.value != 0 {
				return u64(r.lo)
			}
		}
	}
	return 0
}

// `e`, a refusal of `text` (`doc` written in JSON's spelling), pointed back into `src`: the two texts have the
// same values in the same order, so a value, key or closing bracket of row `i` in one is row `i`'s in the other.
// A key name the path borrows from `text` borrows the same key as authored in `src`.
@(private = "file")
json5_error_at :: proc(src: []byte, doc: ^Document, text: []byte, e: Unmarshal_Error) -> Unmarshal_Error {
	e := e
	spelled, err := build(text, {dialect = .Jsonc})
	defer destroy(&spelled)
	if err != nil || len(spelled.rows) != len(doc.rows) {
		return e
	}
	for r, i in spelled.rows {
		s := doc.rows[i]
		switch {
		case u64(r.lo) == e.offset:
			e.offset = u64(s.lo)
		case r.key_lo != walk.NO_KEY && u64(r.key_lo) == e.offset:
			e.offset = u64(s.key_lo)
		case u64(r.hi) == e.offset + 1:
			e.offset = u64(s.hi) - 1
		case u64(r.hi) == e.offset:
			e.offset = u64(s.hi)
		case:
			continue
		}
		break
	}
	text_lo := uintptr(raw_data(text))
	for &step in e.steps[:e.n_steps] {
		name, is_name := step.(core_pkg.Name)
		at := uintptr(raw_data(name))
		if !is_name || at < text_lo || at >= text_lo + uintptr(len(text)) {
			continue
		}
		step = core_pkg.Name("")
		for r, i in spelled.rows {
			if r.key_lo == walk.NO_KEY || u64(at - text_lo) < u64(r.key_lo) || u64(at - text_lo) >= u64(r.key_hi) {
				continue
			}
			s := doc.rows[i]
			lo, hi := u64(s.key_lo), u64(s.key_hi)
			if src[lo] == '"' || src[lo] == '\'' {
				lo, hi = lo + 1, hi - 1
			}
			step = core_pkg.Name(string(src[lo:hi]))
			break
		}
	}
	return e
}
