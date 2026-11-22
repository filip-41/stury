// Exports a build and a format handle for one constant spec, which `tools/deadstrip_check.py` measures. A program
// whose only read is a build of one spec must link that spec's walk and no read of another entry point.
package deadstrip

import "stury:json"
import "stury:lib/core/tape"

@(export)
build :: proc(p: [^]u8, n: int) -> int {
	doc, err := json.build(p[:n], .Json)
	if err != nil {
		return -1
	}
	defer tape.destroy(&doc)
	return len(doc.nodes)
}

@(export)
handle :: proc() -> ^tape.Format {
	return json.as(.Json)
}
