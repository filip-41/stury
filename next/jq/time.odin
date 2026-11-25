package jq

import "stury:lib/query"

// jq's time builtins: gmtime, localtime, mktime, strftime, strflocaltime, strptime, and stury's fromrfc3339 and
// torfc3339, each over the engine's calendar. The local zone is the hooks'.

@(private)
zones_of :: proc(m: ^Machine) -> query.Zones {
	if m.hooks != nil && m.hooks.zone != nil {
		return {data = m.hooks.data, at = m.hooks.zone}
	}
	return {}
}

@(private)
v_time :: proc(m: ^Machine, b: ^Builtin, x: query.Value, args: []query.Value) -> (res: query.Value, status: query.Status) {
	h := m.h
	switch b.name {
	case "gmtime":
		res, status = query.break_time(h, x, {}, false)
	case "localtime":
		res, status = query.break_time(h, x, zones_of(m), true)
	case "mktime":
		res, status = query.make_time(h, x)
	case "strftime":
		res, status = query.format_time(h, x, args[0], {}, false)
	case "strflocaltime":
		res, status = query.format_time(h, x, args[0], zones_of(m), true)
	case "strptime":
		res, status = query.parse_time(h, x, args[0], zones_of(m))
	case "fromrfc3339":
		res, status = query.rfc3339_seconds(h, x)
	case:
		res, status = query.rfc3339_text(h, x)
	}
	if status == .Error && h.err.op == .Time {
		return query.NULL, raise_time_error(m, b)
	}
	return res, status
}

// The engine's time error in the heap, raised as `b`'s message.
@(private)
raise_time_error :: proc(m: ^Machine, b: ^Builtin) -> query.Status {
	e := query.take_error(m.h)
	defer query.destroy_error(m.h, &e)
	out := make([dynamic]u8, m.h.allocator)
	defer delete(out)
	write_time_error(&out, b.name, &e)
	return raise_owned_text(m, string(out[:]))
}
