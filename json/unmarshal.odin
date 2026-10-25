package json

import "base:runtime"
import core_pkg "../core"
import "scan/walk"
import scan_pkg "scan"

// Unknown_Fields selects what `unmarshal` does with a member the target type does not name. `.Ignore` checks
// it under `.Strict` and may skip it unchecked under `.Lazy` (see `strictness`). `.Refuse` refuses it with
// `.Unknown_Field` at its key.
Unknown_Fields :: core_pkg.Unknown_Fields

// How `unmarshal` and `unmarshal_check` read: the zero value is `.Strict`, `.Last`, unknown members ignored,
// strings copied, default `Limits`, strict JSON. The `Read_Opts` fields read as follows here:
//
//	strictness  `.Strict` checks every byte. `.Lazy` checks every value the type reads, and may skip, unchecked,
//	            the members and values it does not read, so under `.Lazy` an unread malformed value may be
//	            accepted or refused. Use `.Strict` to refuse every one. Which it is depends on the document's
//	            size and shape, not on the fault. `.Structural` is `.Bad_Option` under `.Json`: a typed read stores what it
//	            reads, so it checks it.
//	duplicates  what to do with a key that appears twice in one object. `.Default` is `.Last`, which keeps
//	            only the last occurrence. A struct member is reset to zero before it is read again, so nothing
//	            of the earlier one survives, and a map entry or an `any` is replaced. `.First` reads the first
//	            occurrence and checks the later ones as `strictness` says, without storing them. `.All` reads
//	            every occurrence over the one before: struct fields and map entries merge, and a list is read
//	            from its start over the earlier one. `.Refuse` refuses a key that, decoded, repeats one of its
//	            own object's (`.Duplicate_Key` at the repeat), in any object, read or not, under `.Lazy` too:
//	            the walk skips nothing while it is set. Its keys past the first 64 open at once are remembered
//	            in `context.allocator`, given back before the return.
//	limits      a `max_depth` past MAX_DEPTH is held to MAX_DEPTH: the shape walk's frames do not spill.
//	dialect     `.Jsonc` reads comments and trailing commas, every byte checked whatever `strictness` says.
Unmarshal_Opts :: struct {
	using read:     Read_Opts,
	unknown_fields: Unknown_Fields,
	// Escape-free strings and `Raw` values slice `src` instead of being copied, so they live as long as
	// `src`. An escaped string is decoded into the allocator either way. A `cstring` is always copied.
	borrow_strings: bool,
}

// What `unmarshal` refused. A hook's refusal uses the same numbers. `.Bad_Option` is also `.Structural`
// strictness, and `.Syntax` is at `validate`'s offset.
Unmarshal_Error_Kind :: core_pkg.Unmarshal_Error_Kind

// A refusal: what, where, and the path to it.
//
//	- A typed fault's path names exactly the value refused.
//	- A `.Syntax` fault's path is approximate: it names the innermost member or element opened, which may
//	  already have closed (`[1,` names `[0]`). The offset is exact either way.
//	- A `Name` step borrows `src` (a map key, or a key the type does not name, as authored) or the type info
//	  (a field name), so the path is valid while `src` is.
Unmarshal_Error :: core_pkg.Unmarshal_Error

