package query_test

import "core:math"
import "core:testing"
import "stury:lib/query"
import "stury:testkit"

// The engine's operations on texts: digests, codes, identifiers, the texts that hold structure, addresses and number
// formats. Each test checks the heap gave back every block.

@(private)
text_answer :: proc(x: ^Test_Heap, t: ^testing.T, v: query.Value, s: query.Status, loc := #caller_location) -> string {
	testing.expect(t, s == .Ok, loc = loc)
	defer query.release(&x.h, v)
	return as_json(&x.h, v)
}

@(test)
digests_are_lowercase_hex_of_the_bytes :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	v, s := query.digest_hex(&x.h, "abc", .Sha256)
	testing.expect_value(t, text_answer(&x, t, v, s), `"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"`)
	v, s = query.digest_hex(&x.h, "abc", .Sha1)
	testing.expect_value(t, text_answer(&x, t, v, s), `"a9993e364706816aba3e25717850c26c9cd0d89d"`)
	v, s = query.digest_hex(&x.h, "abc", .Md5)
	testing.expect_value(t, text_answer(&x, t, v, s), `"900150983cd24fb0d6963f7d28e17f72"`)
	v, s = query.digest_hex(&x.h, "", .Sha512)
	testing.expect_value(t, text_answer(&x, t, v, s), `"cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"`)
	v, s = query.hmac_hex(&x.h, "what do ya want for nothing?", "Jefe", .Sha256)
	testing.expect_value(t, text_answer(&x, t, v, s), `"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"`)
	testing.expect_value(t, query.crc32("123456789"), 3421780262)
}

@(test)
identifiers_set_their_version_and_variant :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	random: [16]u8
	for &b, i in random {
		b = u8(i)
	}
	v, s := query.uuid_text(&x.h, random)
	testing.expect_value(t, text_answer(&x, t, v, s), `"00010203-0405-4607-8809-0a0b0c0d0e0f"`)
	v, s = query.uuid_text(&x.h, random, 1717238096123)
	testing.expect_value(t, text_answer(&x, t, v, s), `"018fd35d-e0fb-7607-8809-0a0b0c0d0e0f"`)
}

@(test)
hex_and_base64url_read_back_what_they_wrote :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	v, s := query.encode_base(h, "?>?>", .Base64_Url, false)
	testing.expect_value(t, text_answer(&x, t, v, s), `"Pz4_Pg"`)
	for padded in ([]string{"Pz4_Pg", "Pz4_Pg=="}) {
		decoded, none, st := query.decode_base(h, padded, .Base64_Url)
		testing.expect_value(t, none, query.Decode_Fault.None)
		testing.expect_value(t, text_answer(&x, t, decoded, st), `"?>?>"`)
	}
	_, fault, _ := query.decode_base(h, "Pz4/Pg", .Base64_Url)
	testing.expect_value(t, fault, query.Decode_Fault.Bad_Digit)
	_, fault, _ = query.decode_base(h, "a", .Base64_Url)
	testing.expect_value(t, fault, query.Decode_Fault.Lone_Digit)
	// A byte that is no UTF-8 is read as U+FFFD.
	v, fault, s = query.decode_base(h, "_w", .Base64_Url)
	testing.expect_value(t, text_answer(&x, t, v, s), `"�"`)
	hex, ok, st := query.decode_hex(h, "6A6b")
	testing.expect(t, ok)
	testing.expect_value(t, text_answer(&x, t, hex, st), `"jk"`)
	for bad in ([]string{"abc", "6", "zz"}) {
		_, ok, _ = query.decode_hex(h, bad)
		testing.expect(t, !ok, bad)
	}
}

