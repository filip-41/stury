package lex

import core_pkg "../../../core"
import "../walk"

Scanner :: walk.Scanner
Error :: walk.Scan_Error
Error_Kind :: walk.Error_Kind
KIND_LITERAL :: walk.KIND_LITERAL
Fault :: walk.Fault
Query_Ctx :: walk.Query_Ctx
Check_Level :: walk.Check_Level
Walk_Kind :: walk.Walk_Kind
SCAN_FORCE_SLOW :: core_pkg.SCAN_FORCE_SLOW
hex4 :: core_pkg.hex4

VC_NONE :: walk.VC_NONE
VC_OBJECT :: walk.VC_OBJECT
VC_ARRAY :: walk.VC_ARRAY
VC_STRING :: walk.VC_STRING
VC_LITERAL :: walk.VC_LITERAL
VC_NUMBER :: walk.VC_NUMBER

emit_dom_string :: walk.emit_dom_string
emit_literal :: walk.emit_literal
value_bytes_room :: walk.value_bytes_room
edge_publish :: walk.edge_publish
FIRST_ESC_SATURATED :: walk.FIRST_ESC_SATURATED