// Read the one JSON value in `src` into `ptr^`. Returns nil, or an `Unmarshal_Error` that says what was
// refused, where, and the path to it. How strict the read is, how repeated keys and unknown members are
// treated and whether strings are copied: see `Unmarshal_Opts`.
//
// The value is read over what `ptr^` already holds, as Go's and core's unmarshal do.
//
// What a read leaves and replaces:
//
//	- A member the text lacks leaves its field as it was, and only a field tagged `json:",required"` is
//	  `.Missing_Field` when absent.
//	- A map keeps its entries and sets the text's.
//	- A non-nil pointer is read through (Go's rule, core reads no pointer), a nil one gets a fresh zeroed
//	  pointee.
//	- A slice, dynamic array or fixed-capacity one is replaced by the text's elements, each from zero
//	  (core's rule, Go reuses the backing array). A fixed array's elements are read over in place.
//	- A union is replaced, its arm from zero (Go reads through an interface holding a non-nil pointer).
//
// What it refuses:
//
//	- `null` into a bool, number, string, list, map or struct is `.Wrong_Kind` (Go leaves a scalar or struct
//	  as it was and nils a slice or map).
//	- A number with a fraction or exponent into an integer is `.Wrong_Kind`, `1.0` too.
//	- A refusal before the read starts (`.Bad_Option`, `.Plan_Mismatch`, `.Unsupported`, or `.Out_Of_Memory`
//	  lowering the plan) leaves `ptr^` untouched. A later one leaves what was read before the fault.
//	- Under `.Lazy` an unread malformed value may be accepted or refused. Use `.Strict` to refuse every one.
//
// Allocation and ownership:
//
//	- Strings are copied unless `borrow_strings` (an escaped one and a `cstring` always are).
//	- Everything it creates comes from `allocator`, a dynamic array's own `allocator` field included, and
//	  nothing is freed, not what a refused read made nor the list or string a read replaced: read into an
//	  arena freed whole. With the default allocator a refusal therefore leaks its partial result; run
//	  `unmarshal_check` first to refuse without allocating the target.
//	- With `plan` nil the plan is this thread's cached one for `T`, as `marshal` takes it. A kept plan must
//	  have been made for `T`.
//
// A `^Record_Read` reads one record's bytes the same way. `record_read_init` resolves the plan and the shape
// once; a fault's offset stays into those bytes.
unmarshal :: proc {
	unmarshal_value,
	unmarshal_record,
}

