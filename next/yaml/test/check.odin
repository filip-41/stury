package yaml_tests

import "core:testing"
import "stury:lib/core/tape"
import "stury:lib/schema/check"
import "stury:lib/schema/rules"
import "stury:testkit"
import "stury:yaml"

// Streaming `yaml.check` vs `check.check_document(yaml.build)` parity across Core Schema types, aliases, tags,
// `!!binary`, `.Refuse` duplicate keys, and `Yaml_Merge`.
@(test)
yaml_check_matches_document_check :: proc(t: ^testing.T) {
	testkit.deadline(t)
	d: rules.Description
	d.allocator = context.allocator
	defer rules.description_destroy(&d)

	name_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.String}, rules = {min_length = 2}, array = -1, object = -1})
	port_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Integer}, rules = {minimum = "1", maximum = "65535"}, array = -1, object = -1})
	ratio_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Number}, array = -1, object = -1})
	item_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.String}, array = -1, object = -1})
	append(&d.arrays, rules.Array{items = item_n})
	tags_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Array}, rules = {unique = true}, array = 0, object = -1})
	home_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.String, .Null}, array = -1, object = -1})
	false_n := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {}, array = -1, object = -1})

	members := make([]rules.Member, 5)
	members[0] = {name = "name", node = name_n, required = true}
	members[1] = {name = "port", node = port_n, required = true}
	members[2] = {name = "ratio", node = ratio_n}
	members[3] = {name = "tags", node = tags_n}
	members[4] = {name = "home", node = home_n}
	append(&d.objects, rules.Object{members = members, additional = false_n, keys = rules.NONE})

	root := rules.Node_Index(len(d.nodes))
	append(&d.nodes, rules.Node{kinds = {.Object}, array = -1, object = 0})
	d.root = root

	plan, cerr := check.compile(&d)
	testing.expect_value(t, cerr.kind, check.Error_Kind.None)
	defer check.plan_destroy(&plan)

	Case :: struct {
		input: string,
		valid: bool,
		dups:  tape.Duplicates,
	}
	cases := [?]Case {
		{"name: web\nport: 0x1F\nratio: .5\ntags: [a, 'b']\nhome: ~\n", true, .Default},
		{"{name: 'yes', port: !!int \"7\", tags: &t [x], home: /srv}\n", true, .Default},
		{"# head\nport: 8080 # inline\nname: |\n  block\n", true, .Default},
		{"name: web\nport: 0o17\n\"1\": ignored_num_is_diff_wait\n", false, .Default},
		{"name: \"x\"\nport: 70000\ntags: [a, 3]\nextra: ~\n", false, .Default},
		{"name: yes\nport: 1.5\n", false, .Default},
		{"port: 1\ntags: [a, a]\n", false, .Default},
		{"- name\n- port\n", false, .Default},
		{"name: &n 5\nport: *n\nhome: *n\n", false, .Default},
		{"name: \"ab\"\nname: web\nport: 80\n", false, .Refuse},
		{"name: \"x\"\nname: web\nport: 80\n", true, .Last},
		{"name: web\nname: \"x\"\nport: 80\n", true, .First},
		{"name: [unclosed\n", false, .Default},
	}

	for c in cases {
		src := transmute([]u8)c.input
		opts := check.Options{dups = c.dups}

		r_stream := yaml.check(src, &plan, .Yaml_1_2, opts)
		defer check.result_destroy(&r_stream)
		testing.expectf(t, r_stream.valid == c.valid, "%q: stream valid=%v want %v", c.input, r_stream.valid, c.valid)

		sink_s: check.Sink
		check.sink_init(&sink_s)
		defer check.sink_destroy(&sink_s)
		r_ss := yaml.check(src, &plan, .Yaml_1_2, opts, &sink_s)
		defer check.result_destroy(&r_ss)
		testing.expect_value(t, r_ss.valid, c.valid)

		doc, berr := yaml.build(src, .Yaml_1_2, {dups = c.dups})
		defer yaml.destroy(&doc)
		if berr != nil {
			want_err := check.Error_Kind.Duplicate_Key if c.dups == .Refuse else check.Error_Kind.Walk
			testing.expectf(t, !r_ss.valid && r_ss.err.kind == want_err, "%q: got err %v want %v", c.input, r_ss.err.kind, want_err)
			continue
		}

		sink_d: check.Sink
		check.sink_init(&sink_d)
		defer check.sink_destroy(&sink_d)
		r_doc := check.check_document(&doc, &plan, opts, &sink_d)
		defer check.result_destroy(&r_doc)
		testing.expect_value(t, r_ss.valid, r_doc.valid)
		testing.expect_value(t, len(sink_s.entries), len(sink_d.entries))
		for k in 0 ..< min(len(sink_s.entries), len(sink_d.entries)) {
			testing.expect_value(t, sink_s.entries[k].kind, sink_d.entries[k].kind)
		}
	}

	// Merge keys schema parity.
	merge_in := transmute([]u8)string("def: &d {name: web, port: 80}\nbase:\n  <<: *d\n")
	d2: rules.Description
	d2.allocator = context.allocator
	defer rules.description_destroy(&d2)
	any_n := rules.Node_Index(len(d2.nodes))
	append(&d2.nodes, rules.Node{kinds = rules.EVERY_KIND, array = -1, object = -1})
	base_n := rules.Node_Index(len(d2.nodes))
	m2 := make([]rules.Member, 2)
	m2[0] = {name = "name", node = any_n, required = true}
	m2[1] = {name = "port", node = any_n, required = true}
	append(&d2.objects, rules.Object{members = m2, additional = any_n, keys = rules.NONE})
	append(&d2.nodes, rules.Node{kinds = {.Object}, array = -1, object = 0})
	mr := make([]rules.Member, 2)
	mr[0] = {name = "def", node = any_n}
	mr[1] = {name = "base", node = base_n, required = true}
	append(&d2.objects, rules.Object{members = mr, additional = any_n, keys = rules.NONE})
	r2 := rules.Node_Index(len(d2.nodes))
	append(&d2.nodes, rules.Node{kinds = {.Object}, array = -1, object = 1})
	d2.root = r2
	plan2, _ := check.compile(&d2)
	defer check.plan_destroy(&plan2)

	res_plain := yaml.check(merge_in, &plan2, .Yaml_1_2)
	defer check.result_destroy(&res_plain)
	testing.expect(t, !res_plain.valid)

	res_merge := yaml.check(merge_in, &plan2, .Yaml_Merge)
	defer check.result_destroy(&res_merge)
	testing.expect(t, res_merge.valid)
}
