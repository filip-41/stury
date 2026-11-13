package yaml

// The typed write of YAML: `marshal` writes a value by the token write, as block style or, when the layout is compact, as
// one line of flow style.

import core "../core"
import typed "../core/typed"
import cw "../core/write"

// Writes `value` as YAML into new bytes from `allocator`, as `write` says: a struct or map as a mapping, a list as a
// sequence, a byte string as `!!binary` and its base64, which `unmarshal` reads back into a
// `typed.Bytes`. A pretty layout writes block style with `write.indent` spaces a level, and a compact one flow style on
// one line. The text ends with a line end when it is pretty. The form with no plan builds and frees one for the call,
// and a plan made once with `plan_make` is the form for many writes.
marshal :: proc {marshal_once, cw.marshal}

@(private)
marshal_once :: proc(value: any, spec := Spec.Yaml_1_2, opts := Options{}, write := core.Write_Options{}, allocator := context.allocator) -> ([]u8, core.Error) {
	nothing: any
	v := typed.marshal_target(value, &nothing)
	plan, refusal := plan_make(v.id, spec, opts)
	return typed.marshal_planned(&plan, refusal, v.data, write, allocator)
}
