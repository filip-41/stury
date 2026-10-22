package json

import "base:runtime"
import core_pkg "../core"
import scan_pkg "scan"

// What `unmarshal` does with a member the target type does not name.
Unknown_Fields :: enum u8 {
	Ignore, // the member is checked (`.Strict`), or may be skipped unchecked (`.Lazy`, see `strictness`)
	Refuse, // `.Unknown_Field` at its key
}

// How `unmarshal` and `unmarshal_check` read: the zero value is `.Strict`, `.Last`, unknown members ignored,
// strings copied, default `Limits`, strict JSON.
Unmarshal_Opts :: struct {
	// `.Strict` checks every byte. `.Lazy` checks every value the type reads, and may skip, unchecked, the
	// members and values it does not read, so under `.Lazy` an unread malformed value may be accepted or
	// refused. Use `.Strict` to refuse every one. Which it is depends on the document's size and shape, not
	// on the fault. `.Structural` is `.Bad_Option`: a typed read stores what it reads, so it checks it. Under
	// `dialect = .Jsonc`, which reads every byte whatever `strictness` says, it reads the document strictly.
	strictness:     Strictness,
	// What to do with a key that appears twice in one object. `.Last` keeps the last occurrence only: a struct member is reset to
	// zero before it is read again, so nothing of the earlier one survives, and a map entry or an `any` is
	// replaced. `.First` reads the first occurrence and checks the later ones as `strictness` says, without
	// storing them. `.All` reads every occurrence over the one before: struct fields and map entries merge,
	// and a list is read from its start over the earlier one. `.Refuse` refuses a key that, decoded, repeats
	// one of its own object's (`.Duplicate_Key` at the repeat), in any object, read or not, under `.Lazy` too:
	// the walk skips nothing while it is set. Its keys past the first 64 open at once are remembered in
	// `context.allocator`, given back before the return. Every occurrence is checked.
	duplicates:     Duplicates,
	unknown_fields: Unknown_Fields,
	// Escape-free strings and `Raw` values slice `src` instead of being copied, so they live as long as
	// `src`. An escaped string is decoded into the allocator either way. A `cstring` is always copied.
	borrow_strings: bool,
	// A `max_depth` past MAX_DEPTH is held to MAX_DEPTH: the shape walk's frames do not spill.
	limits:         Limits,
	// `.Jsonc` reads comments and trailing commas, every byte checked whatever `strictness` says.
	dialect:        Dialect,
}

// The kinds a read itself reports come first, numbered from 1. A hook's refusal uses the same numbers.
Unmarshal_Error_Kind :: enum u8 {
	Wrong_Kind = 1,  // the value's JSON kind is not one the target takes, at the value
	Out_Of_Range,    // the right kind, but the target cannot hold it, at the value (or the map key)
	Not_A_Member,    // an enum target and a name or an integer that is none of its members, at the value
	Wrong_Length,    // a fixed array short (at its `]`) or over (at the first element too many)
	Missing_Field,   // a field tagged `required` absent, at the object's `}`, the path ends at the field
	Unknown_Field,   // `Unknown_Fields.Refuse` and a member the type does not name, at its key
	Missing_Tag,     // a union only `Plan_Opts.union_tag` reads objects into, and an object without it, at the `{`
	Repeated_Tag,    // such an object with its `union_tag` member twice, at the second key
	Out_Of_Memory,   // the allocator refused, or a list past 2^31 elements, at the value being read (0 preparing the type)
	Syntax,          // the walk's own syntax or budget result (`syntax`), at `validate`'s offset (the path is approximate)
	Unsupported,     // a type unmarshal cannot read, before any byte, offset 0, the path names the field
	Ambiguous_Union, // a union two of whose arms take one JSON kind, before any byte, offset 0, the path names the union
	Bad_Option,      // a nil target, or `.Structural` strictness of a JSON read
	Plan_Mismatch,   // the plan was made for another root type
	Duplicate_Key,   // `Duplicates.Refuse` and a key repeating one of its object's, at the repeat's key, the path as deep as the target reads
}

#assert(int(Unmarshal_Error_Kind.Wrong_Kind) == int(core_pkg.Shape_Fault.Wrong_Kind))
#assert(int(Unmarshal_Error_Kind.Out_Of_Range) == int(core_pkg.Shape_Fault.Out_Of_Range))
#assert(int(Unmarshal_Error_Kind.Not_A_Member) == int(core_pkg.Shape_Fault.Not_A_Member))
#assert(int(Unmarshal_Error_Kind.Wrong_Length) == int(core_pkg.Shape_Fault.Wrong_Length))
#assert(int(Unmarshal_Error_Kind.Missing_Field) == int(core_pkg.Shape_Fault.Missing_Field))
#assert(int(Unmarshal_Error_Kind.Unknown_Field) == int(core_pkg.Shape_Fault.Unknown_Field))
#assert(int(Unmarshal_Error_Kind.Missing_Tag) == int(core_pkg.Shape_Fault.Missing_Tag))
#assert(int(Unmarshal_Error_Kind.Repeated_Tag) == int(core_pkg.Shape_Fault.Repeated_Tag))
#assert(int(Unmarshal_Error_Kind.Out_Of_Memory) == int(core_pkg.Shape_Fault.Out_Of_Memory))

