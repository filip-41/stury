// The order of values.
package core_test

import "core:math"
import "core:testing"
import core ".."
import dsv "../../dsv"
import testkit "../../testkit"

// A nan double is below a cell read as a number, whichever side the cell is on.
@(test)
nan_is_below_a_cell_read_as_a_number :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	context.allocator = context.temp_allocator
	doc, err := core.build(transmute([]u8)string("a\n7\n"), dsv.as(.Csv))
	defer core.destroy(&doc)
	testkit.expect_nil(t, err)
	row, _ := core.child_at(&doc, core.ROOT, 0)
	cell, _ := core.child_at(&doc, row, 0)
	nan, seven := core.Value(math.nan_f64()), core.Value(core.Node_Ref{&doc, cell})
	testing.expect_value(t, core.compare(nan, seven, read_plain = true), -1)
	testing.expect_value(t, core.compare(seven, nan, read_plain = true), 1)
}
