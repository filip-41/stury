package number

import core_pkg "../../../core"
import "../walk"

Scanner :: walk.Scanner
Error :: core_pkg.Error
Query_Ctx :: walk.Query_Ctx
Walk_Kind :: walk.Walk_Kind
Number :: core_pkg.Number
NO_NUMBER :: core_pkg.NO_NUMBER

emit_number :: walk.emit_number
number_digits_pack :: walk.number_digits_pack

// core's number decode, by the names this package's lexer and row readers use.
EXP_SATURATED :: core_pkg.EXP_SATURATED
digit_run :: core_pkg.digit_run
digit8_gap :: core_pkg.digit8_gap
load8_le :: core_pkg.load8_le
digits8_value :: core_pkg.digits8_value
dom_exact_scale :: core_pkg.dom_exact_scale
lex_number_span :: core_pkg.lex_number_span
lex_number_value :: core_pkg.lex_number_value
number_span :: core_pkg.number_span
