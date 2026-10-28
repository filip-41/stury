package json

// `format`: the buffer a caller reaches for after an edit, when the bytes are JSON text and want writing
// again rather than encoding as a value. `marshal` on a `[]byte` writes an array of numbers, which is its
// Odin meaning. JSON text goes through here, or through `Raw` when a value is expected.

import core_pkg "../core"

// `src` read as `build` reads it under `read` (its `dialect`, `duplicates` and `limits`; always `.Strict`) and
// written again as `write` says (compact by default). A `.Jsonc` document keeps its comments. A `.Json5` one is
// written in JSON's spelling with its comments. The result is a new buffer from `allocator`, and `src` is not
// kept.
//
//	.Bad_Source     the text's fault (`syntax`, `detail` and `offset`), or `build`'s refusal of `src`.
//	.Bad_Option     `build` refused `read`.
//	.Encode         the writer refused: `encode` `.Non_Finite` at the first `Infinity` or `NaN` of a JSON5
//	                text, which JSON cannot spell (`offset`), or `.Too_Deep` for a text nested past
//	                MAX_DEPTH (under a raised `max_depth`) in any output but compact plain JSON.
//	.Out_Of_Memory  the allocator refused.
@(require_results)
format :: proc(
	src: []byte,
	read := Read_Opts{},
	write := Document_Opts{},
	allocator := context.allocator,
) -> (out: []byte, err: Maybe(Path_Error)) {
	doc, berr := build(src, read, allocator)
	if e, bad := berr.?; bad {
		return nil, core_pkg.path_error_of(e)
	}
	buf, eerr := document_text(&doc, write, allocator)
	at := non_finite_at(&doc) if eerr == .Non_Finite else 0
	destroy(&doc)
	#partial switch eerr {
	case .None:
		return buf, nil
	case .Out_Of_Memory:
		return nil, core_pkg.PATH_OUT_OF_MEMORY
	}
	return nil, Path_Error{kind = .Encode, encode = eerr, offset = at}
}

// The offset of the first number in `doc` at or under node `n` that is `Infinity` or `NaN`.
@(private)
non_finite_at :: proc(doc: ^Document, n: Node = 0) -> u64 {
	for r, i in doc.rows[n:][:doc.rows[n].subtree_size] {
		if r.kind == .Number {
			if v, _ := get_number(doc, n + Node(i)); v.value - v.value != 0 {
				return u64(r.lo)
			}
		}
	}
	return 0
}
