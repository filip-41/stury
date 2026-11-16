package core

import "base:runtime"
import "core:io"
import "core:reflect"
import spell "./spell"

// The value layer's error, `Document_Error`, which holds a `Fault` by value in `inner`, and `Error`, the union every
// public procedure returns, with its code and its rendered line.

// The value layer's error kinds. `Document_Error.inner` holds a `Fault` by value for `.Walk`, `.Bad_Value` and
// `.Bad_Result`, so the error renders with its cause. The last two name a byte of a text that is not the rendered
// source.
Document_Error_Kind :: enum u8 {
	None,
	Walk, // the walk's fault, in `inner`
	Duplicate_Key, // a build under `.Refuse` met a key that repeats one of its object's, or a YAML read by name one of the same text and another type, at the second key's first byte, or a commit's named cell is one its record holds, at the header cell
	No_Memory, // an allocation the document or the edit list owns was refused, at no byte
	Bad_Index, // an edit names no node it may change: no such node, a key of a member, the root, a table's record
	Bad_Position, // an insert position is past the container's length
	Wrong_Container, // the container requires the other insert form: a key for a member, none for an element
	Bad_Value, // a recorded text is not exactly one value of the document's format and spec
	Bad_Fact, // a recorded fact body does not have its role's shape
	Bad_Width, // an edit would leave a delimited text a record the table cannot read
	Bad_Spec, // a commit asks for a spec of another format family, or one a delimited text cannot write
	Conflicting_Edits, // two edits of one node, or an edit inside what another replaces or removes, at the first byte of the node or span they share
	Bad_Result, // a committed text does not read, the walk's fault in `inner`
	Frozen, // the format does not let an edit touch the node, at no byte: `at` is the node, and `inner.rules` and `inner.detail` give the reason
}

// The document error kinds that name no byte of the text. Their `at` is not read.
@(private)
DOCUMENT_AT_NO_BYTE :: bit_set[Document_Error_Kind]{.None, .No_Memory, .Bad_Index, .Bad_Position, .Wrong_Container, .Bad_Value, .Bad_Fact, .Bad_Width, .Bad_Spec, .Bad_Result, .Frozen}

// Whether `e` names a byte of the source: its kind does, and for `.Walk` its fault does too, as a bad option is found
// before any byte is read.
@(private)
document_at_byte :: proc "contextless" (e: Document_Error) -> bool {
	return e.kind not_in DOCUMENT_AT_NO_BYTE && (e.kind != .Walk || e.inner.kind not_in AT_NO_BYTE)
}

// Returns the build error a walk's fault is. A stack the walk could not grow is the allocator's refusal, not the text's.
fault_error :: proc "contextless" (f: Fault) -> Document_Error {
	if f.kind == .No_Memory {
		return {kind = .No_Memory}
	}
	return {kind = .Walk, at = f.at, inner = f}
}

// Moves the bytes of the source `e` names by `by`, for an error found in a text that starts `by` bytes in.
move_document_error :: proc(e: ^Document_Error, by: u64) {
	if document_at_byte(e^) {
		e.at += by
		if e.kind == .Walk {
			e.inner.at += by
		}
	}
}

// Why an edit is `.Bad_Index`, or for the cell reasons `.Bad_Value`, with `at` the position of the cell in a record, or
// for `.Reads_Back_Other` `.Bad_Result`.
Edit_Reason :: enum u8 {
	None,
	No_Document, // the edit list has no document
	No_Node, // the index is past the document's last node
	Fact_Node, // the node is a fact, which takes only fact edits
	Flat_Container, // the node is a flat text's container, whose members take the edit
	Root, // the root is not removed
	Key_Node, // a key is removed with its member and holds no facts
	Not_Fact_Role, // the role is a value's or a key's, not a fact's
	Not_Object, // a member is set in a node that is no object
	Not_Array, // an element is set in a node that is no array
	Not_Loaded, // the node is not loaded in a partial document
	No_Parent, // a path reaches no container to set its last step in
	Not_Scalar, // a flat text holds a scalar, and the value is an array or an object
	Empty_Text, // a flat format cannot tell the empty text from null
	Starts_With_Mark, // the value would start the text with a byte order mark
	Reads_Back_Typed, // the document reads kinds from the text, and the format has no quotes to keep the value a string
	No_Spelling, // the format has no spelling for the value
	Reads_Back_Other, // a committed text reads back as values other than the edits wrote
}

// A value layer error. `at` is the byte `kind` names: the walk's fault byte for `.Walk`, the first byte of the
// repeated key for `.Duplicate_Key`, of the shared node or span for `.Conflicting_Edits`. `inner` is the fault, set for
// `.Walk`, `.Bad_Value` and `.Bad_Result`, whose `inner.at` for the last two is a byte of the recorded text or of the
// commit's output, not of the source. A `.Bad_Index` says why in `reason`.
Document_Error :: struct {
	kind:   Document_Error_Kind,
	reason: Edit_Reason,
	at:     u64,
	inner:  Fault,
}

