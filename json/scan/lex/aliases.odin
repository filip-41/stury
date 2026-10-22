package lex

import core_pkg "../../../core"

Scanner :: core_pkg.Scanner
Error :: core_pkg.Error
Query_Ctx :: core_pkg.Query_Ctx
Check_Level :: core_pkg.Check_Level
Walk_Kind :: core_pkg.Walk_Kind

VC_NONE :: core_pkg.VC_NONE
VC_OBJECT :: core_pkg.VC_OBJECT
VC_ARRAY :: core_pkg.VC_ARRAY
VC_STRING :: core_pkg.VC_STRING
VC_LITERAL :: core_pkg.VC_LITERAL
VC_NUMBER :: core_pkg.VC_NUMBER

emit_dom_string :: core_pkg.emit_dom_string
emit_literal :: core_pkg.emit_literal
value_bytes_room :: core_pkg.value_bytes_room
edge_publish :: core_pkg.edge_publish
FIRST_ESC_SATURATED :: core_pkg.FIRST_ESC_SATURATED
