package tape_test

import "base:runtime"
import "core:testing"
import "stury:lib/core/tape"
import "stury:testkit"

// The entries of every list a `Document` and its `Partial` hold are offsets, indexes and plain values, with no address,
// so a document's lists can be written to a file and read back.
@(test)
document_entries_hold_no_address :: proc(t: ^testing.T) {
	testkit.deadline(t)
	for holder in ([]^runtime.Type_Info{type_info_of(tape.Document), type_info_of(tape.Partial)}) {
		s := runtime.type_info_base(holder).variant.(^runtime.Type_Info_Struct)
		for i in 0 ..< s.field_count {
			if list, ok := runtime.type_info_base(s.types[i]).variant.(^runtime.Type_Info_Slice); ok {
				testing.expectf(t, holds_no_address(list.elem), "%v.%s holds an address", holder, s.names[i])
			}
		}
	}
}

// Whether a value of `info` holds no pointer, slice, string, map, procedure or other address.
@(private = "file")
holds_no_address :: proc(info: ^runtime.Type_Info) -> bool {
	#partial switch v in runtime.type_info_base(info).variant {
	case ^runtime.Type_Info_Struct:
		for i in 0 ..< v.field_count {
			if !holds_no_address(v.types[i]) {
				return false
			}
		}
		return true
	case ^runtime.Type_Info_Array:
		return holds_no_address(v.elem)
	case ^runtime.Type_Info_Enumerated_Array:
		return holds_no_address(v.elem)
	case ^runtime.Type_Info_Integer, ^runtime.Type_Info_Float, ^runtime.Type_Info_Boolean, ^runtime.Type_Info_Rune, ^runtime.Type_Info_Enum, ^runtime.Type_Info_Bit_Set, ^runtime.Type_Info_Bit_Field:
		return true
	}
	return false
}

// Layout sizes, which change only on purpose.
@(test)
layout_sizes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	testing.expect_value(t, size_of(tape.Token), 16)
	testing.expect_value(t, size_of(tape.Fact), 24)
	testing.expect_value(t, size_of(tape.Table), 28)
	when size_of(uintptr) == 8 {
		testing.expect_value(t, size_of(tape.Document), 128)
	}
}