@(private, rodata)
DOCUMENT_KIND_RULES := [Document_Error_Kind]Rule {
	.None              = {"none", "No error"},
	.Walk              = {"walk", "Input does not parse"},
	.Duplicate_Key     = {"duplicate_key", "Duplicate key"},
	.No_Memory         = {"no_memory", "Out of memory"},
	.Bad_Index         = {"bad_index", "The node takes no such edit"},
	.Bad_Position      = {"bad_position", "Insert position is past the container"},
	.Wrong_Container   = {"wrong_container", "The container takes the other insert form"},
	.Bad_Value         = {"bad_value", "Not one value of the format"},
	.Bad_Fact          = {"bad_fact", "Not a fact of the role's shape"},
	.Bad_Width         = {"bad_width", "The edit would break the table's width"},
	.Bad_Spec          = {"bad_spec", "The commit cannot write that spec"},
	.Conflicting_Edits = {"conflicting_edits", "Edits conflict"},
	.Bad_Result        = {"bad_result", "The edited text does not read"},
	.Frozen            = {"frozen", "The node cannot be edited"},
}

@(private, rodata)
EDIT_REASONS := [Edit_Reason]string {
	.None          = "",
	.No_Document   = "the edit list has no document",
	.No_Node       = "no node has that index",
	.Fact_Node     = "the node is a comment, which takes a fact edit",
	.Flat_Container    = "a flat text's container is edited through its members",
	.Root          = "the root is set, not removed",
	.Key_Node      = "a key is removed with its member and holds no comment",
	.Not_Fact_Role = "the role is no comment's",
	.Not_Object    = "the node is no object",
	.Not_Array     = "the node is no array",
	.Not_Loaded    = "the node is not loaded in this partial document",
	.No_Parent     = "the path reaches no container to set its last step in",
	.Not_Scalar = "a flat text holds a text, a number, true, false or null",
	.Empty_Text     = "a TSV text cannot hold the empty text",
	.Starts_With_Mark       = "the value would start the text with a byte order mark",
	.Reads_Back_Typed  = "a read with kinds inferred would read the value back as a number, true or false, and the format has no quotes",
	.No_Spelling = "the format has no spelling for the value",
	.Reads_Back_Other = "it reads back as values other than the edits wrote",
}

// Writes `prefix` then `code`.
@(private)
write_coded :: proc(w: io.Writer, prefix, code: string) -> io.Error {
	io.write_string(w, prefix) or_return
	_, err := io.write_string(w, code)
	return err
}

// Writes `line:col: message` for `e` in `src`. `.Walk` writes its fault. `.Bad_Value` and `.Bad_Result` name their
// fault and its offset in the recorded text or the commit's output, which is not `src`, and `.Bad_Index` its reason.
// `lines` is as in `render_fault`. Errors from the edit list other than a conflict name no byte, since they describe a
// node, a recorded text or a position rather than a place in `src`.
@(private)
render_document :: proc(w: io.Writer, src: []u8, e: Document_Error, lines: ^Lines = nil) -> io.Error {
	if e.kind == .Walk {
		return render_fault(w, src, e.inner, lines)
	}
	if document_at_byte(e) {
		write_position(w, src, e.at, lines) or_return
	}
	io.write_string(w, DOCUMENT_KIND_RULES[e.kind].message) or_return
	if e.reason != .None {
		io.write_string(w, ": ") or_return
		io.write_string(w, EDIT_REASONS[e.reason]) or_return
	}
	if e.kind == .Frozen {
		if e.inner.rules == nil || int(e.inner.detail) >= len(e.inner.rules.details) {
			return nil
		}
		io.write_string(w, ": ") or_return
		_, err := io.write_string(w, e.inner.rules.details[e.inner.detail].message)
		return err
	}
	if e.inner.kind == .None {
		return nil
	}
	io.write_string(w, ": ") or_return
	io.write_string(w, rule_of(e.inner).message) or_return
	io.write_string(w, " at offset ") or_return
	io.write_u64(w, e.inner.at) or_return
	_, err := io.write_string(w, " of the new text" if e.kind == .Bad_Value else " of the edited text")
	return err
}

// The most bytes of a refused value's text a message shows.
@(private)
SHOWN_TEXT_MAX :: 40

// Writes `text`, cut to `SHOWN_TEXT_MAX` bytes at a character's start with `...` after it.
@(private)
write_shown :: proc(w: io.Writer, text: string) -> io.Error {
	if len(text) <= SHOWN_TEXT_MAX {
		_, err := io.write_string(w, text)
		return err
	}
	io.write_string(w, text[:spell.char_start(text, SHOWN_TEXT_MAX)]) or_return
	_, err := io.write_string(w, "...")
	return err
}

// What a public procedure returns when it fails, nil when it does not. The arms are disjoint by cause: a `Fault` is a
// text that does not read, whichever call found it, and `runtime.Allocator_Error` is an allocation refused. The structs
// hold what is theirs: a refused edit or document call, a refused path, a refused typed read or write as a `Typed_Error`.
// `Typed_Error_Kind` is what the token writer returns once a token.
Error :: union {
	Fault,
	runtime.Allocator_Error,
	Document_Error,
	Path_Error,
	Typed_Error,
	Typed_Error_Kind,
}

