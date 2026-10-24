package number

import core_pkg "../../../core"
import "../walk"

Scanner :: walk.Scanner
Error :: core_pkg.Error
Query_Ctx :: walk.Query_Ctx
Walk_Kind :: walk.Walk_Kind
Exactness :: core_pkg.Exactness
Number :: core_pkg.Number

// What a reader answers for a token with no binary64 value, since the zero `Number` is the exact 0.
NO_NUMBER :: Number{exactness = .None}

Number_Spelling :: walk.Number_Spelling

emit_number :: walk.emit_number
number_digits_pack :: walk.number_digits_pack
Row_Flags :: walk.Row_Flags
