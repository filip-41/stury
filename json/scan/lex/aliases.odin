package lex

import c "../../../core"

Scanner :: c.Scanner
Error :: c.Error
Query_Ctx :: c.Query_Ctx
Check_Level :: c.Check_Level
Walk_Kind :: c.Walk_Kind

VC_NONE :: c.VC_NONE
VC_OBJECT :: c.VC_OBJECT
VC_ARRAY :: c.VC_ARRAY
VC_STRING :: c.VC_STRING
VC_LITERAL :: c.VC_LITERAL
VC_NUMBER :: c.VC_NUMBER

emit_dom_string :: c.emit_dom_string
emit_literal :: c.emit_literal
value_bytes_room :: c.value_bytes_room
edge_publish :: c.edge_publish
FIRST_ESC_SATURATED :: c.FIRST_ESC_SATURATED
