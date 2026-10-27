package core

// The format half of a `Record_Read`: how the format pulls the next record and reads it into a value, and how it
// frees the pull's state. `destroy` may be nil for a source that holds nothing.
//
//	- `read` reads one record's bytes the way the format's `unmarshal` reads them, into `dest`, a value of the
//	  reader's root type, and sets `at^` to the record's offset in the input, 0 when it pulled none. It returns
//	  nil, or the record's refusal. A source with no record left returns `.Bad_Option`; a fault that frames no
//	  record is the format's own.
//	- `opts` is the reader's options as the format spells them, read again on every call: a change made between
//	  records applies to the next.
//	- `plan` is the reader's resolved plan, passed in because a state that held it would dangle in a copy of the
//	  handle.
//	- The end of the input is `.Bad_Option`, for every format. A fault no record holds is the format's own, and
//	  its offset is into the input (`record_read_at` is then 0).
//	- `format` spells a plan the reader makes when it is given none. Core makes a `Type_Plan` by it.
Record_Source :: struct($O: typeid) {
	state:   rawptr,
	read:    proc(state: rawptr, opts: ^O, plan: ^Type_Plan, dest: rawptr, at: ^u64) -> Maybe(Unmarshal_Error),
	destroy: proc(state: rawptr),
	format:  Plan_Format,
}

// A typed read's options: the format's `Read_Opts` (`R`), and what the read does beyond them.
Unmarshal_Opts :: struct($R: typeid) {
	using read:     R,
	unknown_fields: Unknown_Fields,
	// A string with nothing to decode slices `src` instead of being copied, so it lives as long as `src`. One
	// with something to decode is decoded into the allocator, and a `cstring` is always copied.
	borrow_strings: bool,
}

// A typed read of many records of one type: the plan and, once `record_read_init` lowers one, the read shape are
// resolved once, and each `unmarshal` reads one record through `source`.
//
// It is a value. A copy shares the source and the plan it owns, so destroy a reader once: `destroy` clears this
// handle, and a second destroy finds nothing. Every field is the reader's own; read none of them.
Record_Read :: struct($O: typeid) {
	// The caller's plan, borrowed. Nil when the reader made its own (`owned`): a pointer into the handle would
	// dangle in a copy, so `record_read_plan` finds it.
	plan:   ^Type_Plan,
	opts:   O,
	source: Record_Source(O),
	// The plan the reader made, when the caller gave none, and whether it did.
	owned:  Type_Plan,
	root:   typeid,
	// The offset in the input of the record the last read pulled, 0 before the first.
	at:     u64,
	owns:   bool,
	ready:  bool,
}

// The plan `r` reads by: the caller's, or the one the reader owns.
@(require_results)
record_read_plan :: proc(r: ^Record_Read($O)) -> ^Type_Plan {
	return &r.owned if r.owns else r.plan
}

// Resolve the plan for `T` and lower its read shape once. `plan` is the caller's, borrowed, or nil to make and
// own one spelled by `source.format`, in `allocator`. Destroys the reader's previous reading first.
//
// A format refuses its own unusable options (JSON's `.Structural` without JSONC) before calling this. A refusal
// frees the plan and source state it made and leaves the handle empty.
@(require_results)
record_read_init :: proc(
	r: ^Record_Read($O),
	$T: typeid,
	source: Record_Source(O),
	opts: O,
	plan: ^Hooked_Plan($W),
	allocator := context.allocator,
) -> Maybe(Unmarshal_Error) {
	if r == nil {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	record_read_destroy(r)
	r.opts, r.root, r.source = opts, T, source
	if plan != nil {
		if plan.root != T {
			record_read_destroy(r)
			return Unmarshal_Error{kind = .Plan_Mismatch}
		}
		r.plan = &plan.base
	} else {
		r.owned = type_plan_init(T, {}, source.format, allocator)
		r.owns = true
	}
	if _, err := read_shape_of(record_read_plan(r)); err != nil {
		record_read_destroy(r)
		return err
	}
	r.ready = true
	return nil
}

// `.Bad_Option` for a reader that is not ready, `.Plan_Mismatch` for a root other than `T`, else nil. A format's
// `unmarshal` calls it before its source.
@(require_results)
record_read_check :: #force_inline proc(r: ^Record_Read($O), ptr: ^$T) -> Maybe(Unmarshal_Error) {
	if r == nil || r.source.read == nil || !r.ready || ptr == nil {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	if r.root != T {
		return Unmarshal_Error{kind = .Plan_Mismatch}
	}
	return nil
}

// Read the next record into `ptr^`. A refusal leaves the record's partial value and the reader ready for the
// next record.
@(require_results)
unmarshal :: proc(r: ^Record_Read($O), ptr: ^$T) -> Maybe(Unmarshal_Error) {
	if err := record_read_check(r, ptr); err != nil {
		return err
	}
	return r.source.read(r.source.state, &r.opts, record_read_plan(r), ptr, &r.at)
}

// Free the plan the reader made and the source's state, and clear the handle.
record_read_destroy :: proc(r: ^Record_Read($O)) {
	if r == nil {
		return
	}
	if r.owns {
		type_plan_destroy(&r.owned)
	}
	if r.source.destroy != nil {
		r.source.destroy(r.source.state)
	}
	r^ = {}
}

