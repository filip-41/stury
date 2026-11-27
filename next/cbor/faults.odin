package cbor

import "stury:lib/core/tape"

// CBOR's detail of a fault's kind, in `tape.Fault.detail`.
@(private)
Detail :: enum u8 {
	None,
	Reserved_Info, // `Bad_Char`: additional information 28 to 30, or 31 on an item that cannot be indefinite
	Bad_Simple, // `Bad_Char`: the two-byte simple value `f8` with a value below 32
	Bad_Break, // `Bad_Char`: a break outside an indefinite item, or where a map's value is due
	Bad_Chunk, // `Bad_Char`: a chunk of an indefinite string that is not a definite string of its major type
	Invalid_Utf8, // `Bad_Char`: a text string that is not UTF-8
	Bad_Key, // `Bad_Char`: a map key that is not an integer, a text string or a byte string
	Bad_Tag_Content, // `Bad_Char`: the content of a tag whose meaning the content does not fit
	Count_Too_Large, // `Truncated`: a count that the bytes left cannot hold, at its head
	Trailing, // `Bad_Char`: bytes after the item
	No_Item, // `Truncated`: no item
	Not_Preferred, // `Bad_Char`: an item not in preferred serialization
	Key_Order, // `Bad_Char`: a key that does not follow the one before it
	Bad_Nan, // `Bad_Char`: a NaN other than `f97e00`
}

// CBOR's `tape.Rules`, one rule per `Detail` in its order.
@(private, rodata)
RULES := tape.Rules{"cbor", {
	{},
	{"reserved_info", "Reserved additional information"},
	{"bad_simple", "Two-byte simple value below 32"},
	{"bad_break", "Break outside an indefinite item"},
	{"bad_chunk", "Chunk of an indefinite string is no definite string of its type"},
	{"invalid_utf8", "Text string is not UTF-8"},
	{"bad_key", "Map key is no integer, text string or byte string"},
	{"bad_tag_content", "Tag content does not fit the tag"},
	{"count_too_large", "Count larger than the bytes left"},
	{"trailing", "Bytes after the item"},
	{"no_item", "No data item"},
	{"not_preferred", "Item is not in preferred serialization"},
	{"key_order", "Map key out of order"},
	{"bad_nan", "NaN other than f97e00"},
}}

