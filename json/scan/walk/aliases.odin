package walk

// The package below the JSON lexer that every walk in `json/scan` and its lexers run on. It holds the scan
// cursor and its caps, the per-scan query context and its matchers (path automaton, demand), the rows a scan
// writes and their stores, and the typed walk's state. The aliases below give core's names the spelling this
// package's files use.

import core_pkg "../../../core"

Error :: Scan_Error
Public_Error :: core_pkg.Error
Error_Kind :: core_pkg.Error_Kind
Strictness :: core_pkg.Strictness
MAX_DEPTH :: core_pkg.MAX_DEPTH
Step :: core_pkg.Step
Name :: core_pkg.Name
Index :: core_pkg.Index
Any :: core_pkg.Any
Path :: core_pkg.Path
// A path the automaton serves has at most `MAX_PATH_STEPS` steps; a longer one is refused before the walk
// (`Over_Capacity`, `Path_Steps`). The negative-`Index` re-entry nests one frame array per step, so the cap
// bounds stack use.
MAX_PATH_STEPS :: core_pkg.MAX_PATH_STEPS
Read_Shape :: core_pkg.Read_Shape
Shape_Op :: core_pkg.Shape_Op
Shape_Field :: core_pkg.Shape_Field
Shape_Fault :: core_pkg.Shape_Fault
Row :: core_pkg.Row
Row_Flags :: core_pkg.Row_Flags
Row_Str :: core_pkg.Row_Str
Key_Text :: core_pkg.Key_Text
Row_Payload :: core_pkg.Row_Payload
NO_KEY :: core_pkg.NO_KEY
MAX_ROW_SOURCE :: core_pkg.MAX_ROW_SOURCE
Fact :: core_pkg.Fact
adopt_allocator :: core_pkg.adopt_allocator
NAME_BLOCK_BYTES :: core_pkg.NAME_BLOCK_BYTES
name_arena_reset :: core_pkg.name_arena_reset
allocator_ok :: core_pkg.allocator_ok

Shape_Run :: core_pkg.Shape_Run
Shape_Frame :: core_pkg.Shape_Frame
Shape_Number :: core_pkg.Shape_Number
SHAPE_WIDE_WORDS :: core_pkg.SHAPE_WIDE_WORDS
TYPED_FAULT :: core_pkg.TYPED_FAULT
