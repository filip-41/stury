package scan

// Re-exports the names of `walk` (the package this package's walks run on) and of core, so the files here and
// the packages that import scan use one spelling.

import core_pkg "../../core"
import "walk"
import number "./number"

Edge :: walk.Edge

Strictness :: core_pkg.Strictness
Limits :: walk.Limits
Check_Level :: walk.Check_Level
Error :: walk.Scan_Error
Public_Error :: walk.Public_Error
error_of :: walk.error_of
fault_of :: walk.fault_of
KIND_LITERAL :: walk.KIND_LITERAL
Fault :: walk.Fault
Resolution :: walk.Resolution
Strictness_Axes :: walk.Strictness_Axes
Validity :: walk.Validity
Walk_Kind :: walk.Walk_Kind
Query :: walk.Query
Scan_Query :: walk.Scan_Query
Walk_Fault :: walk.Walk_Fault
Kind :: walk.Kind
Row :: core_pkg.Row
Document :: core_pkg.Document
Node :: walk.Node
NO_NODE :: walk.NO_NODE
VC_NONE :: walk.VC_NONE
VC_OBJECT :: walk.VC_OBJECT
VC_ARRAY :: walk.VC_ARRAY
VC_STRING :: walk.VC_STRING
VC_LITERAL :: walk.VC_LITERAL
VC_NUMBER :: walk.VC_NUMBER
Fact :: core_pkg.Fact
Fact_Place :: core_pkg.Fact_Place
Number :: core_pkg.Number
emit_path :: walk.emit_path
bom_len :: core_pkg.bom_len
Demand_Spec :: walk.Demand_Spec
Field_Value :: walk.Field_Value
Name_Arena :: core_pkg.Name_Arena
Scanner :: walk.Scanner
Query_Ctx :: walk.Query_Ctx
Demand_Pend :: walk.Demand_Pend
Open_Frame :: walk.Open_Frame
Key_Set :: walk.Key_Set
Key_Entry :: walk.Key_Entry
KEY_ESCAPED :: walk.KEY_ESCAPED
MAX_DEPTH :: core_pkg.MAX_DEPTH
DEPTH_CEILING :: walk.DEPTH_CEILING
NO_KEY :: core_pkg.NO_KEY

resolve_under :: walk.resolve_under
is_space :: walk.is_space
skip_space :: walk.skip_space
skip_space_back :: walk.skip_space_back
resolve_queries :: walk.resolve_queries
Resolved_Queries :: walk.Resolved_Queries
stop_capable :: walk.stop_capable
axes_check_level :: walk.axes_check_level
emit_scalar :: walk.emit_scalar
dom_container_close :: walk.dom_container_close
dom_container_open :: walk.dom_container_open
seed_row_cap :: walk.seed_row_cap
note_oom :: walk.note_oom
edge_begin :: walk.edge_begin
edge_publish :: walk.edge_publish
auto_key :: walk.auto_key
demand_value_closed :: walk.demand_value_closed
FIRST_ESC_SATURATED :: walk.FIRST_ESC_SATURATED
auto_arm_root :: walk.auto_arm_root
auto_root_scalar :: walk.auto_root_scalar
auto_member_open :: walk.auto_member_open
auto_frame_open :: walk.auto_frame_open
auto_member_closed :: walk.auto_member_closed
auto_frame_closed :: walk.auto_frame_closed
MAX_ROW_SOURCE :: core_pkg.MAX_ROW_SOURCE
axes_for :: walk.axes_for
str_escaped :: walk.str_escaped
first_escape_offset :: walk.first_escape_offset
number_span :: number.number_span
DIALECT_SPELLED :: number.DIALECT_SPELLED
name_arena_adopt :: core_pkg.name_arena_adopt
row_cache :: core_pkg.row_cache
name_arena_reserve :: core_pkg.name_arena_reserve
name_arena_unreserve :: core_pkg.name_arena_unreserve
