package dsv_tests

import "core:testing"
import core "../../core"
import dsv ".."
import walktest "../../walktest"

// A comment line is the fact of the record after it, or of the root as its foot after the last record. The edits of
// facts are in `edit.odin`.
@(test)
fact_read_lines :: proc(t: ^testing.T) {
	Read :: struct {
		src:     string,
		comment: u8,
		node:    core.Node_Index,
		role:    core.Role,
		body:    string,
	}
	for c in ([]Read{
		{"a,b\n#head\n1,2\n", '#', 4, .Comment, "head"},
		{"a,b\n1,2\n#foot\n", '#', core.ROOT, .Comment_Foot, "foot"},
		{"#top\na,b\n1,2\n", '#', core.ROOT, .Comment, "top"},
		{"a,b\n1,2\n#end", '#', core.ROOT, .Comment_Foot, "end"},
		{"//hello\na,b\n1,2\n", '/', core.ROOT, .Comment, "/hello"},
		{"\xEF\xBB\xBF#c\na,b\n1,2\n", '#', core.ROOT, .Comment, "c"},
	}) {
		doc, err := dsv.build(transmute([]u8)c.src, .Csv, {comment = c.comment})
		defer core.destroy(&doc)
		if !testing.expectf(t, err == nil, "%q: %v", c.src, err) || !walktest.body(t, &doc, c.node, c.role, c.body) {
			return
		}
	}
}