// The innermost steps an error path keeps.
@(private)
UNMARSHAL_PATH_STEPS :: 8

// A refusal: what, where, and the path to it.
//
//	- A typed fault's path names exactly the value refused.
//	- A `.Syntax` fault's path is approximate: it names the innermost member or element opened, which may
//	  already have closed (`[1,` names `[0]`). The offset is exact either way.
//	- A `Name` step borrows `src` (a map key, or a key the type does not name, as authored) or the type info
//	  (a field name), so the path is valid while `src` is.
Unmarshal_Error :: struct {
	steps:     [UNMARSHAL_PATH_STEPS]Step, // the path, outermost first, as `steps[:n_steps]`
	offset:    u64,
	kind:      Unmarshal_Error_Kind,
	syntax:    Error_Kind, // `.Syntax` only
	n_steps:   u8,
	truncated: bool, // steps outside the innermost UNMARSHAL_PATH_STEPS were dropped
}

// Read the one JSON value in `src` into `ptr^`. Returns nil, or an `Unmarshal_Error` that says what was
// refused, where, and the path to it. How strict the read is, how repeated keys and unknown members are
// treated and whether strings are copied: see `Unmarshal_Opts`.
//
// The value is read over what `ptr^` already holds, as Go's and core's unmarshal do. That read-over rule is
// all stury takes from Go: where Go is lenient, stury refuses.
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
//	  arena freed whole.
//	- With `plan` nil the plan is this thread's cached one for `T`, as `marshal` takes it. A kept plan must
//	  have been made for `T`.
unmarshal :: proc(
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
	shape, serr := read_shape_of(plan)
	if serr != nil {
		return serr
	}
	frames: [MAX_DEPTH]core_pkg.Shape_Frame = ---
	wide: [core_pkg.SHAPE_WIDE_WORDS]u64 = ---
	run := core_pkg.Shape_Run{
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

// A shape fault is the kind of its name, so a hook's answer passes through it as it is.
#assert(u8(core_pkg.Shape_Fault.Wrong_Kind) == u8(Unmarshal_Error_Kind.Wrong_Kind))
#assert(u8(core_pkg.Shape_Fault.Out_Of_Range) == u8(Unmarshal_Error_Kind.Out_Of_Range))
#assert(u8(core_pkg.Shape_Fault.Not_A_Member) == u8(Unmarshal_Error_Kind.Not_A_Member))
#assert(u8(core_pkg.Shape_Fault.Wrong_Length) == u8(Unmarshal_Error_Kind.Wrong_Length))
#assert(u8(core_pkg.Shape_Fault.Missing_Field) == u8(Unmarshal_Error_Kind.Missing_Field))
#assert(u8(core_pkg.Shape_Fault.Unknown_Field) == u8(Unmarshal_Error_Kind.Unknown_Field))
#assert(u8(core_pkg.Shape_Fault.Missing_Tag) == u8(Unmarshal_Error_Kind.Missing_Tag))
#assert(u8(core_pkg.Shape_Fault.Repeated_Tag) == u8(Unmarshal_Error_Kind.Repeated_Tag))
#assert(u8(core_pkg.Shape_Fault.Out_Of_Memory) == u8(Unmarshal_Error_Kind.Out_Of_Memory))

// The walk's refusal with its path: one step per live frame that names one. A typed fault names
// `run.fault_steps` frames. The walk's own result names every frame the shape walk has open.
@(private)
unmarshal_error_of :: proc(run: ^core_pkg.Shape_Run, e: Error) -> (err: Unmarshal_Error) {
	err.offset = e.offset
	steps := run.sp
	#partial switch e.kind {
	case core_pkg.TYPED_FAULT:
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
				unmarshal_path_prepend(&err, Name(run.shape.fields[op.elem + f.field].name))
			} else if f.key_hi != 0 {
				unmarshal_path_prepend(&err, Name(string(run.src[f.key_lo + 1:f.key_hi - 1])))
			}
		case:
			if f.n > 0 {
				unmarshal_path_prepend(&err, Index(f.n - 1))
			}
		}
	}
	return
}

// Put `s` before the path's steps. Paths are found innermost first, so once UNMARSHAL_PATH_STEPS are held a
// further step is an outer one, and it is dropped.
@(private)
unmarshal_path_prepend :: proc(err: ^Unmarshal_Error, s: Step) {
	if int(err.n_steps) == UNMARSHAL_PATH_STEPS {
		err.truncated = true
		return
	}
	copy(err.steps[1:err.n_steps + 1], err.steps[:err.n_steps])
	err.steps[0] = s
	err.n_steps += 1
}
