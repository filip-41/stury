package dsv

import "stury:lib/base/spell"
import "stury:lib/core/tape"

// Names of `lib/core/tape` re-exported so that a program reading delimited text imports this package alone. The rest of
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

// The comment lines of a document, as facts on its nodes.
Fact :: tape.Fact
Fact_Kind :: tape.Fact_Kind
Facts :: tape.Facts

// Types of a read's options.
Budget :: tape.Budget
Budget_Kind :: tape.Budget_Kind
Tolerance :: tape.Tolerance
Tolerances :: tape.Tolerances
Pieces :: tape.Pieces
Runner :: tape.Runner
Read_Options :: tape.Read_Options
Duplicates :: tape.Duplicates

// Paths and the demand of a scan.
Step :: tape.Step
Name :: tape.Name
Index :: tape.Index
All :: tape.All
Slice :: tape.Slice
Grain :: tape.Grain
Demand :: tape.Demand
demand_of :: tape.demand_of

// Results and errors of a read.
Error :: tape.Error
Fault :: tape.Fault
Fault_Kind :: tape.Fault_Kind
Exceeded :: tape.Exceeded
Piece_Gap :: tape.Piece_Gap
Bad_Option :: tape.Bad_Option
Span_Answer :: tape.Span_Answer
Presence :: tape.Presence
Framing :: tape.Framing
Record :: tape.Record
error_message :: tape.error_message

// Readers over a document, or over the text a `find` answer or a record's key was read in.
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