@(test)
a_url_reads_into_its_parts :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	cases := [?][2]string {
		{"https://u@h:8080/a?x=1#f", `{"scheme":"https","user":"u","host":"h","port":8080,"path":"/a","query":"x=1","fragment":"f"}`},
		{"/rel/path?q", `{"scheme":null,"user":null,"host":null,"port":null,"path":"/rel/path","query":"q","fragment":null}`},
		{"http://[::1]:80/", `{"scheme":"http","user":null,"host":"::1","port":80,"path":"/","query":null,"fragment":null}`},
		{"mailto:a@b.c", `{"scheme":"mailto","user":null,"host":null,"port":null,"path":"a@b.c","query":null,"fragment":null}`},
		{"http://example.com", `{"scheme":"http","user":null,"host":"example.com","port":null,"path":"","query":null,"fragment":null}`},
	}
	for c in cases {
		url := query.text_borrowed(c[0])
		v, s := query.parse_url(h, url)
		testing.expect_value(t, text_answer(&x, t, v, s), c[1])
	}
	faults := [?][2]string {
		{"http://h:99999/", "is not a URL: its port is not a number up to 65535"},
		{"http://a b/", "is not a URL: it holds a space or a control character"},
		{"http://[::1/", "is not a URL: its host is a bad IP literal"},
	}
	for c in faults {
		_, s := query.parse_url(h, query.text_borrowed(c[0]))
		testing.expect_value(t, s, query.Status.Error)
		testing.expect_value(t, h.err.detail, c[1])
		testing.expect_value(t, h.err.op, query.Op.Url)
		query.clear_error(h)
	}
}

@(test)
a_query_string_reads_into_strings_and_lists :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	cases := [?][2]string {
		{"a=1&a=2&b=x+y", `{"a":["1","2"],"b":"x y"}`},
		{"a=1&b=2&a=3&c&d=%41+%20&e=%zz&&f=%E2%82%AC", `{"a":["1","3"],"b":"2","c":"","d":"A  ","e":"%zz","f":"€"}`},
		{"a=1&a=2&a=3&a=4", `{"a":["1","2","3","4"]}`},
		{"?x=1", `{"x":"1"}`},
		{"", `{}`},
		{"a=%ff", `{"a":"�"}`},
	}
	for c in cases {
		v, s := query.parse_query_string(&x.h, query.text_borrowed(c[0]))
		testing.expect_value(t, text_answer(&x, t, v, s), c[1])
	}
}

@(test)
logfmt_reads_pairs_and_names_its_faults :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	v, s := query.parse_logfmt(h, query.text_borrowed(`level=info msg="hello world" ok dur=3ms empty= q="a\"b\n"`))
	testing.expect_value(t, text_answer(&x, t, v, s), `{"level":"info","msg":"hello world","ok":true,"dur":"3ms","empty":"","q":"a\"b\n"}`)
	v, s = query.parse_logfmt(h, query.text_borrowed("a=1 a=2"))
	testing.expect_value(t, text_answer(&x, t, v, s), `{"a":"2"}`)
	faults := [?][3]string {
		{`a="x`, "unclosed", "0"},
		{`=x`, "unexpected", "0"},
		{`ab "c"`, "unexpected", "3"},
		{`b=1 a="\q"`, "unknown escape", "4"},
	}
	for c in faults {
		_, st := query.parse_logfmt(h, query.text_borrowed(c[0]))
		testing.expect_value(t, st, query.Status.Error)
		testing.expect_value(t, h.err.detail, c[1])
		testing.expect_value(t, as_json(h, h.err.b), c[2])
		query.clear_error(h)
	}
}

@(test)
a_pointer_splits_into_unescaped_tokens :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	cases := [?][2]string {
		{"", `[]`},
		{"/", `[""]`},
		{"/a/b~1c/~0/~01", `["a","b/c","~","~1"]`},
		{"/a//0", `["a","","0"]`},
	}
	for c in cases {
		v, s := query.pointer_tokens(h, query.text_borrowed(c[0]))
		testing.expect_value(t, text_answer(&x, t, v, s), c[1])
	}
	for bad in ([]query.Value{query.text_borrowed("a"), query.int_value(1), query.NULL}) {
		_, s := query.pointer_tokens(h, bad)
		testing.expect_value(t, s, query.Status.Error)
		testing.expect_value(t, h.err.op, query.Op.Pointer)
		query.clear_error(h)
	}
	for c in ([]struct {
		token: string,
		index: i64,
		ok:    bool,
	}{{"0", 0, true}, {"12", 12, true}, {"01", 0, false}, {"-", 0, false}, {"", 0, false}, {"2147483648", 0, false}}) {
		i, ok := query.pointer_index(c.token)
		testing.expectf(t, ok == c.ok && (!ok || i == c.index), "%q", c.token)
	}
}