@(require_results)
unmarshal_value :: proc(
	src: []byte,
	ptr: ^$T,
	opts := Unmarshal_Opts{},
	plan: ^Type_Plan = nil,
	allocator := context.allocator,
) -> (err: Maybe(Unmarshal_Error)) {
	if ptr == nil {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	return read_typed(src, ptr, T, opts, plan, allocator)
}

// Whether `src` reads as a `T` under `opts`: the same walk and the same results as `unmarshal`, but for what
// a hook would refuse.
//
//	- With no target, it allocates nothing but the plan (and `.Refuse`'s spilled keys, given back).
//	- With `plan` nil the plan is this thread's cached one for `T`, as `marshal` takes it. A kept plan
//	  allocates nothing after its first use, which lowers the read shape in the plan's allocator.
@(require_results)
unmarshal_check :: proc(src: []byte, $T: typeid, opts := Unmarshal_Opts{}, plan: ^Type_Plan = nil) -> (err: Maybe(Unmarshal_Error)) {
	return read_typed(src, nil, T, opts, plan, runtime.nil_allocator())
}

@(private)
read_typed :: proc(
	src: []byte,
	dest: rawptr,
	T: typeid,
	opts: Unmarshal_Opts,
	plan: ^Type_Plan,
	allocator: runtime.Allocator,
) -> Maybe(Unmarshal_Error) {
	if opts.strictness == .Structural && opts.dialect != .Jsonc {
		return Unmarshal_Error{kind = .Bad_Option}
	}
	tmp: Type_Plan = ---
	p, ok := plan_for(plan, T, &tmp)
	if !ok {
		return Unmarshal_Error{kind = .Plan_Mismatch}
	}
	err := read_planned(src, dest, opts, p, allocator)
	e, refused := err.?
	plan_done(p, plan, &tmp, refused && e.kind == .Out_Of_Memory)
	return err
}

@(private)
read_planned :: proc(src: []byte, dest: rawptr, opts: Unmarshal_Opts, plan: ^Type_Plan, allocator: runtime.Allocator) -> Maybe(Unmarshal_Error) {
	shape, serr := core_pkg.read_shape_of(&plan.base)
	if serr != nil {
		return serr
	}
	frames: [MAX_DEPTH]walk.Shape_Frame = ---
	wide: [walk.SHAPE_WIDE_WORDS]u64 = ---
	run := walk.Shape_Run{
		shape          = shape,
		frames         = &frames,
		wide           = wide[:],
		src            = src,
		allocator      = allocator,
		borrow         = opts.borrow_strings,
		refuse_unknown = opts.unknown_fields == .Refuse,
		keep_first     = opts.duplicates == .First,
		read_over      = opts.duplicates == .All,
		enum_ints      = plan.opts.enums == .Int,
		union_tag      = plan.opts.union_tag,
	}
	lazy := opts.strictness == .Lazy
	// The descent never skips, so `.Lazy` takes it only where skipping would not pay.
	if shape.descends && opts.dialect == .Json && opts.duplicates != .Refuse && (!lazy || scan_pkg.shape_lazy_reads_all(src, &run, opts.limits)) {
		read, oom := scan_pkg.shape_descend(src, &run, dest, opts.limits)
		if e, refused := oom.?; refused {
			return unmarshal_error_of(&run, e)
		}
		if read {
			return nil
		}
	}
	// The dialect and `refuse` (the last argument) are compile-time parameters of the walks, so each call
	// below is a separate instance and the plain JSON read compiles without the JSONC and key-check code.
	verdict: Maybe(Error)
	if opts.dialect == .Jsonc {
		verdict = scan_pkg.scan_shape(src, &run, dest, lazy, opts.limits, .Jsonc, false) if opts.duplicates != .Refuse else scan_pkg.scan_shape(src, &run, dest, lazy, opts.limits, .Jsonc, true)
	} else if lazy {
		verdict = scan_pkg.scan_shape_lazy(src, &run, dest, opts.limits, false) if opts.duplicates != .Refuse else scan_pkg.scan_shape_lazy(src, &run, dest, opts.limits, true)
	} else {
		verdict = scan_pkg.scan_shape(src, &run, dest, false, opts.limits, .Json, false) if opts.duplicates != .Refuse else scan_pkg.scan_shape(src, &run, dest, false, opts.limits, .Json, true)
	}
	if e, refused := verdict.?; refused {
		return unmarshal_error_of(&run, e)
	}
	return nil
}

// The walk's refusal with its path: one step per live frame that names one. A typed fault names
// `run.fault_steps` frames. The walk's own result names every frame the shape walk has open.
@(private)
unmarshal_error_of :: proc(run: ^walk.Shape_Run, e: Error) -> (err: Unmarshal_Error) {
	err.offset = e.offset
	steps := run.sp
	#partial switch e.kind {
	case walk.TYPED_FAULT:
		err.kind = Unmarshal_Error_Kind(run.fault)
		steps = u64(run.fault_steps)
		// A union's tag that is not well-formed is the walk's syntax fault at its byte: a value that is read is
		// checked before it is refused.
		if run.fault == .Not_A_Member && e.offset < u64(len(run.src)) && run.src[e.offset] == '{' {
			if serr, bad := scan_pkg.shape_tag_verdict(run, e.offset).?; bad {
				err.kind, err.syntax, err.offset = .Syntax, serr.kind, serr.offset
			}
		}
	case .Duplicate_Key:
		err.kind = .Duplicate_Key
	case:
		err.kind = .Syntax
		err.syntax = e.kind
	}
	for k := int(steps) - 1; k >= 0 && !err.truncated; k -= 1 {
		f := &run.frames[k]
		op := &run.shape.ops[f.op]
		// A frame names nothing before its first key or element: a syntax fault can stop there.
		#partial switch op.kind {
		case .Struct, .Map:
			if op.kind == .Struct && f.field != core_pkg.NO_FIELD {
				core_pkg.unmarshal_path_prepend(&err, Name(run.shape.fields[op.elem + f.field].name))
			} else if f.key_hi != 0 {
				core_pkg.unmarshal_path_prepend(&err, Name(string(run.src[f.key_lo + 1:f.key_hi - 1])))
			}
		case:
			if f.n > 0 {
				core_pkg.unmarshal_path_prepend(&err, Index(f.n - 1))
			}
		}
	}
	return
}
