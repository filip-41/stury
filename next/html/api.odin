package html

import "stury:lib/base/spell"
import "stury:lib/core/markup"
import "stury:lib/core/tape"

// The names an HTML user calls beside the reads, so a caller reading HTML needs no direct `core/tape` import.

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

Fact :: tape.Fact
Fact_Kind :: tape.Fact_Kind
Facts :: tape.Facts

Budget :: tape.Budget
Budget_Kind :: tape.Budget_Kind
Tolerance :: tape.Tolerance
Tolerances :: tape.Tolerances
Pieces :: tape.Pieces
Runner :: tape.Runner
Read_Options :: tape.Read_Options
Duplicates :: tape.Duplicates
Xml_Options :: tape.Xml_Options

Step :: tape.Step
Name :: tape.Name
Index :: tape.Index
All :: tape.All
Slice :: tape.Slice
Grain :: tape.Grain
Demand :: tape.Demand
demand_of :: tape.demand_of

Error :: tape.Error
Fault :: tape.Fault
Fault_Kind :: tape.Fault_Kind
Bad_Option :: tape.Bad_Option
Exceeded :: tape.Exceeded
Piece_Gap :: tape.Piece_Gap
Span_Answer :: tape.Span_Answer
Presence :: tape.Presence
Framing :: tape.Framing
Record :: tape.Record

error_message :: proc "contextless" (buf: []u8, err: Error, src: []u8, spec := Spec.Html) -> string {
	return tape.error_message(buf, err, src, as(spec))
}

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
node_text_read :: tape.node_text_read
node_number :: tape.node_number
text_room :: tape.text_room
key_raw :: tape.key_raw
span_bytes :: tape.span_bytes
facts_of :: tape.facts_of
Number :: spell.Number
Number_Kind :: spell.Number_Kind
Number_Form :: tape.Number_Form
number_form :: tape.number_form
number_exact :: tape.number_exact
text_is_ascii :: tape.text_is_ascii
destroy :: tape.destroy
records_window :: tape.records_window

TEXT_KEY :: markup.TEXT_KEY
content :: markup.content
