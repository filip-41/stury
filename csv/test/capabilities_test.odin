package csv_tests

import "core:testing"
import core "../../core"
import csv "../"

// Each capability has the signature core declares for every format: one that drifts fails the build.
@(test)
test_capabilities_have_core_signatures :: proc(t: ^testing.T) {
	f := core.Format(csv.Read_Opts, csv.Records, csv.Record, csv.Document, csv.Request) {
		validate         = csv.validate,
		records          = csv.records,
		next_record      = csv.next_record,
		each_record      = csv.each_record,
		validate_records = csv.validate_records,
		find             = csv.find,
		build            = csv.build,
		query            = csv.query,
		set              = csv.set,
		insert           = csv.insert,
		remove           = csv.remove,
		splice           = csv.splice,
		request_init     = csv.request_init,
		scan             = csv.scan,
		answers          = csv.answers,
		route_of         = csv.route_of,
	}
	testing.expect(t, f.validate != nil)
}
