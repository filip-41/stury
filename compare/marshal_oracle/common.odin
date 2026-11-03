// The oracle's arms share these types, the fixtures they read and the directed values. Each arm's `marshal_all` writes
// each value compact and pretty to `<out>/<name>.json` and `<out>/<name>.pretty.json`, and oracle.py compares them.
#+feature dynamic-literals
package marshal_oracle

import "core:fmt"
import "core:os"

Log_Record :: struct {
	ts, level, service, msg: string,
	status, bytes:           i64,
	duration_ms:             f64,
	id:                      string,
}
Logs :: struct {
	logs: []Log_Record,
}
Tweet_Metadata :: struct {
	result_type, iso_language_code: string,
}
Twitter_User :: struct {
	id:                                                                             i64,
	id_str, name, screen_name, location, description, created_at:                   string,
	followers_count, friends_count, listed_count, favourites_count, statuses_count: i64,
	lang:                                                                           string,
	verified, protected:                                                            bool,
}
Tweet :: struct {
	metadata:                      Tweet_Metadata,
	created_at:                    string,
	id:                            i64,
	id_str, text, source:          string,
	truncated:                     bool,
	retweet_count, favorite_count: i64,
	lang:                          string,
	user:                          Twitter_User,
}
Twitter :: struct {
	statuses: []Tweet,
}
Citm_Event :: struct {
	id:                    i64,
	name:                  string,
	subTopicIds, topicIds: []i64,
}
Citm_Price :: struct {
	amount, audienceSubCategoryId, seatCategoryId: i64,
}
Citm_Perf :: struct {
	eventId, id, start: i64,
	venueCode:          string,
	prices:             []Citm_Price,
}
Citm :: struct {
	areaNames, blockNames: map[string]string,
	events:                map[string]Citm_Event,
	performances:          []Citm_Perf,
	topicSubTopics:        map[string][]i64,
	venueNames:            map[string]string,
}
Canada_Geo :: struct {
	type:        string,
	coordinates: [][][2]f64,
}
Canada_Feat :: struct {
	type:     string,
	geometry: Canada_Geo,
}
Canada :: struct {
	type:     string,
	features: []Canada_Feat,
}

Color :: enum u8 {
	Red,
	Green = 5,
	Blue,
}
Inner :: struct {
	x: i32,
	y: string `json:"why"`,
}
Pet :: union {
	Inner,
	i64,
	string,
}
Link :: struct {
	id:   i64,
	next: ^Link,
}
Kinds :: struct {
	a:     i8,
	b:     i16,
	c:     i32,
	d:     u8,
	e:     u16,
	f:     u32,
	g:     u64,
	h:     f32,
	i:     f64,
	j:     bool,
	k:     b32,
	l:     string,
	m:     cstring,
	n:     Color,
	o:     bit_set[Color],
	p:     [3]u8,
	q:     []Inner,
	r:     [dynamic]string,
	s:     map[string]i64,
	t:     map[i32]string,
	u:     map[Color]bool,
	v:     Maybe(i64),
	w:     Maybe(i64),
	x:     ^i64,
	y:     ^i64,
	z:     Pet,
	aa:    Pet,
	bb:    Pet,
	cc:    Pet,
	dd:    Link,
	skip:  i64 `json:"-"`,
	empty: struct {},
	text:  string `json:"t e x t"`,
	full:  i64 `json:"full,omitempty"`,
}

directed_kinds :: proc() -> Kinds {
	n := new_clone(i64(77))
	list := make([]Inner, 2)
	list[0], list[1] = {1, "a"}, {2, ""}
	return Kinds {
		a = -8,
		b = -300,
		c = -70000,
		d = 200,
		e = 60000,
		f = 4000000000,
		g = max(u64),
		h = 1.5,
		i = 0.1,
		j = true,
		k = true,
		l = "esc \" \\ \n \t \x01 é 日本 😀 /",
		m = "c",
		n = .Blue,
		o = {.Red, .Blue},
		p = {1, 2, 3},
		q = list,
		r = {"x", "y"},
		s = {"b" = 2, "a" = 1},
		t = {10 = "ten", 9 = "nine", -1 = "m"},
		u = {.Blue = true, .Red = false},
		v = 5,
		x = n,
		z = i64(9),
		aa = "s",
		bb = Inner{3, "z"},
		dd = {1, new_clone(Link{id = 2})},
		text = "t",
		full = 1,
	}
}

Hooked_Arm :: proc(name: string, value: any)

marshal_values :: proc(out_dir: string, arm: Hooked_Arm) {
	dir := os.args[1]
	load :: proc($T: typeid, read: proc(src: []u8, v: ^T), dir, name: string) -> T {
		src, err := os.read_entire_file(fmt.tprintf("%s/%s", dir, name), context.allocator)
		assert(err == nil, name)
		v: T
		read(src, &v)
		return v
	}
	logs := load(Logs, read_logs, dir, "logs.json")
	twitter := load(Twitter, read_twitter, dir, "corpus/twitter.json")
	citm := load(Citm, read_citm, dir, "corpus/citm_catalog.json")
	canada := load(Canada, read_canada, dir, "corpus/canada.json")
	kinds := directed_kinds()
	arm("logs", logs)
	arm("twitter", twitter)
	arm("citm", citm)
	arm("canada", canada)
	arm("kinds", kinds)
	_ = out_dir
}

write_text :: proc(name: string, text: []u8) {
	assert(os.write_entire_file(fmt.tprintf("%s/%s", os.args[2], name), text) == nil, name)
}
