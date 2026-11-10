package model_oracle

import "core:fmt"
import "core:os"
import "core:strings"
import core "../../../core"
import typed "../../../core/typed"
import json "../.."
import model "../../../core/model"

// The models `pydantic_diff.py` declares in pydantic, loaded here. Reads the bodies of the file named by the first
// argument, one per line, loads each with repeats taken as the second argument says (`last` or `refuse`), and writes
// for each line its errors as `pointer kind` pairs separated by tabs, in the order the load found them, or `fatal kind`
// for a load that ended at its first error.

Mode :: enum {
	Fast,
	Slow,
}

Address :: struct {
	street: string,
	floor:  i8,
}

Cat :: struct {
	lives: int `model:"0..=9"`,
}

Dog :: struct {
	bark: string `model:"len>=1"`,
}

Profile :: struct {
	id:    i64 `model:"read_only"`,
	name:  string `model:"len>=1,len<=8"`,
	age:   int `model:"0..=150"`,
	score: f64 `model:">=0,<=1"`,
	step:  int `model:"multiple_of=5"`,
	mode:  Mode,
	pair:  [2]int,
	nick:  Maybe(string) `model:"len>=2"`,
	tags:  []string `model:"optional,len<=2"`,
	home:  Address,
	level: int,
	count: map[string]int `model:"optional,len<=2"`,
	pet:   union {
		Cat,
		Dog,
	} `model:"optional"`,
}

main :: proc() {
	if len(os.args) != 3 || os.args[2] != "last" && os.args[2] != "refuse" {
		fmt.eprintln("usage: oracle BODIES last|refuse")
		os.exit(2)
	}
	dups := core.Duplicates.Last if os.args[2] == "last" else .Refuse
	data, read_err := os.read_entire_file(os.args[1], context.allocator)
	if read_err != nil {
		fmt.eprintln("cannot read", os.args[1])
		os.exit(2)
	}
	reg := model.Registry {
		naming = {union_tag = "type"},
	}
	model.register(&reg, Address, model.Extra.Forbid)
	model.register(&reg, Profile, "level", 7)
	m, err := model.compile(&reg, Profile, json.reads(.Json))
	if err != nil {
		fmt.eprintln("compile:", err)
		os.exit(2)
	}
	out: strings.Builder
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		free_all(context.temp_allocator)
		p: Profile
		sink := typed.Sink{max_errors = 1000}
		loaded := model.load(&m, transmute([]u8)line, &p, &sink, dups, context.temp_allocator)
		if f, faulted := loaded.(core.Fault); faulted {
			fmt.sbprintf(&out, "fatal %v\n", f.kind)
			continue
		}
		if sink.fatal.kind != .None {
			fmt.sbprintf(&out, "fatal %v\n", sink.fatal.kind)
			continue
		}
		for e, i in sink.entries {
			if i > 0 {
				strings.write_byte(&out, '\t')
			}
			for s in e.path {
				#partial switch v in s {
				case core.Name:
					fmt.sbprintf(&out, "/%s", string(v))
				case core.Index:
					fmt.sbprintf(&out, "/%d", int(v))
				}
			}
			fmt.sbprintf(&out, " %v", e.kind)
		}
		strings.write_byte(&out, '\n')
	}
	os.write(os.stdout, out.buf[:])
}