@(test)
addresses_are_read_classed_and_written_canonically :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	valid := [?]string{"1.2.3.4", "::ffff:1.2.3.4", "2001:db8::", "::", "1:2:3:4:5:6:7:8", "255.255.255.255"}
	invalid := [?]string{"01.2.3.4", "1.2.3", "::1::", "fe80::1%eth0", "1.2.3.256", "", "1:2:3:4:5:6:7:8:9", "12345::", "[::1]"}
	for s in valid {
		testing.expect(t, query.ip_valid(query.text_borrowed(s)), s)
	}
	for s in invalid {
		testing.expect(t, !query.ip_valid(query.text_borrowed(s)), s)
	}
	testing.expect(t, !query.ip_valid(query.int_value(1)))
	classes := [?][2]string {
		{"10.0.0.1", "private"},
		{"172.31.0.1", "private"},
		{"172.32.0.1", "global"},
		{"127.0.0.1", "loopback"},
		{"169.254.1.1", "link-local"},
		{"224.0.0.1", "multicast"},
		{"0.0.0.0", "unspecified"},
		{"::1", "loopback"},
		{"fe80::1", "link-local"},
		{"fc00::1", "private"},
		{"ff02::1", "multicast"},
		{"::ffff:192.168.1.1", "private"},
		{"2001:db8::1", "global"},
	}
	for c in classes {
		v, s := query.ip_class(h, query.text_borrowed(c[0]))
		testing.expect_value(t, text_answer(&x, t, v, s), text_quoted(c[1]))
	}
	canonical := [?][2]string {
		{"2001:0DB8:0000:0000:0000:0000:0000:0001", "2001:db8::1"},
		{"::ffff:1.2.3.4", "::ffff:1.2.3.4"},
		{"1:0:0:2:0:0:0:3", "1:0:0:2::3"},
		{"0:0:0:0:0:0:0:0", "::"},
		{"1.2.3.4", "1.2.3.4"},
		{"2001:db8:0:0:1:0:0:1", "2001:db8::1:0:0:1"},
		{"1:2:3:4:5:6:7:0", "1:2:3:4:5:6:7:0"},
		{"0:0:1:0:0:0:0:0", "0:0:1::"},
	}
	for c in canonical {
		v, s := query.ip_canonical(h, query.text_borrowed(c[0]))
		testing.expect_value(t, text_answer(&x, t, v, s), text_quoted(c[1]))
	}
	_, s := query.ip_class(h, query.text_borrowed("x"))
	testing.expect_value(t, s, query.Status.Error)
	testing.expect_value(t, h.err.detail, "is not an IP address")
	query.clear_error(h)
}

@(private)
text_quoted :: proc(s: string) -> string {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, '"')
	append(&out, s)
	append(&out, '"')
	return string(out[:])
}

@(test)
a_network_holds_the_addresses_under_its_prefix :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	cases := [?]struct {
		address, cidr: string,
		inside:        bool,
	}{
		{"10.1.2.3", "10.0.0.0/8", true},
		{"10.1.2.3", "10.1.2.0/23", true},
		{"10.1.3.3", "10.1.2.0/23", true},
		{"10.1.4.3", "10.1.2.0/23", false},
		{"10.1.2.3", "10.1.3.0/24", false},
		{"10.1.2.3", "::/0", false},
		{"10.1.2.3", "0.0.0.0/0", true},
		{"10.1.2.3", "10.1.2.3/32", true},
		{"2001:db8::5", "2001:db8::/32", true},
		{"2001:db9::5", "2001:db8::/32", false},
	}
	for c in cases {
		in_network, s := query.ip_in_cidr(h, query.text_borrowed(c.address), query.text_borrowed(c.cidr))
		testing.expect_value(t, s, query.Status.Ok)
		testing.expectf(t, in_network == c.inside, "%s in %s", c.address, c.cidr)
	}
	for bad in ([]query.Value{query.text_borrowed("10.0.0.0/33"), query.text_borrowed("10.0.0.0"), query.text_borrowed("10.0.0.0/"), query.int_value(1)}) {
		_, s := query.ip_in_cidr(h, query.text_borrowed("10.1.2.3"), bad)
		testing.expect_value(t, s, query.Status.Error)
		testing.expect_value(t, h.err.detail, "is not a CIDR network")
		query.clear_error(h)
	}
}

