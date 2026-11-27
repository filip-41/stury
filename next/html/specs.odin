package html

import "stury:lib/core/tape"

// The grammars HTML5 reads: a whole document (`<!DOCTYPE html>...<html>...`) or a fragment whose context
// defaults to an HTML `body` element.
Spec :: enum u8 {
	Html,
	Fragment,
}

// Options of an HTML read. `budget` sets `depth` (an element or implied wrapper is a level), `nodes`, `memory`,
// and `steps` (containers opened). `format` takes `tape.Xml_Options` (`infer`). Refuses `.Invalid_Utf8`.
Options :: tape.Options

// Central base Format_Id for HTML specs (16..17: Html, Fragment).
@(private)
ID :: tape.FORMAT_ID_HTML

// The facts an HTML document holds.
@(private)
FACTS :: tape.COMMENTS + {.Doctype, .Attribute, .Instruction, .Instruction_Foot}

// Format capabilities: HTML elements depend on tree-construction context, keys group by name, and inputs are UTF-8 text.
CAPS :: tape.Caps{}

@(private, rodata)
FORMATS := [Spec]tape.Format {
	.Html = {
		name      = "html",
		id        = ID,
		facts     = FACTS,
		caps      = CAPS,
		options   = .Xml,
		dups      = .Group,
		refuses   = {.Invalid_Utf8},
		bounds    = bounds,
		decode    = text_decoded,
		number    = number_value,
		same_text = same_text,
		key_hash  = key_hash,
		room      = decode_room_node,
		text_ext  = html_text_ext,
		close_end = close_end,
		attribute = attribute,
		namespace = namespace,
	},
	.Fragment = {
		name      = "html_fragment",
		id        = ID + 1,
		facts     = FACTS,
		caps      = CAPS,
		options   = .Xml,
		dups      = .Group,
		refuses   = {.Invalid_Utf8},
		bounds    = bounds,
		decode    = text_decoded,
		number    = number_value,
		same_text = same_text,
		key_hash  = key_hash,
		room      = decode_room_node,
		text_ext  = fragment_text_ext,
		close_end = close_end,
		attribute = attribute,
		namespace = namespace,
	},
}

// The format handle of `spec`, to pass to generic `tape` helpers. Nil for a `spec` out of range.
as :: proc "contextless" (spec: Spec) -> ^tape.Format {
	return &FORMATS[spec] if spec <= max(Spec) else nil
}

// The reads of `spec`, for a caller that picks the format at run time, to use with `as`. Nil for a `spec` out of range.
reads :: proc "contextless" (spec: Spec) -> ^tape.Reads {
	return tape.format_reads(Spec, ID, validate, build, find, scan, Records, records_open, records_validate, records_find, records_scan) if spec <= max(Spec) else nil
}
