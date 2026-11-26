package yaml

import "stury:lib/core/tape"

// The services of the YAML specs beyond the node readers: `reads` returns the runtime read table for a caller picking
// the spec via its handle.
reads :: proc "contextless" (spec: Spec) -> ^tape.Reads {
	return tape.format_reads(Spec, ID, validate, build, find, scan, Records, records_open, records_validate, records_find, records_scan) if spec <= max(Spec) else nil
}
