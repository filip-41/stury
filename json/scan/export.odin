package scan

// Re-exports core's names (the substrate this package's walks run on) so the files here and the packages that
// import scan use one spelling.

import core_pkg "../../core"
import number "./number"

Edge :: core_pkg.Edge

Strictness :: core_pkg.Strictness
Limits :: core_pkg.Limits
Check_Level :: core_pkg.Check_Level
Error :: core_pkg.Error
Resolution :: core_pkg.Resolution
Strictness_Axes :: core_pkg.Strictness_Axes
Validity :: core_pkg.Validity
Walk_Kind :: core_pkg.Walk_Kind
Query :: core_pkg.Query
Scan_Query :: core_pkg.Scan_Query
Walk_Fault :: core_pkg.Walk_Fault
Kind :: core_pkg.Kind
Row :: core_pkg.Row
Node :: core_pkg.Node
NO_NODE :: core_pkg.NO_NODE
VC_NONE :: core_pkg.VC_NONE
VC_OBJECT :: core_pkg.VC_OBJECT
VC_ARRAY :: core_pkg.VC_ARRAY
VC_STRING :: core_pkg.VC_STRING
VC_LITERAL :: core_pkg.VC_LITERAL
VC_NUMBER :: core_pkg.VC_NUMBER
Fact :: core_pkg.Fact
Fact_Place :: core_pkg.Fact_Place
Number :: core_pkg.Number
emit_path :: core_pkg.emit_path
Demand_Spec :: core_pkg.Demand_Spec
Field_Value :: core_pkg.Field_Value
Name_Arena :: core_pkg.Name_Arena
Scanner :: core_pkg.Scanner
Query_Ctx :: core_pkg.Query_Ctx
Demand_Pend :: core_pkg.Demand_Pend
Open_Frame :: core_pkg.Open_Frame
Key_Set :: core_pkg.Key_Set
Key_Entry :: core_pkg.Key_Entry
KEY_ESCAPED :: core_pkg.KEY_ESCAPED
MAX_DEPTH :: core_pkg.MAX_DEPTH
DEPTH_CEILING :: core_pkg.DEPTH_CEILING
NO_KEY :: core_pkg.NO_KEY

resolve_under :: core_pkg.resolve_under
resolve_queries :: core_pkg.resolve_queries
Resolved_Queries :: core_pkg.Resolved_Queries
stop_capable :: core_pkg.stop_capable
axes_check_level :: core_pkg.axes_check_level
emit_scalar :: core_pkg.emit_scalar
dom_container_close :: core_pkg.dom_container_close
dom_container_open :: core_pkg.dom_container_open
seed_row_cap :: core_pkg.seed_row_cap
note_oom :: core_pkg.note_oom
edge_begin :: core_pkg.edge_begin
edge_publish :: core_pkg.edge_publish
auto_key :: core_pkg.auto_key
demand_value_closed :: core_pkg.demand_value_closed
FIRST_ESC_SATURATED :: core_pkg.FIRST_ESC_SATURATED
auto_arm_root :: core_pkg.auto_arm_root
auto_root_scalar :: core_pkg.auto_root_scalar
auto_member_open :: core_pkg.auto_member_open
auto_frame_open :: core_pkg.auto_frame_open
auto_member_closed :: core_pkg.auto_member_closed
auto_frame_closed :: core_pkg.auto_frame_closed
TAPE_MAX_SOURCE :: core_pkg.TAPE_MAX_SOURCE
axes_for :: core_pkg.axes_for
str_escaped :: core_pkg.str_escaped
first_escape_offset :: core_pkg.first_escape_offset
number_span :: number.number_span
name_arena_adopt :: core_pkg.name_arena_adopt
name_arena_reserve :: core_pkg.name_arena_reserve
name_arena_unreserve :: core_pkg.name_arena_unreserve
