package json_tests

// `json.Record_Fault` is `core`'s type, so a caller using several formats writes one fault type and one list.

import "core:testing"
import core "../../../core"
import json "../.."

@(test)
test_record_fault_is_cores :: proc(t: ^testing.T) {
	faults, err := json.validate_records(transmute([]byte)string("1\nx\n"), {framing = .NDJSON})
	defer delete(faults)
	testing.expect(t, err == nil && len(faults) == 1)
	// The record's fault is core's without a conversion, which only an alias allows.
	fault: core.Record_Fault = faults[0]
	testing.expect_value(t, fault.lo, 2)
	testing.expect_value(t, fault.hi, 3)
	testing.expect_value(t, fault.err, core.Error{kind = .Bad_Char, offset = 2})
	// And core's fault is json's again.
	faults[0] = fault
}
