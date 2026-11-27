package msgpack

import "stury:lib/base/spell"
import "stury:lib/core/tape"
import "stury:lib/ops/build"

// Re-exports of `tape` types and readers so MessagePack callers import `stury:msgpack` alone.

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
fact_number :: tape.fact_number
fact_name :: tape.fact_name

Budget :: tape.Budget
Budget_Kind :: tape.Budget_Kind
Tolerance :: tape.Tolerance
Tolerances :: tape.Tolerances
Pieces :: tape.Pieces
Runner :: tape.Runner
Read_Options :: tape.Read_Options
Duplicates :: tape.Duplicates

Step :: tape.Step
Name :: tape.Name
Index :: tape.Index
All :: tape.All
Slice :: tape.Slice
Descend :: tape.Descend
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

// Writes a human-readable message for `err` using byte offsets (as MessagePack has no line numbers).
error_message :: proc "contextless" (buf: []u8, err: Error, src: []u8) -> string {
	return tape.error_message(buf, err, src, as(.Msgpack))
}

Reader :: tape.Reader
Doc_Index :: tape.Doc_Index
Children :: tape.Children
root :: tape.root
answer :: tape.answer
query :: build.query
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
clone_document :: tape.clone_document
records_window :: tape.records_window
