package core

// The shape walk over a document's rows: a tree format's `unmarshal` once its text is built as a `Document`.
// It drives the same transitions as a format's own walk over its text (`shape_walk.odin`), with every key and
// value read from the rows, so offsets point into the document's source. A bool, `null`, string, cstring, rune
// or enum-name target reads its row's decoded value here. Everything else goes to the format's `leaf`: a number
// into a numeric target, and any value into a `Raw`, `Digits`, `Number`, `Decoded`, `any`, bit_set or hooked one,
// read as the format's own walk would read it.
//
// The document was checked as it was built, and a repeat it refuses (`Duplicates.Refuse`) was refused there.

@(private = "file")
Row_Walk :: struct {
	doc: ^Document,
	at:  Node, // the row whose value is opening
}

// The class of each kind as the shape walk numbers it: `null` is a literal, read by its row's kind.
@(private = "file")
row_class :: #force_inline proc(k: Kind) -> u8 {
	switch k {
	case .Null, .False, .True:
		return VC_LITERAL
	case .Number:
		return VC_NUMBER
	case .String:
		return VC_STRING
	case .Array:
		return VC_ARRAY
	case .Object:
		return VC_OBJECT
	}
	return VC_NONE
}

// Read the document `doc` into `dest` along `r.shape`. A container nested `max_depth` deep (at most the frames
// `r.frames` has) is `.Too_Deep`. A typed fault is `TYPED_FAULT` with `r.fault` set.
shape_rows :: proc(
	r: ^Shape_Run,
	doc: ^Document,
	dest: rawptr,
	max_depth: u64,
	c: ^$C,
	$leaf: proc(c: ^C, r: ^Shape_Run, n: Node, op: ^Shape_Op, dest: rawptr) -> Shape_Fault,
) -> Maybe(Walk_Error) {
	r.sp = 0
	r.ops, r.fields = raw_data(r.shape.ops), raw_data(r.shape.fields)
	r.pend_op, r.pend_dest, r.pend_live = r.shape.root, dest, true
	if len(doc.rows) == 0 {
		return nil
	}
	w := Row_Walk{doc = doc}
	return shape_row_value(r, &w, 0, 0, max_depth, c, leaf)
}

@(private = "file")
shape_row_value :: proc(
	r: ^Shape_Run,
	w: ^Row_Walk,
	n: Node,
	sp, max_depth: u64,
	c: ^$C,
	$leaf: proc(c: ^C, r: ^Shape_Run, n: Node, op: ^Shape_Op, dest: rawptr) -> Shape_Fault,
) -> Maybe(Walk_Error) {
	rows := w.doc.rows[:]
	row := &rows[n]
	vc := row_class(row.kind)
	w.at = n
	if err := shape_value_open(r, w, sp, u64(row.lo), max_depth, vc, row_is_null, row_tag_arm); err != nil {
		return err
	}
	if vc > VC_ARRAY {
		if !r.cur_live {
			return nil
		}
		r.cur_live = false
		if fault := shape_row_scalar(r, w.doc, n, c, leaf); fault != .None {
			return shape_fault(r, fault, u64(row.lo), sp)
		}
		return nil
	}
	if sp >= max_depth {
		return Walk_Error{offset = u64(row.lo), kind = .Too_Deep}
	}
	if r.raw_open && r.raw_sp == sp {
		r.raw_open = false
		if fault := leaf(c, r, n, &r.ops[r.cur_op], r.cur_dest); fault != .None {
			return shape_fault(r, fault, u64(row.lo), sp)
		}
		return nil
	}
	if r.sp != sp + 1 {
		// Not read: nothing inside it is.
		return nil
	}
	for m := dom_first_member(rows, n); m != NO_NODE; m = dom_next_member(rows, n, m) {
		if row.kind == .Object {
			k := &rows[m]
			if err := shape_key(r, w, u64(k.key_lo), u64(k.key_hi), m, sp + 1, false, row_key_is, row_key_scan, row_key_text, row_map_key, row_key_unique); err != nil {
				return err
			}
		}
		if err := shape_row_value(r, w, m, sp + 1, max_depth, c, leaf); err != nil {
			return err
		}
	}
	return shape_close(r, sp, u64(row.hi), row_no_container)
}

