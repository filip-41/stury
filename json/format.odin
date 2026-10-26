package json

// `format`: the buffer a caller reaches for after an edit, when the bytes are JSON text and want writing
// again rather than encoding as a value. `marshal` on a `[]byte` writes an array of numbers, which is its
// Odin meaning. JSON text goes through here, or through `Raw` when a value is expected.

// `src` validated strictly and written again as `opts` says (compact by default). A `.Jsonc` document keeps
// its comments. A `.Json5` one is written in JSON's spelling with its comments, and its first `Infinity` or
// `NaN`, which JSON cannot spell, is refused as `.Bad_Number`. The result is a new buffer from `allocator`, and
// `src` is not kept.
@(require_results)
format :: proc(
	src: []byte,
	opts := Marshal_Opts{},
	dialect := Dialect.Json,
	allocator := context.allocator,
) -> (out: []byte, err: Maybe(Error)) {
	doc, perr := build(src, {dialect = dialect}, allocator)
	if e, bad := perr.?; bad {
		return nil, e
	}
	buf, eerr := marshal(&doc, opts, allocator)
	at := non_finite_at(&doc) if eerr == .Non_Finite else 0
	destroy(&doc)
	#partial switch eerr {
	case .None:
		return buf, nil
	case .Non_Finite:
		return nil, Error{kind = .Bad_Number, offset = at}
	case .Out_Of_Memory:
		return nil, Error{kind = .Out_Of_Memory}
	case .Too_Deep:
		return nil, Error{kind = .Too_Deep}
	}
	// A built, strictly validated document reaches no other encode fault: no hooks, no pointers, and its
	// depth is the walk's.
	unreachable()
}