// Makes the `Error` of a concrete error: nil for the kind `.None`, the inner `Fault` for `.Walk`, an out of memory
// for `.No_Memory`, a `Fault` for `.Duplicate_Key`, else the struct itself, a `Typed_Refusal` as its `Typed_Error`. A
// struct that is assigned to an `Error` by hand is not nil when its kind is `.None`, so every public procedure returns
// through this one. `edit` says a `Document_Error` is an edit's own refusal, whose `.Duplicate_Key` is a commit's named
// cell that its record holds and no fault of a text.
error_of :: proc{error_of_untyped, error_of_typed}

// Nil is judged in line, so that a call that succeeds does not unpack the struct it was given.
@(private)
error_of_untyped :: #force_inline proc "contextless" (e: $E, edit := false) -> Error {
	when E == Maybe(Fault) {
		if e == nil {
			return nil
		}
	} else {
		if e.kind == .None {
			return nil
		}
	}
	return refusal_of(e, edit)
}

@(private)
@(cold)
refusal_of :: #force_no_inline proc "contextless" (e: $E, edit: bool) -> Error {
	when E == Fault {
		#partial switch e.kind {
		case .None:
			return nil
		case .No_Memory:
			return runtime.Allocator_Error.Out_Of_Memory
		}
		return e
	} else when E == Maybe(Fault) {
		if f, ok := e.?; ok {
			return error_of(f)
		}
		return nil
	} else when E == Document_Error || E == Path_Error {
		#partial switch e.kind {
		case .None:
			return nil
		case .Walk:
			return error_of(e.inner)
		case .No_Memory:
			return runtime.Allocator_Error.Out_Of_Memory
		case .Duplicate_Key:
			if !edit {
				return Fault{at = e.at, kind = .Duplicate_Key}
			}
		}
		return e
	} else {
		#panic("error_of takes a Fault, a Maybe(Fault), a Document_Error, a Path_Error")
	}
}

// `error_of` of a `Typed_Refusal`, whose path is copied to `allocator`: the temp allocator, or a reader's own for a
// record read in a loop.
@(private)
error_of_typed :: #force_inline proc(e: Typed_Refusal, allocator := context.temp_allocator) -> Error {
	if e.kind == .None {
		return nil
	}
	return refusal_of_typed(e, allocator)
}

@(private)
@(cold)
refusal_of_typed :: #force_no_inline proc(e: Typed_Refusal, allocator: runtime.Allocator) -> Error {
	#partial switch e.kind {
	case .Walk:
		return error_of(e.inner)
	case .No_Memory:
		return runtime.Allocator_Error.Out_Of_Memory
	case .Duplicate_Key:
		return Fault{at = e.at, kind = .Duplicate_Key}
	}
	return typed_error_of(e, allocator)
}

// Writes `err`'s code, as `json.literal`, `document.bad_index`, `path.bad_path` or `typed.wrong_kind`. A `Fault`'s is
// its rule's, prefixed by its format when it has one, and an allocation refused is `no_memory`. Nil writes nothing.
write_code :: proc(w: io.Writer, err: Error) -> io.Error {
	switch e in err {
	case Fault:
		return write_fault_code(w, e)
	case runtime.Allocator_Error:
		return write_coded(w, "", KIND_RULES[.No_Memory].code if e == .Out_Of_Memory else "allocator_error")
	case Document_Error:
		return write_coded(w, "document.", DOCUMENT_KIND_RULES[e.kind].code)
	case Path_Error:
		return write_coded(w, "path.", PATH_KIND_RULES[e.kind].code)
	case Typed_Error:
		return write_coded(w, "typed.", TYPED_KIND_RULES[typed_refusal_of(e).kind].code)
	case Typed_Error_Kind:
		return write_coded(w, "typed.", TYPED_KIND_RULES[e].code)
	}
	return nil
}

// Writes the rendered line of `err` in `src`, as `line:col: message`, with `at path` after a typed error's. A
// `Typed_Error_Kind` renders as a `Typed_Refusal` of that kind, and an allocation refused as out of memory. `lines` is as in
// `render_fault`. Nil writes nothing.
render :: proc(w: io.Writer, src: []u8, err: Error, lines: ^Lines = nil) -> io.Error {
	switch e in err {
	case Fault:
		return render_fault(w, src, e, lines)
	case runtime.Allocator_Error:
		if e == .Out_Of_Memory {
			_, werr := io.write_string(w, KIND_RULES[.No_Memory].message)
			return werr
		}
		io.write_string(w, "Allocator error: ") or_return
		_, werr := io.write_string(w, reflect.enum_string(e))
		return werr
	case Document_Error:
		return render_document(w, src, e, lines)
	case Path_Error:
		return render_path(w, src, e, lines)
	case Typed_Error:
		return render_typed(w, src, typed_refusal_of(e), lines)
	case Typed_Error_Kind:
		return render_typed(w, src, Typed_Refusal{kind = e}, lines)
	}
	return nil
}