// The scalar row `n` into the latched target: by its decoded value, or by the format's `leaf`.
@(private = "file")
shape_row_scalar :: proc(
	r: ^Shape_Run,
	doc: ^Document,
	n: Node,
	c: ^$C,
	$leaf: proc(c: ^C, r: ^Shape_Run, n: Node, op: ^Shape_Op, dest: rawptr) -> Shape_Fault,
) -> Shape_Fault {
	op, dest := &r.ops[r.cur_op], r.cur_dest
	row := &doc.rows[n]
	#partial switch op.kind {
	case .Bool:
		if row.kind != .True && row.kind != .False {
			return .Wrong_Kind
		}
		shape_bool_store(row.kind == .True, dest, op.width)
		return .None
	case .Null:
		return .None if row.kind == .Null else .Wrong_Kind
	case .Pointer, .Union:
		// Only `null` gets here, or a scalar no union arm takes: any other value was unwrapped at its open.
		return shape_leaf_null(r, op, dest) if row.kind == .Null else .Wrong_Kind
	case .Cstring:
		if row.kind == .Null {
			if dest != nil {
				(^cstring)(dest)^ = nil
			}
			return .None
		}
		return shape_row_text(r, doc, n, op, dest)
	case .String, .Rune:
		return shape_row_text(r, doc, n, op, dest)
	case .Enum_Int, .Enum_Uint:
		if !r.enum_ints {
			return shape_row_text(r, doc, n, op, dest)
		}
	}
	return leaf(c, r, n, op, dest)
}

// String row `n` into a string, cstring, rune or enum-name target. A string decoded to its own bytes borrows
// the source when the run allows it.
@(private = "file")
shape_row_text :: proc(r: ^Shape_Run, doc: ^Document, n: Node, op: ^Shape_Op, dest: rawptr) -> Shape_Fault {
	row := &doc.rows[n]
	if row.kind != .String {
		return .Wrong_Kind
	}
	s, ok := get_string(doc, n)
	if !ok {
		return .Out_Of_Memory
	}
	return shape_leaf_text(r, s, op, dest, r.borrow && .Str_Escaped not_in row.flags)
}

@(private = "file")
row_is_null :: proc(w: ^Row_Walk, at: u64) -> bool {
	return w.doc.rows[w.at].kind == .Null
}

// The arm the object opening names by its first `r.union_tag` member, a string naming an arm by its decoded text.
@(private = "file")
row_tag_arm :: proc(w: ^Row_Walk, r: ^Shape_Run, op: ^Shape_Op, at: u64) -> (u8, Shape_Fault) {
	rows := w.doc.rows[:]
	for m := dom_first_member(rows, w.at); m != NO_NODE; m = dom_next_member(rows, w.at, m) {
		if !row_key_equals(w.doc, &rows[m], r.union_tag) {
			continue
		}
		tag, is_string := get_string(w.doc, m)
		if is_string {
			for arm, i in r.fields[op.elem:][:op.count] {
				if len(arm.name) > 0 && arm.name == tag {
					return u8(i + 1), .None
				}
			}
		}
		return 0, .Not_A_Member
	}
	return 0, .None
}

@(private = "file")
row_key_is :: #force_inline proc(w: ^Row_Walk, r: ^Shape_Run, key_lo, key_hi: u64, key: Node, name: string) -> bool {
	return row_key_equals(w.doc, &w.doc.rows[key], name)
}

@(private = "file")
row_key_scan :: #force_inline proc(w: ^Row_Walk, r: ^Shape_Run, op: ^Shape_Op, key_lo: u64, key: Node) -> bool {
	return true
}

@(private = "file")
row_key_text :: proc(w: ^Row_Walk, r: ^Shape_Run, key_lo, key_hi: u64, key: Node) -> (string, bool) {
	if .Key_Escaped in w.doc.rows[key].flags {
		return "", false
	}
	return get_key(w.doc, key)
}

@(private = "file")
row_map_key :: proc(w: ^Row_Walk, r: ^Shape_Run, kop: ^Shape_Op, key_lo, key_hi: u64, key: Node, dest: rawptr) -> Shape_Fault {
	s, ok := get_key(w.doc, key)
	if !ok {
		return .Out_Of_Memory
	}
	return shape_leaf_text(r, s, kop, dest, r.borrow && .Key_Escaped not_in w.doc.rows[key].flags)
}

@(private = "file")
row_key_unique :: proc(w: ^Row_Walk, r: ^Shape_Run, key_lo, key_hi, sp: u64) -> Maybe(Walk_Error) {
	return nil
}

// A container read whole was read at its open.
@(private = "file")
row_no_container :: proc(r: ^Shape_Run, lo, hi: u64) -> Shape_Fault {
	return .None
}
