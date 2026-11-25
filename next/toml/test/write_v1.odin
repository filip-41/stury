package toml_tests

import "core:testing"
import "stury:json"
import "stury:testkit"
import "stury:toml"

// A text v1 writes of the same values, which the writer here writes as it does.

@(test)
toml_is_v1s_text :: proc(t: ^testing.T) {
	testkit.deadline(t)
	doc, err := json.build(transmute([]u8)string(`{"a":1,"b":"x\ny","c":[1,2.5],"d":{"e":true},"f":[{"g":1},{"g":2}]}`))
	defer json.destroy(&doc)
	testing.expect(t, err == nil)
	text, _, werr := toml.write(&doc)
	defer delete(text)
	want := "a = 1\nb = \"x\\ny\"\nc = [1, 2.5]\n\n[d]\ne = true\n\n[[f]]\ng = 1\n\n[[f]]\ng = 2\n"
	testing.expectf(t, werr == nil && string(text) == want, "%v\n%s", werr, text)
}
