package scan

// Re-exports core's names (the substrate this package's walks run on) so the files here and the packages that
// import scan use one spelling.

import c "../../core"
import number "./number"

Edge :: c.Edge

Strictness :: c.Strictness
Limits :: c.Limits
Check_Level :: c.Check_Level
Error :: c.Error
Resolution :: c.Resolution
Strictness_Axes :: c.Strictness_Axes
Validity :: c.Validity
Walk_Kind :: c.Walk_Kind
Query :: c.Query
Scan_Query :: c.Scan_Query
Walk_Fault :: c.Walk_Fault
Kind :: c.Kind
Row :: c.Row
Node :: c.Node
NO_NODE :: c.NO_NODE
VC_NONE :: c.VC_NONE
VC_OBJECT :: c.VC_OBJECT
VC_ARRAY :: c.VC_ARRAY
VC_STRING :: c.VC_STRING
VC_LITERAL :: c.VC_LITERAL
VC_NUMBER :: c.VC_NUMBER
Fact :: c.Fact
Fact_Place :: c.Fact_Place
Number :: c.Number
emit_path :: c.emit_path
Demand_Spec :: c.Demand_Spec
Field_Value :: c.Field_Value
Name_Arena :: c.Name_Arena
Scanner :: c.Scanner
Query_Ctx :: c.Query_Ctx
Demand_Pend :: c.Demand_Pend
Open_Frame :: c.Open_Frame
Key_Set :: c.Key_Set
Key_Entry :: c.Key_Entry
KEY_ESCAPED :: c.KEY_ESCAPED
MAX_DEPTH :: c.MAX_DEPTH
DEPTH_CEILING :: c.DEPTH_CEILING
NO_KEY :: c.NO_KEY

resolve_under :: c.resolve_under
resolve_queries :: c.resolve_queries
Resolved_Queries :: c.Resolved_Queries
stop_capable :: c.stop_capable
axes_check_level :: c.axes_check_level
emit_scalar :: c.emit_scalar
dom_container_close :: c.dom_container_close
dom_container_open :: c.dom_container_open
seed_row_cap :: c.seed_row_cap
note_oom :: c.note_oom
edge_begin :: c.edge_begin
edge_publish :: c.edge_publish
auto_key :: c.auto_key
demand_value_closed :: c.demand_value_closed
FIRST_ESC_SATURATED :: c.FIRST_ESC_SATURATED
auto_arm_root :: c.auto_arm_root
auto_root_scalar :: c.auto_root_scalar
auto_member_open :: c.auto_member_open
auto_frame_open :: c.auto_frame_open
auto_member_closed :: c.auto_member_closed
auto_frame_closed :: c.auto_frame_closed
TAPE_MAX_SOURCE :: c.TAPE_MAX_SOURCE
axes_for :: c.axes_for
str_escaped :: c.str_escaped
first_escape_offset :: c.first_escape_offset
number_span :: number.number_span
name_arena_adopt :: c.name_arena_adopt
name_arena_reserve :: c.name_arena_reserve
name_arena_unreserve :: c.name_arena_unreserve
