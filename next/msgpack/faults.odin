package msgpack

import "stury:lib/core/tape"

// MessagePack's detail of a fault's kind, in `tape.Fault.detail`.
@(private)
Detail :: enum u8 {
	None,
	Reserved_Type,   // `Bad_Char`: never-used format byte 0xc1
	Invalid_Utf8,    // `Bad_Char`: a string that is not valid UTF-8
	Bad_Key,         // `Bad_Char`: a map key that is not an integer, text string, or byte string
	Bad_Timestamp,   // `Bad_Char`: a timestamp ext (-1) with invalid payload length or nanoseconds >= 10^9
	Count_Too_Large, // `Truncated`: a container count that the remaining bytes cannot hold, at its head
	Trailing,        // `Bad_Char`: trailing bytes after the item
	No_Item,         // `Truncated`: empty input with no item
	Not_Preferred,   // `Bad_Char`: an item not in compact (shortest) representation
}

// MessagePack's `tape.Rules`, one rule per `Detail` in its order.
@(private, rodata)
RULES := tape.Rules{"msgpack", {
	{},
	{"reserved_type", "Never-used MessagePack format byte 0xc1"},
	{"invalid_utf8", "String is not valid UTF-8"},
	{"bad_key", "Map key is not an integer, string, or binary"},
	{"bad_timestamp", "Invalid MessagePack timestamp payload"},
	{"count_too_large", "Container count larger than remaining bytes"},
	{"trailing", "Trailing bytes after the item"},
	{"no_item", "No data item"},
	{"not_preferred", "Item is not in compact encoding"},
}}
