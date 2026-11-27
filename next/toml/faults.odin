package toml

import "stury:lib/core/hook"
import "stury:lib/core/tape"

// TOML's detail of a fault, in `tape.Fault.detail`.
@(private)
Detail :: enum u8 {
	None,
	Cut_Utf8, // `Truncated`: the text ends inside a UTF-8 sequence
	Invalid_Utf8, // `Bad_Char`: at the lead byte of an ill-formed sequence
	Control_Char, // `Bad_Char`: a control character other than a tab in a string or comment
	Lone_Cr, // `Bad_Char`: a carriage return no line feed follows
	Open_String, // `Truncated`: a string the text never closes
	Line_End_In_String, // `Bad_Char`: a line end inside a string on one line
	Bad_Quotes, // `Bad_Char`: more than two quotes before the close of a multi-line string
	Bad_Codepoint, // `Bad_Escape`: an escape of a surrogate or a value past U+10FFFF
	Leading_Zero, // `Bad_Number`: a zero before more digits
	Bad_Underscore, // `Bad_Number`: an underscore not between two digits
	Out_Of_Range, // `Bad_Number`: an integer outside 64 bits
	Bad_Datetime, // `Bad_Char`: a date or time of a field out of range or a missing part
	Expected_Key, // `Bad_Char`: a key was expected
	Expected_Equals, // `Bad_Char`: `=` was expected after a key
	Expected_Value, // `Bad_Char`: a value was expected
	Expected_Line_End, // `Bad_Char`: text after a statement
	After_Value, // `Bad_Char`: text right after a value
	Expected_Comma, // `Bad_Char`: a comma or the close of an array or inline table
	Expected_Close, // `Bad_Char`: a closing bracket was expected
	Trailing_Comma, // `Bad_Char`: a comma before the close of an inline table, which 1.0 refuses
	Redefined_Table, // `Bad_Char`: a table defined twice, or a header over a table a dotted key made
	Duplicate_Key, // `Bad_Char`: a key written twice
	Extends_Inline, // `Bad_Char`: a key or header into an inline table
	Extends_Array, // `Bad_Char`: a header into an array that no header made
	Not_Table, // `Bad_Char`: a header through a value that is no table
}

// TOML's `tape.Rules`, one rule per `Detail` in its order, which names the format whatever the spec.
@(private, rodata)
RULES := tape.Rules{"toml", {
	{},
	{"cut_utf8", "Unfinished UTF-8 sequence"},
	{"invalid_utf8", "Invalid UTF-8"},
	{"control_char", "Control character"},
	{"lone_cr", "Carriage return not before a line feed"},
	{"open_string", "Unfinished string"},
	{"line_end_in_string", "Line end inside a string"},
	{"bad_quotes", "Too many quotes before the end of a multi-line string"},
	{"bad_codepoint", "Escape of a value that is no Unicode scalar"},
	{"leading_zero", "Leading zero in a number"},
	{"bad_underscore", "Underscore not between two digits"},
	{"out_of_range", "Integer does not fit 64 bits"},
	{"bad_datetime", "Invalid date or time"},
	{"expected_key", "Expected a key"},
	{"expected_equals", "Expected ="},
	{"expected_value", "Expected a value"},
	{"expected_line_end", "Expected the end of the line"},
	{"after_value", "Unexpected text after a value"},
	{"expected_comma", "Expected a comma or a close"},
	{"expected_close", "Expected a closing bracket"},
	{"trailing_comma", "Trailing comma in an inline table"},
	{"redefined_table", "Table defined twice"},
	{"duplicate_key", "Key defined twice"},
	{"extends_inline", "Inline table cannot be extended"},
	{"extends_array", "Array cannot be extended by a header"},
	{"not_table", "Header through a value that is no table"},
}}

// A scanner's verdict on what it read, a walk result: 0 for none, else the fault.
@(private)
Verdict :: hook.Walk_Result

@(private)
bad :: #force_inline proc "contextless" (at: int, kind: tape.Fault_Kind, detail: Detail) -> Verdict {
	return hook.walk_result(u64(at), u8(kind), u8(detail))
}