@(test)
a_format_text_writes_a_number :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	cases := [?]struct {
		n:    f64,
		spec: string,
		want: string,
	}{
		{3.14159, "%.2f", "3.14"},
		{3.14159, "%e", "3.141590e+00"},
		{3.14159, "%10.2f", "      3.14"},
		{3.14159, "%010.2f", "0000003.14"},
		{3.14159, "%-8.1f|", "3.1     |"},
		{3.14159, "%d", "3"},
		{3.14159, "$%.2f%%", "$3.14%"},
		{1234567.891, "%,.2f", "1,234,567.89"},
		{1234567.891, "%,d", "1,234,567"},
		{-1234.5, "%,.1f", "-1,234.5"},
		{-1234.5, "%d", "-1234"},
		{-0.5, "%d", "0"},
		{-0.5, "%.0f", "-0"},
		{2.5, "%.0f", "2"},
		{-1234.5, "%e", "-1.234500e+03"},
		{12, "n=%03d.", "n=012."},
	}
	for c in cases {
		v, s := query.number_format(h, query.double_value(c.n), query.text_borrowed(c.spec))
		testing.expect_value(t, text_answer(&x, t, v, s), text_quoted(c.want))
	}
	for spec in ([]string{"%x", "abc", "%d%d", "", "%", "%2000d", "%.200f"}) {
		_, s := query.number_format(h, query.int_value(1), query.text_borrowed(spec))
		testing.expect_value(t, s, query.Status.Error)
		testing.expect_value(t, h.err.kind, query.Error_Kind.Parse)
		query.clear_error(h)
	}
	_, _ = query.number_format(h, query.int_value(1), query.int_value(1))
	testing.expect_value(t, h.err.kind, query.Error_Kind.Types)
	query.clear_error(h)
	_, _ = query.number_format(h, query.double_value(math.inf_f64(1)), query.text_borrowed("%d"))
	testing.expect_value(t, h.err.kind, query.Error_Kind.Range)
	query.clear_error(h)
}

@(test)
base_decoding_names_the_first_fault_jq_would :: proc(t: ^testing.T) {
	testkit.deadline(t)
	x: Test_Heap
	heap_start(&x)
	defer heap_done(t, &x)
	h := &x.h
	Case :: struct {
		text:  string,
		base:  query.Base,
		fault: query.Decode_Fault,
	}
	cases := [?]Case {
		{"", .Base64, .None},
		{"====", .Base64, .None},
		{"YQ", .Base64, .None},
		{"YQ=====", .Base64, .None},
		{"Y", .Base64, .Lone_Digit},
		{"YWJjZ", .Base64, .Lone_Digit},
		{"YWJj$", .Base64, .Bad_Digit},
		{"YW$jZ", .Base64, .Bad_Digit},
		{"YW=j", .Base64, .Bad_Digit},
		{"Pz4/Pg", .Base64, .None},
		{"Pz4/Pg", .Base64_Url, .Bad_Digit},
		{"Pz4_Pg", .Base64, .Bad_Digit},
		{"MY", .Base32, .None},
		{"MY======", .Base32, .None},
		{"MFRGG", .Base32, .None},
		{"M", .Base32, .Lone_Digit},
		{"MFR", .Base32, .Lone_Digit},
		{"MFRGGZ", .Base32, .Lone_Digit},
		{"MFRGGZ1", .Base32, .Bad_Digit},
		{"mfrgg", .Base32, .Bad_Digit},
		{"M1R", .Base32, .Bad_Digit},
	}
	for c in cases {
		v, fault, s := query.decode_base(h, c.text, c.base)
		testing.expect_value(t, fault, c.fault)
		if fault == .None {
			query.release(h, v)
		}
		testing.expect_value(t, s, query.Status.Ok)
	}
	v, fault, s := query.decode_base(h, "MFRGG===", .Base32)
	testing.expect_value(t, fault, query.Decode_Fault.None)
	testing.expect_value(t, text_answer(&x, t, v, s), `"abc"`)
	v, s = query.encode_base(h, "abc", .Base32, true)
	testing.expect_value(t, text_answer(&x, t, v, s), `"MFRGG==="`)
	v, s = query.encode_base(h, "abcd", .Base64, false)
	testing.expect_value(t, text_answer(&x, t, v, s), `"YWJjZA"`)
	v, s = query.encode_base(h, "", .Base64_Url, true)
	testing.expect_value(t, text_answer(&x, t, v, s), `""`)
}
