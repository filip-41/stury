package core

// The typed per-record reader's neutral half: a handle that resolves a type's plan and read shape once, and a
// format source that pulls one record and reads it. A format supplies its own options and its own plan spelling.

// The format half of a `Record_Read`: how the format pulls the next record and reads it into a value, and how it
// frees the pull's state. `destroy` may be nil for a source that holds nothing.
//
//	- `read` reads one record's bytes the way the format's `unmarshal` reads them, into `dest`, a value of the
//	  reader's root type. It returns nil, or the record's refusal. A source with no record left returns
//	  `.Bad_Option`; a fault that frames no record is the format's own.
//	- `opts` is the reader's options as the format spells them, read again on every call: a change made between
//	  records applies to the next.
//	- `plan` is the reader's resolved plan. It is the handle's when the reader owns it, and a handle may be
//	  copied or returned by value: a state that held this pointer would point into the copy's caller.
//	- The end of the input is `.Bad_Option`, for every format. A fault no record holds is the format's own, and
//	  its offset is into the input (`record_read_at` is then 0).
//	- `format` spells a plan the reader makes when it is given none. Core makes a `Type_Plan` by it.
Record_Source :: struct($O: typeid) {
	state:   rawptr,
	read:    proc(state: rawptr, opts: ^O, plan: ^Type_Plan, dest: rawptr) -> Maybe(Unmarshal_Error),
	destroy: proc(state: rawptr),
	format:  Plan_Format,
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
// A format refuses its own unusable options (JSON's `.Structural` without JSONC) in its `record_read_init`
// before this, since their spelling is its own. So does a refusable option leave the handle empty, not half
// built: a refusal frees the plan it made and the source's state.
@(require_results)
record_read_init :: proc(
	r: ^Record_Read($O),
	$T: typeid,
	source: Record_Source(O),
	opts: O,
	plan: ^Type_Plan = nil,
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
		r.plan = plan
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

// Read the next record into `ptr^`, as the format's `unmarshal` reads one record's bytes. The options the reader
// holds apply, so a change since the last record takes effect here. A refusal leaves the record's partial value
// and the reader ready for the next record.
@(require_results)
unmarshal :: proc(r: ^Record_Read($O), ptr: ^$T) -> Maybe(Unmarshal_Error) {
	if r == nil || r.source.read == nil || !r.ready || ptr == nil {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	if r.root != T {
		return Unmarshal_Error{kind = .Plan_Mismatch}
	}
	return r.source.read(r.source.state, &r.opts, record_read_plan(r), ptr)
}

// Free the plan the reader made and the source's state, and clear the handle. A copy of the handle shares both,
// so destroy it once; destroying this handle twice finds no state the second time.
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

// `record_read_destroy`, for a caller that destroys several owners through one name.
destroy :: proc {
	record_read_destroy,
}
