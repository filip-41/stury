package walk

// The JSON walk's substrate, below the lexer: the scan cursor and its caps, the per-scan query context and
// the matchers it carries (path automaton, demand), the rows a scan writes and the stores behind them, and the
// typed walk's state. Every walk in `json/scan` and its lexers run on it. The aliases are core's names, in the
// spelling the files of this package use.

import core_pkg "../../../core"

Error :: core_pkg.Error
Error_Kind :: core_pkg.Error_Kind
Strictness :: core_pkg.Strictness
Step :: core_pkg.Step
Name :: core_pkg.Name
Index :: core_pkg.Index
Any :: core_pkg.Any
Path :: core_pkg.Path
MAX_PATH_STEPS :: core_pkg.MAX_PATH_STEPS
Read_Shape :: core_pkg.Read_Shape
Shape_Op :: core_pkg.Shape_Op
Shape_Field :: core_pkg.Shape_Field
Shape_Fault :: core_pkg.Shape_Fault

// A union's arm is picked by `arm_of[vc]`, so the scan classes number core's: `true` and `false` are the
// `Bool` class, and `null`, which the walk tells apart from them, reads `arm_of[0]`.
#assert(VC_OBJECT == int(core_pkg.Value_Class.Object))
#assert(VC_ARRAY == int(core_pkg.Value_Class.Array))
#assert(VC_STRING == int(core_pkg.Value_Class.String))
#assert(VC_LITERAL == int(core_pkg.Value_Class.Bool))
#assert(VC_NUMBER == int(core_pkg.Value_Class.Number))
