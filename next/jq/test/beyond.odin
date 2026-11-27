package jq_tests

import "core:testing"
import "stury:testkit"

// stury's builtins beyond jq, by the examples of `docs/cli.md` "Builtins beyond jq" and the edges it states.

@(private, rodata)
BEYOND := [?][3]string {
	{"[1,2,3,4] | avg", "null", "2.5"},
	{"[1,2,3,4] | variance", "null", "1.25"},
	{"[1,2,3,4] | stddev", "null", "1.118033988749895"},
	{"[1,2,3,4] | median", "null", "2.5"},
	{"[1,2,3,4] | quantile(0.25)", "null", "1.75"},
	{"[3,1,2] | quantile(1)", "null", "3"},
	{"[] | avg, median, variance", "null", "null\nnull\nnull"},
	{"map(.a) | avg", `[{"a":1},{"a":2}]`, "1.5"},
	{"avg(.a), median(.a), quantile(0; .a), stddev(.a), variance(.a)", `[{"a":1},{"a":3}]`, "2\n2\n1\n1\n1"},
	{`try (["a"] | avg) catch .`, "null", `"string (\"a\") cannot be summarized"`},
	{`try ([1] | quantile(2)) catch .`, "null", `"quantile 2 must be a number from 0 to 1"`},
	{`["a","b","a"] | frequency`, "null", `[{"value":"a","count":2},{"value":"b","count":1}]`},
	{`frequency(.k)`, `[{"k":2},{"k":1},{"k":2},{"k":1},{"k":3}]`, `[{"value":1,"count":2},{"value":2,"count":2},{"value":3,"count":1}]`},
	{"[1,2,2] | union([3])", "null", "[1,2,3]"},
	{"[3,1,2,2] | intersect([2,3,4])", "null", "[2,3]"},
	{"[3,1,2,2] | except([2])", "null", "[1,3]"},
	{"[1,null,2] | fill_forward", "null", "[1,1,2]"},
	{"[null,1,null,null] | fill_forward", "null", "[null,1,1,1]"},
	{`[{"a":1,"b":null},{"a":null,"b":2},{"a":null,"b":null}] | fill_forward`, "null", `[{"a":1,"b":null},{"a":1,"b":2},{"a":1,"b":2}]`},
	{`[{"id":1,"x":5}] | melt(["id"])`, "null", `[{"id":1,"variable":"x","value":5}]`},
	{`[{"id":1,"x":5,"y":6}] | melt(["id"]; "k"; "v")`, "null", `[{"id":1,"k":"x","v":5},{"id":1,"k":"y","v":6}]`},
	{`[{"id":1,"k":"x","v":5},{"id":2,"k":"y","v":6}] | pivot(["id"]; "k"; "v")`, "null", `[{"id":1,"x":5,"y":null},{"id":2,"x":null,"y":6}]`},
	{`[{"id":2,"k":"x","v":1},{"id":1,"k":"x","v":5},{"id":1,"k":"x","v":7}] | pivot(["id"]; "k"; "v")`, "null", `[{"id":1,"x":7},{"id":2,"x":1}]`},
	{`"abc"|sha256`, "null", `"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"`},
	{`""|sha256`, "null", `"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"`},
	{`"abc"|sha1`, "null", `"a9993e364706816aba3e25717850c26c9cd0d89d"`},
	{`"abc"|md5`, "null", `"900150983cd24fb0d6963f7d28e17f72"`},
	{`"abc"|sha512`, "null", `"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"`},
	{`"é"|sha256`, "null", `"4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c"`},
	{`"what do ya want for nothing?"|hmac_sha256("Jefe")`, "null", `"5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"`},
	{`"what do ya want for nothing?"|hmac_sha512("Jefe")`, "null", `"164b7a7bfcf819e2e395fbe73b56e0a387bd64222e831fd610270cd7ea2505549758bf75c05a994a6d034f65f8f0e6fdcaeab1a34d4a6b4b636e070a38bce737"`},
	{`"Hi There"|hmac_sha256("\u000b" * 20)`, "null", `"b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"`},
	{`"123456789"|crc32`, "null", `3421780262`},
	{`""|crc32`, "null", `0`},
	{`try (1|sha256) catch .`, "null", `"sha256 input must be a string"`},
	{`try ("x"|hmac_sha256(1)) catch .`, "null", `"hmac_sha256 key must be a string"`},
	{`"abc"|hex_encode`, "null", `"616263"`},
	{`"616263","6A6b"|hex_decode`, "null", `"abc"
"jk"`},
	{`""|hex_encode,hex_decode`, "null", `""
""`},
	{`try ("abc"|hex_decode) catch .`, "null", `"string (\"abc\") is not valid hex data"`},
	{`try ("6"|hex_decode) catch .`, "null", `"string (\"6\") is not valid hex data"`},
	{`"?>?>"|base64url_encode`, "null", `"Pz4_Pg"`},
	{`"Pz4_Pg","Pz4_Pg==","YWJj"|base64url_decode`, "null", `"?>?>"
"?>?>"
"abc"`},
	{`try ("Pz4/Pg"|base64url_decode) catch .`, "null", `"string (\"Pz4/Pg\") is not valid base64 data"`},
	{`try ("a"|base64url_decode) catch .`, "null", `"string (\"a\") trailing base64 byte found"`},
	{`"_w"|base64url_decode`, "null", `"�"`},
	{`3.14159|numfmt("%.2f"),numfmt("%e"),numfmt("%10.2f"),numfmt("%010.2f"),numfmt("%-8.1f|"),numfmt("%d"),numfmt("$%.2f%%")`, "null", `"3.14"
"3.141590e+00"
"      3.14"
"0000003.14"
"3.1     |"
"3"
"$3.14%"`},
	{`1234567.891|numfmt("%,.2f"),numfmt("%,d")`, "null", `"1,234,567.89"
"1,234,567"`},
	{`-1234.5|numfmt("%,.1f"),numfmt("%d"),numfmt("%e")`, "null", `"-1,234.5"
"-1234"
"-1.234500e+03"`},
	{`2.5,3.5,-0.5|numfmt("%.0f"),numfmt("%d")`, "null", `"2"
"2"
"4"
"3"
"-0"
"0"`},
	{`try (1|numfmt("%x")) catch .`, "null", `"numfmt: invalid format \"%x\""`},
	{`try (1|numfmt("abc")) catch .`, "null", `"numfmt: invalid format \"abc\""`},
	{`try (1|numfmt("%d%d")) catch .`, "null", `"numfmt: invalid format \"%d%d\""`},
	{`try (1|numfmt(1)) catch .`, "null", `"numfmt format must be a string"`},
	{`try ("x"|numfmt("%d")) catch .`, "null", `"string (\"x\") number required"`},
	{`try (infinite|numfmt("%d")) catch .`, "null", `"numfmt requires a finite number"`},
	{`"https://user:pw@example.com:8080/a/b?x=1&y=2#frag"|parse_url`, "null", `{"scheme":"https","user":"user:pw","host":"example.com","port":8080,"path":"/a/b","query":"x=1&y=2","fragment":"frag"}`},
	{`"/rel/path?q","mailto:a@b.c","http://[::1]:80/","file:///etc/hosts","http://example.com"|parse_url`, "null", `{"scheme":null,"user":null,"host":null,"port":null,"path":"/rel/path","query":"q","fragment":null}
{"scheme":"mailto","user":null,"host":null,"port":null,"path":"a@b.c","query":null,"fragment":null}
{"scheme":"http","user":null,"host":"::1","port":80,"path":"/","query":null,"fragment":null}
{"scheme":"file","user":null,"host":"","port":null,"path":"/etc/hosts","query":null,"fragment":null}
{"scheme":"http","user":null,"host":"example.com","port":null,"path":"","query":null,"fragment":null}`},
	{`try ("http://h:99999/"|parse_url) catch .`, "null", `"string (\"http://h:99999/\") is not a URL: its port is not a number up to 65535"`},
	{`try ("http://a b/"|parse_url) catch .`, "null", `"string (\"http://a b/\") is not a URL: it holds a space or a control character"`},
	{`try (1|parse_url) catch .`, "null", `"number (1) cannot be parsed by parse_url, only a string"`},
	{`"a=1&b=2&a=3&c&d=%41+%20&e=%zz&&f=%E2%82%AC"|parse_query_string`, "null", `{"a":["1","3"],"b":"2","c":"","d":"A  ","e":"%zz","f":"€"}`},
	{`"?x=1"|parse_query_string`, "null", `{"x":"1"}`},
	{`""|parse_query_string`, "null", `{}`},
	{`"level=info msg=\"hello world\" ok dur=3ms empty= q=\"a\\\"b\\n\""|parse_logfmt`, "null", `{"level":"info","msg":"hello world","ok":true,"dur":"3ms","empty":"","q":"a\"b\n"}`},
	{`"a=1 a=2"|parse_logfmt`, "null", `{"a":"2"}`},
	{`try ("a=\"x"|parse_logfmt) catch .`, "null", `"logfmt: the quoted value of a is not closed"`},
	{`try ("=x"|parse_logfmt) catch .`, "null", `"logfmt: unexpected = at byte 0"`},
	{`try ("a=\"\\q\""|parse_logfmt) catch .`, "null", `"logfmt: unknown escape in the value of a"`},
	{`{"a":{"b/c":[10,{"~":5}]}}|json_pointer("/a/b~1c/1/~0"),json_pointer("/a/b~1c/0"),json_pointer("")`, "null", `5
10
{"a":{"b/c":[10,{"~":5}]}}`},
	{`{"a":[1]}|json_pointer("/x/y"),json_pointer("/a/5"),json_pointer("/a/01"),json_pointer("/a/-")`, "null", `null
null
null
null`},
	{`{"1":"one"}|json_pointer("/1")`, "null", `"one"`},
	{`try ({}|json_pointer("a")) catch .`, "null", `"json_pointer: \"a\" is not a JSON Pointer"`},
	{`try ({"a":1}|json_pointer("/a/b")) catch .`, "null", `"Cannot index number with string (\"b\")"`},
	{`"1.2.3.4","01.2.3.4","1.2.3","::1::","fe80::1%eth0","::ffff:1.2.3.4","2001:db8::",1|ip_valid`, "null", `true
false
false
false
false
true
true
false`},
	{`"10.0.0.1","172.16.0.1","172.32.0.1","192.168.1.1","127.0.0.1","169.254.1.1","224.0.0.1","8.8.8.8","0.0.0.0"|ip_class`, "null", `"private"
"private"
"global"
"private"
"loopback"
"link-local"
"multicast"
"global"
"unspecified"`},
	{`"::1","fe80::1","fc00::1","ff02::1","2001:db8::1","::ffff:192.168.1.1","::"|ip_class`, "null", `"loopback"
"link-local"
"private"
"multicast"
"global"
"private"
"unspecified"`},
	{`try ("x"|ip_class) catch .`, "null", `"string (\"x\") is not an IP address"`},
	{`"2001:0DB8:0000:0000:0000:0000:0000:0001","::ffff:1.2.3.4","1:0:0:2:0:0:0:3","0:0:0:0:0:0:0:0","1.2.3.4","2001:db8:0:0:1:0:0:1","1:2:3:4:5:6:7:0","0:0:1:0:0:0:0:0"|ip_canonical`, "null", `"2001:db8::1"
"::ffff:1.2.3.4"
"1:0:0:2::3"
"::"
"1.2.3.4"
"2001:db8::1:0:0:1"
"1:2:3:4:5:6:7:0"
"0:0:1::"`},
	{`"10.1.2.3"|ip_in_cidr("10.0.0.0/8"),ip_in_cidr("10.1.2.0/23"),ip_in_cidr("10.1.3.0/24"),ip_in_cidr("::/0"),ip_in_cidr("0.0.0.0/0"),ip_in_cidr("10.1.2.3/32")`, "null", `true
true
false
false
true
true`},
	{`"2001:db8::5"|ip_in_cidr("2001:db8::/32"),ip_in_cidr("2001:db9::/32")`, "null", `true
false`},
	{`try ("10.1.2.3"|ip_in_cidr("10.0.0.0/33")) catch .`, "null", `"string (\"10.0.0.0/33\") is not a CIDR network"`},
	{`try ("10.1.2.3"|ip_in_cidr("10.0.0.0")) catch .`, "null", `"string (\"10.0.0.0\") is not a CIDR network"`},
	{`try ("x"|ip_in_cidr("10.0.0.0/8")) catch .`, "null", `"string (\"x\") is not an IP address"`},
	{`"1.2.3.4:80","[1.2.3.4]","[1.2.3.4]:80","[::1]","[::1]:80","::1%eth0","fe80::1%1","::1:80","::1.2.3.4:80"|ip_valid`, "null", `false
false
false
false
false
false
false
true
false`},
	{`"01.2.3.4","1.02.3.4","1.2.3.04","1.2.3.","1.2.3","1.2","16909060","1..3.4",".1.2.3.4","1.2.3.4.5","256.1.1.1","1.2.3.0","0.0.0.0"|ip_valid`, "null", `false
false
false
false
false
false
false
false
false
false
false
true
true`},
	{`"::ffff:01.2.3.4","::1.2.3.","::1.2.3","::1.2.3.4.5","1:2:3:4:5:6:7:8:9","1::2::3","1:2:3:4:5:6:7","12345::","::g","1:2:3:4:5:6:7:8:","0:0:0:0:0:0:0:0"|ip_valid`, "null", `false
false
false
false
false
false
false
false
false
false
true`},
	{`try ("10.1.2.3"|ip_in_cidr("[10.0.0.0]/8")) catch .`, "null", `"string (\"[10.0.0.0]/8\") is not a CIDR network"`},
	{`try ("10.1.2.3"|ip_in_cidr("10.0.0.0:80/8")) catch .`, "null", `"string (\"10.0.0.0:80/8\") is not a CIDR network"`},
	{`try ("10.1.2.3"|ip_in_cidr("010.0.0.0/8")) catch .`, "null", `"string (\"010.0.0.0/8\") is not a CIDR network"`},
	{`try ("10.1.2.3"|ip_in_cidr("10.0.0.0/")) catch .`, "null", `"string (\"10.0.0.0/\") is not a CIDR network"`},
	{`try ("::1"|ip_in_cidr("[::]/0")) catch .`, "null", `"string (\"[::]/0\") is not a CIDR network"`},
	{`"10.1.2.3","::ffff:10.1.2.3"|ip_in_cidr("10.0.0.0/8")`, "null", `true
false`},
	{`"::1","fe80::1"|ip_in_cidr("fe80::/10")`, "null", `false
true`},
	{`"?>?>" | base64url_encode`, "null", `"Pz4_Pg"`},
	{`"a" | base64url_encode, ("" | base64url_encode, base64url_decode)`, "null", `"YQ"
""
""`},
	{`try (1 | hex_decode) catch .`, "null", `"hex_decode input must be a string"`},
	{`try (null | base64url_encode) catch .`, "null", `"base64url_encode input must be a string"`},
	{`try ("ab" | hmac_sha512([])) catch .`, "null", `"hmac_sha512 key must be a string"`},
	{`"ff" | hex_decode`, "null", `"�"`},
	{`[uuid_v4, uuid_v4]`, "null", `["00010203-0405-4607-8809-0a0b0c0d0e0f","10111213-1415-4617-9819-1a1b1c1d1e1f"]`},
	{`uuid_v7`, "null", `"018fd35d-e0fb-7607-8809-0a0b0c0d0e0f"`},
	{`"https://u@h:8080/a?x=1#f" | parse_url`, "null", `{"scheme":"https","user":"u","host":"h","port":8080,"path":"/a","query":"x=1","fragment":"f"}`},
	{`"a=1&a=2&b=x+y" | parse_query_string`, "null", `{"a":["1","2"],"b":"x y"}`},
	{`"a=1&a=2&a=3" | parse_query_string`, "null", `{"a":["1","2","3"]}`},
	{`"ok msg=\"a b\"" | parse_logfmt`, "null", `{"ok":true,"msg":"a b"}`},
	{`try ("a=\"x\\q\"" | parse_logfmt) catch ., try ("a\"" | parse_logfmt) catch .`, "null", `"logfmt: unknown escape in the value of a"
"logfmt: unexpected \" at byte 1"`},
	{`try ([] | parse_logfmt) catch ., try ({} | parse_query_string) catch .`, "null", `"array ([]) cannot be parsed by parse_logfmt, only a string"
"object ({}) cannot be parsed by parse_query_string, only a string"`},
	{`1234567.891 | numfmt("%,.2f")`, "null", `"1,234,567.89"`},
	{`try (1 | numfmt("")) catch ., try (nan | numfmt("%d")) catch .`, "null", `"numfmt: invalid format \"\""
"numfmt requires a finite number"`},
	{`try (1 | numfmt("%2000d")) catch .`, "null", `"numfmt: invalid format \"%2000d\""`},
	{`[7, 12.5] | map(numfmt("[%-4d]")), map(numfmt("[%04d] 100%%"))`, "null", `["[7   ]","[12  ]"]
["[0007] 100%","[0012] 100%"]`},
	{`"::ffff:1.2.3.4" | ip_valid`, "null", `true`},
	{`"::a:b:c:d:e:1.2.3.4" | ip_valid, ip_canonical`, "null", `true
"0:a:b:c:d:e:102:304"`},
	{`"172.16.0.1" | ip_class`, "null", `"private"`},
	{`"2001:0DB8:0:0:0:0:0:1" | ip_canonical`, "null", `"2001:db8::1"`},
	{`"10.1.2.3" | ip_in_cidr("10.0.0.0/8")`, "null", `true`},
	{`try (1 | ip_class) catch ., (1 | ip_valid)`, "null", `"number (1) cannot be read as an IP address, only a string"
false`},
	{`try ("10.1.2.3" | ip_in_cidr(1)) catch .`, "null", `"number (1) is not a CIDR network"`},
	{`"::" | ip_canonical, ip_class`, "null", `"::"
"unspecified"`},
	{`{"a":[10]} | json_pointer("/a/0")`, "null", `10`},
	{`{"a":[10]} | path(json_pointer("/a/0"))`, "null", `["a",0]`},
	{`{"a":[10]} | json_pointer("/a/0") |= . + 1`, "null", `{"a":[11]}`},
	{`{"a":[10,20]} | del(json_pointer("/a/0"))`, "null", `{"a":[20]}`},
	{`{"a":{"b/c":1}} | json_pointer("/a/b~1c"), path(json_pointer("/a/b~1c")), json_pointer("")`, "null", `1
["a","b/c"]
{"a":{"b/c":1}}`},
	{`{"a":[1]} | json_pointer("/a/x"), (try path(json_pointer("/a/x")) catch .)`, "null", `null
"Invalid path expression with result null"`},
	{`try (json_pointer(1)) catch ., try (json_pointer("/a/b")) catch .`, `{"a":1}`, `"json_pointer: 1 is not a JSON Pointer"
"Cannot index number with string (\"b\")"`},
	{`[(builtins | contains(["sha1/0", "sha256/0", "sha512/0", "md5/0", "hmac_sha256/1", "hmac_sha512/1", "crc32/0", "hex_encode/0", "hex_decode/0", "base64url_encode/0", "base64url_decode/0", "uuid_v4/0", "uuid_v7/0", "numfmt/1", "parse_url/0", "parse_query_string/0", "parse_logfmt/0", "json_pointer/1", "ip_valid/0", "ip_class/0", "ip_canonical/0", "ip_in_cidr/1"])), (builtins | map(startswith("_pointer")) | any)]`, "null", `[true,false]`},
	{`"2015-03-05T23:51:47Z" | fromrfc3339`, "null", "1425599507"},
	{`"2024-06-01T12:34:56.123+02:00" | fromrfc3339`, "null", "1717238096.123"},
	{`"1969-12-31T23:59:58.5-00:00", "2016-12-31T23:59:60Z" | fromrfc3339`, "null", "-1.5\n1483228800"},
	{`"2015-03-05t23:51:47z" | fromrfc3339`, "null", "1425599507"},
	{`"2015-03-05 23:51:47Z", "2015-02-29T00:00:00Z", "2015-03-05T23:51:47", "2015-03-05T23:51:60Z" | try fromrfc3339 catch .`, "null", `"date \"2015-03-05 23:51:47Z\" is not an RFC 3339 date-time"` + "\n" + `"date \"2015-02-29T00:00:00Z\" is not an RFC 3339 date-time"` + "\n" + `"date \"2015-03-05T23:51:47\" is not an RFC 3339 date-time"` + "\n" + `"date \"2015-03-05T23:51:60Z\" is not an RFC 3339 date-time"`},
	{`try (1 | fromrfc3339) catch .`, "null", `"fromrfc3339 requires string inputs"`},
	{`1425599507 | torfc3339`, "null", `"2015-03-05T23:51:47Z"`},
	{`1717238096.123, -1.5, 0 | torfc3339`, "null", `"2024-06-01T10:34:56.123Z"` + "\n" + `"1969-12-31T23:59:58.5Z"` + "\n" + `"1970-01-01T00:00:00Z"`},
	{`try (253402300800 | torfc3339) catch .`, "null", `"torfc3339() input is outside the years 0000 to 9999"`},
	{`try ("x" | torfc3339) catch .`, "null", `"torfc3339() requires numeric inputs"`},
	{`[builtins | index("fromrfc3339/0"), index("torfc3339/0")] | map(. != null)`, "null", "[true,true]"},
}

@(test)
builtins_beyond_jq_give_their_documented_answers :: proc(t: ^testing.T) {
	testkit.deadline(t)
	run_case_table(t, "beyond", BEYOND[:])
}
