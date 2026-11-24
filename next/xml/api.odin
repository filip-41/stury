package xml

import "stury:lib/base/spell"
import "stury:lib/core/markup"
import "stury:lib/core/tape"

// The names an XML user calls beside the reads, so that a program reading XML imports this package alone. The rest of
// `lib/core/tape` serves walks and hooks.

// A document and the place of a node in it.
Document :: tape.Document
Doc_Flag :: tape.Doc_Flag
Doc_Flags :: tape.Doc_Flags
Node :: tape.Node
Node_Index :: tape.Node_Index
Kind :: tape.Kind
ROOT :: tape.ROOT
NO_NODE :: tape.NO_NODE
Format :: tape.Format
Reads :: tape.Reads

// The comments, instructions, declarations and attributes of a document, as facts on its nodes.
Fact :: tape.Fact
Fact_Kind :: tape.Fact_Kind
Facts :: tape.Facts

// What a read takes beside the text.
Budget :: tape.Budget
Budget_Kind :: tape.Budget_Kind
Tolerance :: tape.Tolerance
Tolerances :: tape.Tolerances
Read_Options :: tape.Read_Options
Duplicates :: tape.Duplicates
Xml_Options :: tape.Xml_Options

// Paths and the demand of a scan.
Step :: tape.Step
Name :: tape.Name
Index :: tape.Index
All :: tape.All
Slice :: tape.Slice
Grain :: tape.Grain
Demand :: tape.Demand
demand_of :: tape.demand_of

// What a read gives back.
Error :: tape.Error
Fault :: tape.Fault
Fault_Kind :: tape.Fault_Kind
Bad_Option :: tape.Bad_Option
Exceeded :: tape.Exceeded
Span_Answer :: tape.Span_Answer
Presence :: tape.Presence
Framing :: tape.Framing
Record :: tape.Record

// Writes the message of `err`, an error of a read of `src`, into `buf` and returns it, led by its line and column.
error_message :: proc "contextless" (buf: []u8, err: Error, src: []u8) -> string {
	return tape.error_message(buf, err, src, as(.Xml))
}

// The readers over a document, or over the text a `find` answer or a record's key was read in.
Reader :: tape.Reader
Doc_Index :: tape.Doc_Index
Children :: tape.Children
root :: tape.root
answer :: tape.answer
member :: tape.member
element :: tape.element
length :: tape.length
children :: tape.children
next_child :: tape.next_child
named :: tape.named
answer_node :: tape.answer_node
node_text :: tape.node_text
node_number :: tape.node_number
text_room :: tape.text_room
key_raw :: tape.key_raw
span_bytes :: tape.span_bytes
Number :: spell.Number
Number_Kind :: spell.Number_Kind
Number_Form :: tape.Number_Form
number_form :: tape.number_form
number_exact :: tape.number_exact
text_is_ascii :: tape.text_is_ascii
destroy :: tape.destroy

// The markup shape's readers: the name of a text member, and an element's string value. `attribute` and
// `namespace` read an element's attributes and the namespace of its name.
TEXT_KEY :: markup.TEXT_KEY
content :: markup.content
