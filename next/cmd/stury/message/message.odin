package message

// The text of the command line's messages: the errors it prints, the errors its filters raise and the lines
// `--explain` writes. A message is a format string and the values that fill it, as `core:fmt` has it, with only the
// verbs those messages use, so the command line does not link `core:fmt`:
//
//	%s, %v  a string, a cstring, a byte slice, an integer, or an enum by name (a union by its variant)
//	%d      an integer, with an optional width that pads it with zeros on the left
//	%q      a string or a byte slice in double quotes, with `core:io`'s escapes
//	%c      the character whose code an integer is
//	%%      a percent sign
//
// A verb with no value left to fill it is written as `%!(MISSING ARGUMENT)`, and a value no verb takes does not appear.

import "base:runtime"
import "core:io"
import "core:os"
import "core:reflect"
import "core:strconv"
import "core:strings"

// `format` filled with `args`, on `allocator`.
build :: proc(format: string, args: ..any, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write(&b, format, ..args)
	return strings.to_string(b)
}

// `build` on the temporary allocator.
build_temp :: proc(format: string, args: ..any) -> string {
	return build(format, ..args, allocator = context.temp_allocator)
}

// Writes `format` filled with `args` at the end of `b`.
write :: proc(b: ^strings.Builder, format: string, args: ..any) {
	rest, next := format, 0
	for {
		at := strings.index_byte(rest, '%')
		if at < 0 {
			break
		}
		strings.write_string(b, rest[:at])
		rest = rest[at + 1:]
		width := 0
		for len(rest) > 0 && '0' <= rest[0] && rest[0] <= '9' {
			width = width * 10 + int(rest[0] - '0')
			rest = rest[1:]
		}
		assert(len(rest) > 0, "a format ends in a lone %")
		verb := rest[0]
		rest = rest[1:]
		switch {
		case verb == '%':
			strings.write_byte(b, '%')
		case next >= len(args):
			strings.write_string(b, "%!(MISSING ARGUMENT)")
		case:
			write_value(b, args[next], verb, width)
			next += 1
		}
	}
	strings.write_string(b, rest)
}

// Writes `format` filled with `args` to standard error, in one write.
write_stderr :: proc(format: string, args: ..any) {
	os.write_string(os.stderr, build_temp(format, ..args))
}

// Writes `format` filled with `args` to standard output, in one write.
write_stdout :: proc(format: string, args: ..any) {
	os.write_string(os.stdout, build_temp(format, ..args))
}

@(private = "file")
write_value :: proc(b: ^strings.Builder, value: any, verb: u8, width: int) {
	if value == nil {
		strings.write_string(b, "<nil>")
		return
	}
	switch verb {
	case 'q':
		text, ok := text_of(value)
		assert(ok, "%q takes a string")
		io.write_quoted_string(strings.to_writer(b), text)
	case 'c':
		code, ok := reflect.as_i64(value)
		assert(ok, "%c takes an integer")
		strings.write_rune(b, rune(code))
	case 'd':
		write_integer(b, value, width)
	case 's', 'v':
		write_plain(b, value)
	case:
		panic("a format has a verb that message does not write")
	}
}

// The characters of a string, a cstring or a byte slice.
@(private = "file")
text_of :: proc(value: any) -> (text: string, ok: bool) {
	if bytes, is_bytes := value.([]u8); is_bytes {
		return string(bytes), true
	}
	return reflect.as_string(value)
}

@(private = "file")
write_plain :: proc(b: ^strings.Builder, value: any) {
	if text, ok := text_of(value); ok {
		strings.write_string(b, text)
		return
	}
	#partial switch _ in runtime.type_info_base(type_info_of(value.id)).variant {
	case runtime.Type_Info_Enum:
		if name := reflect.enum_string(value); name != "" {
			strings.write_string(b, name)
		} else {
			strings.write_string(b, "%!(BAD ENUM VALUE=")
			write_integer(b, value, 0)
			strings.write_byte(b, ')')
		}
	case runtime.Type_Info_Union:
		if variant := reflect.get_union_variant(value); variant != nil {
			write_plain(b, variant)
		} else {
			strings.write_string(b, "nil")
		}
	case runtime.Type_Info_Integer:
		write_integer(b, value, 0)
	case:
		panic("a %s or %v value that message does not write")
	}
}

@(private = "file")
write_integer :: proc(b: ^strings.Builder, value: any, width: int) {
	digits: [24]u8
	core := runtime.type_info_core(type_info_of(value.id))
	assert(reflect.is_integer(core), "%d takes an integer")
	text: string
	if reflect.is_unsigned(core) {
		u, _ := reflect.as_u64(value)
		text = strconv.write_uint(digits[:], u, 10)
	} else {
		i, _ := reflect.as_i64(value)
		text = strconv.write_int(digits[:], i, 10)
	}
	width := width
	if text[0] == '-' {
		strings.write_byte(b, '-')
		text, width = text[1:], width - 1
	}
	for _ in len(text) ..< width {
		strings.write_byte(b, '0')
	}
	strings.write_string(b, text)
}
