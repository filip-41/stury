package json_tests

import json "../.."
import core "../../../core"
import "core:testing"

// Each capability has the signature core declares for every format: one that drifts fails the build.
@(test)
test_capabilities_have_core_signatures :: proc(t: ^testing.T) {
	f := core.Format(json.Read_Opts, json.Records, json.Record, json.Document, json.Request({.Path})) {
		validate         = json.validate,
		records          = json.records,
		next_record      = json.next_record,
		each_record      = json.each_record,
		validate_records = json.validate_records,
		find             = json.find,
		build            = json.build,
		query            = json.query,
		set              = json.set,
		insert           = json.insert,
		remove           = json.remove,
		splice           = json.splice,
		request_init     = json.request_init,
		scan             = json.scan,
		answers          = json.answers,
		route_of         = json.route_of,
	}
	testing.expect(t, f.validate != nil)
}
