package dsv

import "stury:lib/core/tape"

// A delimited text's detail of a fault, in `tape.Fault.detail`.
@(private)
Detail :: enum u8 {
	None,
	Too_Many, // `Bad_Width`: a record wider than the first, at the delimiter that starts its extra cell
	Too_Few, // `Bad_Width`: a record narrower than the first, at its line end
	Bare_Quote, // `Bad_Char`: a quote inside an unquoted CSV cell
	Invalid_Utf8, // `Bad_Char`: at the lead byte of an ill-formed sequence
	Lone_Cr, // `Bad_Char`: a CR with no LF after it
	After_Quote, // `Bad_Char`: a byte after a closing quote that is not a quote, the delimiter or a line end
	Open_Quote, // `Truncated`: at the opening quote of a quoted cell the text never closes
	Cut_Utf8, // `Truncated`: at the text's end, inside a UTF-8 sequence
}

// A delimited text's `tape.Rules`, one rule per `Detail` in its order, named for the family whichever spec read the text.
@(private, rodata)
RULES := tape.Rules{"dsv", {
	{},
	{"too_many_fields", "Record has more fields than the first record"},
	{"too_few_fields", "Record has fewer fields than the first record"},
	{"bare_quote", "Quote inside an unquoted field"},
	{"invalid_utf8", "Invalid UTF-8"},
	{"lone_cr", "Carriage return not before a line feed"},
	{"after_quote", "Character after a closing quote"},
	{"open_quote", "Unfinished quoted field"},
	{"cut_utf8", "Unfinished UTF-8 sequence"},
}}
