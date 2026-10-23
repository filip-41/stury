package walk

// The package below the JSON lexer that every walk in `json/scan` and its lexers run on. It holds the scan
// cursor and its caps, the per-scan query context and its matchers (path automaton, demand), the rows a scan
// writes and their stores, and the typed walk's state. The aliases below give core's names the spelling this
// package's files use.

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

// A union's variant is selected by `arm_of[vc]`, so the scan classes use core's numbering. `true` and `false`
// are the `Bool` class. The walk classifies `null` separately, and it reads `arm_of[0]`.
#assert(VC_OBJECT == int(core_pkg.Value_Class.Object))
#assert(VC_ARRAY == int(core_pkg.Value_Class.Array))
#assert(VC_STRING == int(core_pkg.Value_Class.String))
#assert(VC_LITERAL == int(core_pkg.Value_Class.Bool))
#assert(VC_NUMBER == int(core_pkg.Value_Class.Number))
