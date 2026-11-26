package query_test

import "core:testing"
import "stury:lib/query"
import "stury:testkit"

// Trailing `.` and trailing/leading single `:` are refused both as standalone IP addresses and as CIDR networks, while
// valid RFC 4291 `::` endpoints remain accepted.
@(test)
ip_valid_and_cidr_refuse_trailing_dot_and_colon :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	bad_addrs := [?]string{
		"1.2.3.4.",
		"1.2.3.",
		"::ffff:1.2.3.4.",
		"::1.2.3.",
		"::1.",
		"1:2:3:4:5:6:7:8.",
		".",
		"1.2.3.4:",
		"::1:",
		"1::2:",
		"1:2:3:4:5:6:7:8:",
		"1:2:3:4:5:6:7:",
		"1:2:3:4:5:6:1.2.3.4:",
		":1::",
		":1:2:3:4:5:6:7",
		":",
		":::",
		"1:::",
		":::1",
	}
	for s in bad_addrs {
		testing.expectf(t, !query.ip_valid(query.text_borrowed(s)), "expected invalid: %q", s)
		_, cs := query.ip_canonical(h, query.text_borrowed(s))
		testing.expectf(t, cs == .Error, "expected canonical error for %q", s)
		query.clear_error(h)
	}

	bad_cidrs := [?]string{
		"10.0.0.0./8",
		"10.0.0./8",
		"10.0.0.0:/8",
		"::1:/128",
		"1::2:/64",
		"1:2:3:4:5:6:7:8:/128",
		":1::/64",
		":::/0",
	}
	for cidr in bad_cidrs {
		_, st := query.ip_in_cidr(h, query.text_borrowed("::1"), query.text_borrowed(cidr))
		testing.expectf(t, st == .Error && h.err.detail == "is not a CIDR network", "cidr %q: status=%v detail=%q", cidr, st, h.err.detail)
		query.clear_error(h)
	}

	for ok_addr in ([?]string{"::", "2001:db8::", "::1"}) {
		testing.expectf(t, query.ip_valid(query.text_borrowed(ok_addr)), "expected valid: %q", ok_addr)
	}
}

// CIDR prefix lengths with leading zeros (e.g. `/08`, `/00`, `/008`) or non-digits are refused, while `/0` and valid
// decimal lengths work for both IPv4 and IPv6.
@(test)
cidr_leading_zero_prefix_handling :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	bad_cidrs := [?]string{
		"10.0.0.0/08",
		"10.0.0.0/00",
		"10.0.0.0/008",
		"10.0.0.0/032",
		"::1/08",
		"::1/00",
		"::1/0128",
		"10.0.0.0/+8",
		"10.0.0.0/-1",
		"10.0.0.0/8/8",
		"10.0.0.0/33",
		"::1/129",
	}
	for cidr in bad_cidrs {
		_, st := query.ip_in_cidr(h, query.text_borrowed("10.0.0.1"), query.text_borrowed(cidr))
		testing.expectf(t, st == .Error && h.err.detail == "is not a CIDR network", "cidr %q: status=%v detail=%q", cidr, st, h.err.detail)
		query.clear_error(h)
	}

	ok_cases := [?]struct {
		addr, cidr: string,
		want:       bool,
	}{
		{"10.0.0.1", "10.0.0.0/8", true},
		{"10.0.0.1", "0.0.0.0/0", true},
		{"10.0.0.1", "10.0.0.1/32", true},
		{"10.0.0.2", "10.0.0.1/32", false},
		{"::1", "::/0", true},
		{"::1", "::1/128", true},
		{"::2", "::1/128", false},
	}
	for c in ok_cases {
		got, st := query.ip_in_cidr(h, query.text_borrowed(c.addr), query.text_borrowed(c.cidr))
		testing.expect_value(t, st, query.Status.Ok)
		testing.expectf(t, got == c.want, "%s in %s: got %v want %v", c.addr, c.cidr, got, c.want)
	}
}

// Leading `::` IPv6 addresses and CIDRs with dotted IPv4 tails (including 5-group forms with 7 colons) parse and match
// properly, while malformed triple-colon or double-`::` forms with dotted IPv4 tails are refused.
@(test)
cidr_and_address_leading_double_colon_with_ipv4_tail :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h

	cidr_cases := [?]struct {
		addr, cidr: string,
		want:       bool,
	}{
		{"::192.0.2.1", "::192.0.2.1/96", true},
		{"::192.0.2.99", "::192.0.2.0/120", true},
		{"::192.0.3.1", "::192.0.2.0/120", false},
		{"::ffff:192.0.2.1", "::ffff:192.0.2.1/96", true},
		{"::ffff:192.0.2.42", "::ffff:192.0.2.0/120", true},
		{"::ffff:192.0.3.1", "::ffff:192.0.2.0/120", false},
		{"::1:2:3:4:5:192.0.2.7", "::1:2:3:4:5:192.0.2.0/120", true},
		{"0:1:2:3:4:5:c000:207", "::1:2:3:4:5:192.0.2.0/120", true},
		{"::1:2:3:4:5:192.0.3.7", "::1:2:3:4:5:192.0.2.0/120", false},
		{"1::2:3:4:5:192.0.2.7", "1::2:3:4:5:192.0.2.0/120", true},
		{"1:2:3:4:5::192.0.2.7", "1:2:3:4:5::192.0.2.0/120", true},
		// IPv4 address is not in an IPv6 CIDR even with an IPv4 tail.
		{"192.0.2.1", "::192.0.2.0/120", false},
		{"192.0.2.1", "::ffff:192.0.2.0/120", false},
	}
	for c in cidr_cases {
		got, st := query.ip_in_cidr(h, query.text_borrowed(c.addr), query.text_borrowed(c.cidr))
		testing.expect_value(t, st, query.Status.Ok)
		testing.expectf(t, got == c.want, "%s in %s: got %v want %v", c.addr, c.cidr, got, c.want)
	}

	// Malformed leading-`::` + dotted IPv4 tail forms must be refused (not rewritten into valid addresses).
	bad_v4_tails := [?]string{
		":::1:2:3:4:1.2.3.4",
		"::1::2:3:4:1.2.3.4",
		"::1:2:3:4:5:6:1.2.3.4",
		"::1:2:3:4:5:01.2.3.4",
		"::1:2:3:4:5:1.2.3.",
		"::1:2:3:4:5:1.2.3.4.",
	}
	for s in bad_v4_tails {
		testing.expectf(t, !query.ip_valid(query.text_borrowed(s)), "expected invalid: %q", s)
		_, st := query.ip_in_cidr(h, query.text_borrowed("::1"), query.text_borrowed(s))
		testing.expectf(t, st == .Error, "expected CIDR error for %q", s)
		query.clear_error(h)
	}
}
