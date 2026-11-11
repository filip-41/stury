// A type plan as one array of records, which `Hook_Regs.b` walks through. A struct's block holds one record per member
// in the type's order, then a `Never` record, and a list's, a map's or a pointer's holds its element's record, then a
// `Never` record. The record before `b` is always the one the next value is read by, so a value needs no frame lookup.
package typed

import "base:intrinsics"
import "base:runtime"
import "core:io"
import "core:mem/virtual"
import "core:reflect"
import "core:slice"
import "core:strings"
import core ".."
import rules "../rules"

// What a value is read as. The kinds up to `F64` are the ones the hook's hot compares take. The rest reach the cold
// paths, since every hot compare fails for them, so a type that has none of them pays nothing for them.
Read_Kind :: enum u8 {
	Never,
	Struct,
	Required, // a struct with `required` members, or one that captures unknown members, opened as a struct is
	Slice,
	Dynamic,
	Map,
	String,
	Bool,
	I8,
	I16,
	I32,
	I64,
	U8,
	U16,
	U32,
	U64,
	F32,
	F64,
	Array, // placed past `F64` so the numeric kinds keep the values the hook's compares are laid out for
	Enum,
	Ptr, // `Meta.whole` for a `Maybe` of a pointer, whose element is replaced where a pointer's is read into
	Maybe, // holds its element in place, then a tag
	Union,
	Any,
	Hook,
	Raw,
	Value, // a `core.Value`, built from the text of whatever the member holds
	Number_Text,
	Number,
	Scalar,
	Cstring,
	Bool_Wide,
	Bit_Set,
	Bit_Elem, // an element of the `Bit_Set` whose block holds it
	Fixed_List,
	Inside, // a token of a value read whole
	Checked, // a description's node, judged by a `Check` and stored nowhere
	Before, // a model's member whose value a `before` procedure rewrites first, which only a `Check` reads
}

// The hook's number arm tests `U8 ..= U64` as one aligned block and `I8 ..= I32` and `F32 ..= F64` as ranges.
#assert(int(Read_Kind.U8) % 4 == 0 && int(Read_Kind.I8) == 8)

// A member's or element's record. `stride` is what a value moves `Hook_Regs.c` by: the element size in a list, 0
// elsewhere. `first` is a container's starting `Hook_Regs.b`.
Field :: struct {
	using key: core.Expected_Key,
	kind:      Read_Kind,
	omit:      bool, // a member a write leaves out when it is empty, the tag's `omitempty`
	key_size:  u8, // what a write stores of `key`, 0 for a member it must look at first: `omit`, the end, or a name to escape
	lists:     bool, // a struct a write lists before it writes, since it captures unknown members
	offset:    u32,
	stride:    u32,
	meta:      u32,
	first:     ^Field,
}
#assert(size_of(Field) == 72)

// The longest key text a write stores in line. A longer one is written through the format's string writer.
KEY_SIZE_MAX :: 240

// What only the cold paths read, indexed like `Plan.fields`.
Meta :: struct {
	name:       string,
	type:       typeid, // what a refusal of a value read by the record names
	map_info:   ^runtime.Map_Info,
	enum_info:  ^runtime.Type_Info_Enum,
	arms:       []Arm, // a `Union`'s
	read:       Unmarshal_Hook, // a `Hook`'s
	before:     ^Before, // a `Before`'s
	write:      Marshal_Hook, // a `Hook`'s
	data:       rawptr, // a `Hook`'s `Type_Hook.data`
	required:   []i32, // on a struct's `Never` record, the members that must be present
	required_end: i32, // on a struct's own record, one past its last `required` member: a cursor at or past it has passed every one
	names:      u64, // a struct's members' `name_bit`s, so most keys it does not hold are known by one test
	lower:      i64, // a `Bit_Set`'s lowest element
	count:      u32, // a fixed array's length, a `Fixed_List`'s capacity, a `Bit_Set`'s bit count
	size:       u32,
	elem_size:  u32,
	align:      u32,
	tag:        u32, // a `Maybe`'s or `Union`'s tag offset, a `Fixed_List`'s length offset
	tag_size:   u8, // a `Union`'s, 0 for a pure maybe
	key_kind:   Read_Kind, // a `Map`'s key, a `Hook`'s own kind, which says when `omitempty` finds it empty
	block:      i32,
	members:    i32, // a struct's member count
	capture:    i32, // on a struct's `Never` record, the record of the map that captures unknown members, or -1
	whole:      bool,
	list:       bool, // `block` is a list's or map's, so `first` is past its element's record
	zeroed:     bool, // a list's new elements must start zeroed, since their readers may leave bytes unwritten
	tagged:     bool, // a `Union` that reads objects by `union_tag`, or such a union's named struct arm
	union_tag:  string, // the member a tagged `Union` and its named struct arms name the arm by
	no_nil:     bool, // a `Union` that has no nil, or a pointer member that refuses null
	access:     Access, // a struct member's, under a model
	omit_empty: bool, // a member the tag's `omitempty` leaves out when it is empty, where `Field.omit` may be a model's
	optional:   bool, // a model's member that a load does not require
	bit:        i8, // a model's member's bit in its struct's `Fields_Set`, -1 for one the load does not read
	forbid:     bool, // a struct whose model refuses the members it does not name
	counted:    bool, // on a checked object's record, its leaf bounds how many members the object holds
	model:      ^Struct_Model, // on a struct's records, what a load does with it, nil for none
	owner:      ^Struct_Model, // on a model's member's record, its struct's model, nil for none
	rule_set:   i32, // 1 + the record's leaf in `Plan.leaves`, and for a type's plan its set in `Plan.rule_sets`, 0 for none
	default:    i32, // on a model's member's record, 1 + its default in `owner.defaults`, 0 for none
}

// A `Checked` record's use of its node, beside its `Meta`, so a type plan's records stay as they are. `items` is the
// `Hook_Regs.b` its array's elements start at, `additional` that of the record of the members no record names, and
// `keys` 1 + the leaf of its member names, each 0 for none. `inside` says a rule reads an element. `site` is the keyword
// steps from the record that holds it to its own rules, `$ref`s included.
Use :: struct {
	items, additional, keys: i32,
	site:                    []core.Step,
	step:                    bool, // a prefix record, which moves the cursor on to the next element's
	inside:                  bool,
	node:                    Markup_Node, // the node of a markup element a member record reads
	// The record of the members the compiled `^regex.Regex` `regex` matches and no other record names, 0 for none.
	pattern:                 i32,
	regex:                   rawptr,
	// A held record's arms, which judge its value as the check reads it, empty for any other record.
	applies:                 []Apply,
	// The arms a check with no sink reads in their place, with the `allOf` and `$ref` arms conjoined, nil for the same.
	verdict:                 []Apply,
	// The ids the held uses a check with no sink, and one with a sink, judges alike share, by arms that read the same
	// records the same way, 0 for a use with no arms.
	judging:                 u32,
	judging_all:             u32,
	// An object record's `dependentRequired`, which its close judges by the members seen.
	requires:                []Requires,
}

// A member of an object record's block whose presence asks for the members `wants`, as places in the block.
@(private)
Requires :: struct {
	trigger: i32,
	wants:   []i32,
}

// A union's arm: the value classes it takes, its tag value, and its tag name when the tag names it.
Arm :: struct {
	classes: bit_set[Value_Class],
	tag:     u32,
	fields:  i32,
	name:    string,
}

// The classes of value a union picks its arm by.
Value_Class :: enum u8 {
	Bool,
	Number,
	String,
	Object,
	Array,
}

@(private)
EVERY_CLASS :: bit_set[Value_Class]{.Bool, .Number, .String, .Object, .Array}

// How a plan reads an enum: `.Name` as a member's name, `.Int` as its backing integer.
Enum_Spelling :: enum u8 {
	Name,
	Int,
}

// Whether a plan reads and writes the enum `info` as its integers, which a plan built with `.Int` does and a model's
// plan does for an enum it gives no names.
enum_by_number :: #force_inline proc "contextless" (plan: ^Plan, info: ^runtime.Type_Info_Enum) -> bool {
	return plan.enums == .Int || len(info.names) == 0
}

// The enum of `ti` as the plan spells it: the type's own, or the plan's copy with the names its model gives. Two members a
// model spells alike are refused as `.Bad_Tag`, with the enum as `want.type` and the name as `want.text`.
@(private)
enum_of :: proc(b: ^Builder, ti: ^runtime.Type_Info) -> ^runtime.Type_Info_Enum {
	info := &runtime.type_info_base(ti).variant.(runtime.Type_Info_Enum)
	if b.model == nil || b.model.enum_names == nil {
		return info
	}
	room := size_of(runtime.Type_Info_Enum) + len(info.names) * size_of(string)
	memory, failed := runtime.mem_alloc(room, align_of(runtime.Type_Info_Enum))
	if failed != nil {
		refuse_plan(b, .No_Memory)
		return info
	}
	owned(b, memory)
	copied := (^runtime.Type_Info_Enum)(raw_data(memory))
	copied^ = info^
	names := ([^]string)(&memory[size_of(runtime.Type_Info_Enum)])[:len(info.names)]
	copy(names, info.names)
	copied.names = nil
	by_name, err := b.model.enum_names(b.model, ti.id, names)
	if err != nil {
		refuse_plan(b, .No_Memory)
	}
	if !by_name {
		return copied
	}
	for &name, i in names {
		if b.err.kind == .None && slice.contains(names[:i], name) {
			refuse_plan(b, .Bad_Tag, text = name)
			b.err.want.type = ti.id
		}
		name = name if name == info.names[i] else owned_copy(b, name)
	}
	copied.names = names
	return copied
}

// The name a type's arm of a union goes by in place of its type name.
Tag_Name :: struct {
	type: typeid,
	name: string,
}

// One whole value a `Type_Hook` reads. `text` is the value as the format spells it, and `decoded` a string's text
// decoded, or `text` for any other kind. Both live for the call.
Hook_Value :: struct {
	kind:    core.Kind,
	text:    string,
	decoded: string,
}

// Reads `v` into `dest`, a value of the hook's type that holds what the target held, allocating with `allocator`. Nil
// reads it, and a kind refuses it at the value.
Unmarshal_Hook :: #type proc(v: Hook_Value, dest: rawptr, allocator: runtime.Allocator) -> Maybe(core.Typed_Error_Kind)

// Answers what to write in place of `v`, a value of the hook's type: any value, which is written as a value of its own
// type, through hooks too, and nil writes a null. A value the call must allocate comes from `allocator`, which lasts as
// long as the write. A kind refuses the value.
Marshal_Hook :: #type proc(v: rawptr, allocator: runtime.Allocator) -> (stand_in: any, refuse: core.Typed_Error_Kind)

// A type read or written by the caller's procs instead of by the plan. A nil `read` or `write` refuses the type on that
// side as `.Unsupported`, at the value. `data` is `context.user_ptr` during a call of either when it is not nil.
// `carrier` is a type whose values are the values `read` takes, which a union's arm of the hook's type picks by, nil for
// a hook that takes every value.
Type_Hook :: struct {
	type:    typeid,
	read:    Unmarshal_Hook,
	write:   Marshal_Hook,
	data:    rawptr,
	carrier: typeid,
}

// How a field with no name of its own in its tag is spelled from its Odin name.
Rename :: enum u8 {
	None,
	Camel, // `lastName`
	Pascal, // `LastName`
	Kebab, // `last-name`
	Screaming, // `LAST_NAME`
	Snake, // `last_name`, which an `Ada_Case` enum member is spelled as before any other
}

// What a plan is built with. `union_tag` is the member that names a struct arm of a union with two or more named struct
// arms, and `tag_names` the names that replace the arms' type names.
Plan_Options :: struct {
	enums:     Enum_Spelling,
	// The model whose rules the members' records take, nil for none. A built plan holds nil here, so the plans a write
	// builds for a type met in an `any` hold no rules. A read by the plan does not check them.
	model:     ^Model_Rules,
	union_tag: string,
	tag_names: []Tag_Name,
	hooks:     []Type_Hook,
	rename:    Rename,
	// Builds a description's plan as a check reads it: each record `Checked`, judging its use of its node.
	checking:  bool,
}

// A model's rules, which a plan built with them asks for at each struct member and at each value no member holds, and
// the compiler of each rule set the plan keeps.
Model_Rules :: struct {
	// The rules of member `field`, of type `type` and tag `tag`, of struct `owner`. With `owner` nil, of a value of `type`
	// that no member holds: the root, a list's element, a map's value, a union's arm.
	member:  proc(m: ^Model_Rules, owner: typeid, field: string, type: typeid, tag: string) -> Member_Rule,
	// Whether struct `owner` refuses the members it does not name.
	forbids: proc(m: ^Model_Rules, owner: typeid) -> bool,
	compile: Rule_Compiler,
	// What a load's plan records of each struct it lays out, `load_struct` for a load's plan and nil for any other, so
	// a program that loads no model links none of it.
	structs: proc(b: ^Builder, owner: typeid, at: i32, f: ^Field, m: ^Meta, members: []Member, layout: ^Struct_Layout),
	// The validators of struct `owner`, which run at its close once none of its members failed, nil for none.
	validators: proc(m: ^Model_Rules, owner: typeid) -> []Validator,
	// How the model spells the members of enum `type`: `names` holds the type's own in its order, which it may replace,
	// and false spells them as their integers. Nil keeps the plan's `enums`.
	enum_names: proc(m: ^Model_Rules, type: typeid, names: []string) -> (by_name: bool, err: runtime.Allocator_Error),
	// How union `type` is read: by the member `tag` that names its struct arms where `set`, in place of
	// `Plan_Options.union_tag`, or by its first arm that reads a value, which takes arms that read one kind alike.
	unions:     proc(m: ^Model_Rules, type: typeid) -> (tag: string, set: bool, first_match: bool),
	// The check plan that judges a value of `type`, its rules `unique` when they say so, once a load read it, nil for none.
	judge:      proc(m: ^Model_Rules, type: typeid, unique: bool) -> ^Plan,
	// How a load runs them, `validate_closed`, which a registered validator names, so a load with none links none of it.
	close:      Close_Validators,
	// Whether the plan is a load's, whose structs settle at their close. Any other model plan holds only the validators.
	loading: bool,
	// The rule sets and leaves of the model's plan of the same type, which this plan takes in place of its own, nil for
	// none. Each of this plan's rule sets is one of them.
	rule_sets: []rules.Rules,
	leaves:    []rules.Leaf,
}

// What a model's plan serves. `Whole` holds every member and serves validate, the schemas and writes, and reads nothing.
// `Load` leaves out the read_only members and reads only as a check, into a zeroed target, as a model's load does.
Model_Plan :: enum u8 {
	None,
	Whole,
	Load,
}

// What a load does with one of a model's structs. At its close it sets the `Fields_Set` at `fields_set` less one, if
// that is not zero, and gives each member of `defaults` the input left out its default. A key of `read_only` is a
// read_only member's, which the load skips, or refuses under the struct's `forbid`. `afters` and `checks` are the
// validators of its members and of the struct, which run at its close.
Struct_Model :: struct {
	settle:     proc "contextless" (h: ^Reader, sm: ^Struct_Model, f: ^Frame, owner: ^Field, regs: core.Hook_Regs, at: u64) -> (core.Typed_Error_Kind, bool),
	validate:   Close_Validators, // a load's, nil when the struct has no validator
	fields_set: u32,
	defaults:   []Default,
	read_only:  []string,
	afters:     []After,
	checks:     []Validator,
}

Close_Validators :: #type proc "contextless" (h: ^Reader, sm: ^Struct_Model, f: ^Frame, owner: ^Field, regs: core.Hook_Regs, at: u64, base: uintptr) -> bool

@(private)
Default :: struct {
	member: i32,
	make:   Make_Default,
	data:   rawptr,
}

// Writes a member's default at `dest`, which holds the zero value, from `data`, with the load's allocator.
Make_Default :: #type proc(dest, data: rawptr, allocator: runtime.Allocator) -> runtime.Allocator_Error

// The members a model's load found in the input, one bit each in the order of the load's members. A model refuses a
// struct that holds one and loads more than 128 members.
Fields_Set :: struct {
	bits: [2]u64,
}

// What a model says of a member or a value. `name` replaces the member's name, "" for none, and `refused` is the item
// the model refuses the member for, "" for none. A member that is not `optional` is required, unless it is read only.
Member_Rule :: struct {
	rules:    rules.Rules,
	name:     string,
	alias:    string, // the item that gave `name`, "" for none
	optional: bool,
	skip:     bool, // the member is no part of the model
	access:   Access,
	extra:    bool, // the member takes the members the struct does not name
	not_null: bool, // a pointer member that refuses null
	// What writes the member's default from `data`, nil for none.
	make:     Make_Default,
	data:     rawptr,
	after:    Validator, // judges the member's value once it is read and has passed its rules
	before:   ^Before, // rewrites the member's value before it is read, nil for none
	refused:  string,
}

// Whether a model's member is loaded and dumped, only dumped and never loaded, or only loaded and never dumped.
Access :: enum u8 {
	Read_Write,
	Read_Only,
	Write_Only,
}

// Compiles a rule set for the kinds a node takes into a leaf in `allocator`, or names the keyword it does not judge.
Rule_Compiler :: #type proc(r: rules.Rules, kinds: rules.Kinds, allocator: runtime.Allocator) -> (rules.Leaf, string)

// A plan is a value the caller owns, for one type and one format. `plan_make` builds it and `plan_destroy` frees it. It
// is read only while reading, so a read needs nothing else and any number of reads may share it. A plan is not copied,
// since a copy and the original would free the same memory. It outlives every reader and writer that was given it.
Plan :: struct {
	fields:    []Field,
	// Each of `fields` followed by a `Never` record, the place a key found out of order moves the cursor to when no
	// later key may match by its bytes.
	solo:      []Field,
	meta:      []Meta,
	root:      ^Field,
	// A zeroed value as wide as the widest map value, the value a new entry is inserted with.
	zero:      []u8,
	// The format, and for a format whose writer reads them, the spec and option bytes a write by the plan takes.
	using as:  core.As,
	type:      typeid,
	// What a key's writing adds to its name, `Field.n` less the name's length.
	key_frame: u32,
	// The name bytes of records and of renamed or unescaped names, and the enums a model renames with their names.
	strings:   [dynamic]string,
	allocator: runtime.Allocator,
	// A format whose tokens do not type their values reads a document's node through this, where its plan maker sets it.
	node_read: Node_Read,
	// The format's text reads and the check of a node, copied from its `Format_Reads` by `plan_build`.
	read, check: Text_Read,
	node_check: Node_Read,
	docs:       proc "contextless" () -> rawptr,
	// The format's value writer, which holds its spelling compiled in, where its plan maker sets it.
	marshal:   Marshal_Text,
	// Checks a `Raw` member's text as one value of the format, and the format's `^write.Token_Spelling` a token write by
	// the plan uses, nil for a format with none.
	raw:       proc(v: ^core.Token_View, src: []u8, allocator: runtime.Allocator) -> core.Document_Error,
	tokens:    rawptr,
	// The format's writer of a built value, which a read of a value takes, where its plan maker sets it, and its build
	// of a text, which `write.marshal_value` takes, copied from its `Format_Reads`.
	value_text: Value_Text,
	build:      Text_Build,
	// The options the plan was built with, which its reads and writes take, and so do the plans a write builds for a type
	// met in an `any`.
	using options: Plan_Options,
	// What `plan_make` refused a plan with, which a read or write given the refused plan returns.
	err:       core.Typed_Refusal,
	// A hash of the type, format and options the plan was built from, so a reader that kept what it bound to one plan's
	// records can tell a plan built the same at their address from another made there after the first was destroyed. A
	// description's plan has 0, so a reader binds nothing to one.
	stamp:     u64,
	// The rules of members, which `Meta.rule_set` names.
	rule_sets: []rules.Rules,
	// A check's rules, which `Meta.rule_set` names: of `rule_sets`, in the same order, for a type's plan.
	leaves:    []rules.Leaf,
	// A description's plan's `Use` of each record, by its `Meta` index.
	uses:      []Use,
	// A description's plan's record that reads every value inside a held value, which hands it to the held value's
	// runs, 0 for a plan with no held record.
	fork:      i32,
	// What `leaves` and `uses` allocate: patterns, enum keys, keyword steps and the uses.
	arena:     ^virtual.Arena,
	model_plan: Model_Plan,
}

// Writes the value of `plan`'s type at `value` as `opts` says, to `stream` when it has a procedure, else to new bytes
// from `allocator`.
Marshal_Text :: #type proc(plan: ^Plan, value: rawptr, opts: core.Write_Options, stream: io.Stream, allocator: runtime.Allocator, omits: ^Omits) -> ([]u8, core.Typed_Refusal)

// What a write asks of each member a model's plan marks `Field.omit`, beside the tag's `omitempty`: whether to leave the
// member of record `r` at `at` out.
Omits :: struct {
	call: proc(o: ^Omits, plan: ^Plan, r: ^Field, at: uintptr) -> bool,
}

// Writes the built value `v` in `plan`'s format into new bytes from `allocator`.
Value_Text :: #type proc(plan: ^Plan, v: core.Value, allocator: runtime.Allocator) -> ([]u8, core.Typed_Refusal)

// The members a plan builder names in a refusal's path, the outermost ones when the type nests deeper.
@(private)
TRAIL_MAX :: 32

@(private)
Builder :: struct {
	using options: ^Plan_Options, // the plan's, which own their strings
	p:             ^Plan,
	fields:        [dynamic]Field,
	meta:          [dynamic]Meta,
	blocks:        map[Block_Key]i32,
	ends:          map[i32]i32, // a struct block's `Never` record
	widest:        int,
	err:           core.Typed_Refusal,
	// The names of the members being filled, outermost first, which a refusal reports as its path.
	trail:         [TRAIL_MAX]string,
	depth:         int,
	rule_sets:     [dynamic]rules.Rules,
	leaves:        [dynamic]rules.Leaf,
	uses:          [dynamic]Use,
	// The dynamic scope the record being filled is in, an index of `scopes`, and what `evaluates` made per node and scope.
	scope:         i32,
	scopes:        [dynamic]Scope,
	evaluated:     map[Block_Key]^Evaluates,
	// The conjoined node of each holder whose `allOf` and `$ref` arms conjoin, and the node each pair conjoins into.
	conjoined:     map[rules.Node_Index]Conjoined,
	pairs:         map[[2]rules.Node_Index]rules.Node_Index,
	// The objects whose one pattern their record reads.
	inline:        map[i32]Inline_Pattern,
	// The patterns compiled so far, which every use of one shares.
	programs:      rules.Programs,
	// The objects and arrays whose `additionalProperties` or `items` is an `unevaluatedProperties` or
	// `unevaluatedItems` that `settle_unevaluated` placed there.
	unevaluated:   map[[2]i32]bool,
	// The place in its `allOf` of each member `settle_unevaluated` kept, of a node it dropped one of.
	all_of_at:     map[rules.Node_Index][]int,
}

// An object's one pattern, which its record reads: the expression, the node a member it matches passes, and the
// compiled `^regex.Regex`.
@(private)
Inline_Pattern :: struct {
	expression: string,
	node:       rules.Node_Index,
	regex:      rawptr,
}

// What a block is recorded under for its next use and for a value that holds itself: a type and the rule set its
// element was given, or for a description plan the table (`rules.Array`, `rules.Object`, `rules.Node`,
// `Maybe(rules.Node)`) and the index of the block's shape, with the dynamic scope it was filled in.
@(private)
Block_Key :: struct {
	type:  typeid,
	of:    i32,
	scope: i32,
}

// A format's plan maker, which `core.Services.plans` points at: `plan_build` and what the format's reads and writes add.
Plan_Make :: #type proc(T: typeid, as: core.As, opts: Plan_Options, allocator: runtime.Allocator) -> (Plan, core.Typed_Refusal)

// Builds the plan of `T` for format `as`, by the format's plan maker, allocating with `allocator`. A type the read
// cannot take is an error, with the path to it, and the plan is then the zero value with that error in `err`. `opts`'s
// strings and slices are read here only. A format with no plan maker gets `plan_build`'s plan, and a handle with no services is
// `.Bad_Option`.
plan_make :: proc(T: typeid, as: core.As, opts := Plan_Options{}, allocator := context.allocator) -> (Plan, core.Error) {
	services := core.services_of(as)
	if services == nil {
		err := core.Typed_Refusal{kind = .Bad_Option}
		return {err = err}, core.error_of(err)
	}
	if services.plans != nil {
		made, err := (Plan_Make)(services.plans)(T, as, opts, allocator)
		return made, core.error_of(err)
	}
	made, err := plan_build(T, as, opts, allocator)
	return made, core.error_of(err)
}

// The plan of `T` for format `as` with nothing a format adds: no writer and no document read of its own. A format's
// plan maker starts from it, and so does a write's plan for a type met in an `any`.
plan_build :: proc(T: typeid, as: core.As, opts := Plan_Options{}, allocator := context.allocator) -> (p: Plan, err: core.Typed_Refusal) {
	context.allocator = allocator
	b := plan_start(&p, as, opts)
	p.type = T
	if b.model != nil {
		// The same rule sets in the same order, so a record's set names the other plan's leaf.
		if _, failed := append(&b.rule_sets, ..b.model.rule_sets); failed != nil {
			refuse_plan(&b, .No_Memory)
		}
	}
	if root_block(&b) {
		fill(&b, 0, type_info_of(T), "", 0, 0)
	}
	if b.err.kind == .None {
		refuse_tag_members(&b)
	}
	stamp := plan_stamp(T, as, opts)
	if b.model != nil {
		for m in b.meta {
			stamp_text(&stamp, m.name)
			stamp_mix(&stamp, u64(m.rule_set) | u64(m.access) << 32 | u64(len(m.required)) << 40)
			for k in m.required {
				stamp_mix(&stamp, u64(k))
			}
		}
	}
	err = plan_finish(&b, stamp)
	if err.kind == .None && len(p.rule_sets) > 0 {
		if len(opts.model.leaves) == len(p.rule_sets) {
			// Borrowed: the model frees this plan with its leaves taken back.
			p.leaves = opts.model.leaves
		} else {
			err = plan_leaves(&p, opts.model.compile)
		}
	}
	p.model = nil
	return
}

// Compiles the leaves of a type's plan from its rule sets into the plan's arena. A rule the check does not judge
// refuses the plan as `.Unsupported`, naming its keyword.
@(private)
plan_leaves :: proc(p: ^Plan, compile: Rule_Compiler) -> core.Typed_Refusal {
	leaves, failed := make([]rules.Leaf, len(p.rule_sets))
	p.leaves = leaves
	arena, made := plan_arena(p)
	if failed != nil || !made {
		plan_destroy(p)
		p.err = {kind = .No_Memory}
		return p.err
	}
	for r, i in p.rule_sets {
		refused: string
		if leaves[i], refused = compile(r, rules.EVERY_KIND, arena); refused != "" {
			plan_destroy(p)
			p.err = {kind = .Unsupported, want = {text = refused}}
			return p.err
		}
	}
	return {}
}

// Gives `p` its arena, which `plan_destroy` frees, false when it does not fit in memory.
@(private)
plan_arena :: proc(p: ^Plan) -> (runtime.Allocator, bool) {
	if p.arena != nil {
		return virtual.arena_allocator(p.arena), true
	}
	p.arena = new(virtual.Arena)
	if p.arena == nil || virtual.arena_init_growing(p.arena) != nil {
		free(p.arena)
		p.arena = nil
		return {}, false
	}
	return virtual.arena_allocator(p.arena), true
}

// Gives `p` the text reads and node reads of `reads`, where it holds any.
plan_reads :: proc(p: ^Plan, reads: ^Format_Reads) {
	if reads != nil {
		p.read, p.check, p.node_read, p.node_check = reads.read, reads.check, reads.node_read, reads.node_check
		p.build, p.docs = reads.build, reads.docs
	}
}

// Whether `p` has a `core.Value` member, which reads only with a format's `build`.
plan_has_value :: proc(p: ^Plan) -> bool {
	for f in p.fields {
		if f.kind == .Value {
			return true
		}
	}
	return false
}

// The plan both front ends start from: the format, its typed reads, and the options, which the plan owns.
@(private)
plan_start :: proc(p: ^Plan, as: core.As, opts: Plan_Options) -> Builder {
	readers := as.readers
	p^ = {as = as, key_frame = u32(len(readers.key_open) + len(readers.key_close)), allocator = context.allocator}
	if services := readers.services; services != nil {
		if reads := (^Format_Reads)(services.reads); reads != nil {
			p.read, p.check, p.node_read, p.node_check = reads.read, reads.check, reads.node_read, reads.node_check
			p.build, p.docs = reads.build, reads.docs
		}
		if services.edit != nil {
			p.raw = services.edit.value
		}
		p.tokens = services.tokens
	}
	b := Builder{options = &p.options, p = p}
	hooks, no_hooks := make([]Type_Hook, len(opts.hooks))
	tag_names, no_names := make([]Tag_Name, len(opts.tag_names))
	p.options = {enums = opts.enums, model = opts.model, checking = opts.checking, union_tag = owned_copy(&b, opts.union_tag), rename = opts.rename, hooks = hooks, tag_names = tag_names}
	copy(hooks, opts.hooks)
	for &t, i in tag_names {
		t = {opts.tag_names[i].type, owned_copy(&b, opts.tag_names[i].name)}
	}
	if no_hooks != nil || no_names != nil {
		refuse_plan(&b, .No_Memory)
	}
	return b
}

// Adds the root's block, whose first record the front end fills, then the block a value read whole passes through.
@(private)
root_block :: proc(b: ^Builder) -> bool {
	if reserve_block(b, 4, {}) < 0 {
		return false
	}
	never(b, 1)
	never(b, 2)
	b.fields[2].kind = .Inside
	never(b, 3)
	return true
}

// Sets what records find each other by, once every block is filled, or frees the plan with its first refusal in `err`.
@(private)
plan_finish :: proc(b: ^Builder, stamp: u64) -> core.Typed_Refusal {
	p := b.p
	delete(b.blocks)
	delete(b.ends)
	solo, no_solo := make([]Field, 2 * len(b.fields))
	zero, no_zero := make([]u8, max(b.widest, 1))
	p.solo, p.zero, p.fields, p.meta, p.rule_sets = solo, zero, b.fields[:], b.meta[:], b.rule_sets[:]
	if no_solo != nil || no_zero != nil {
		refuse_plan(b, .No_Memory)
	}
	if b.err.kind != .None {
		err := b.err
		own_names(&err)
		plan_destroy(p)
		p.err = err
		return err
	}
	for i in 0 ..< len(b.fields) {
		m := &b.meta[i]
		if m.block >= 0 {
			b.fields[i].first = &b.fields[int(m.block) + (1 if m.list else 0)]
			// The record a `.Before` keeps reads the same block.
			if m.before != nil && m.before.field.meta == u32(i) {
				m.before.field.first = b.fields[i].first
			}
		}
		if m.members > 0 {
			for &f, j in b.fields[m.block:][:m.members] {
				name := b.meta[int(m.block) + j].name
				m.names |= max(u64) if len(name) == 0 || f.n == 0 else name_bit(name)
			}
		}
	}
	for &f, i in b.fields {
		p.solo[2 * i] = f
		p.solo[2 * i + 1] = b.fields[1]
	}
	p.root = &b.fields[1]
	p.stamp = stamp
	return {}
}

@(private)
plan_stamp :: proc(T: typeid, as: core.As, opts: Plan_Options) -> u64 {
	h := stamp_as(as, opts)
	stamp_mix(&h, transmute(u64)T)
	return h
}

// A hash of the format and the options a plan is built with, which each front end mixes what it reads into.
@(private)
stamp_as :: proc(as: core.As, opts: Plan_Options) -> u64 {
	h := u64(0xcbf29ce484222325)
	stamp_mix(&h, u64(uintptr(rawptr(as.readers.format))))
	stamp_mix(&h, u64(as.max_depth) | u64(as.spec) << 32 | u64(transmute(u8)as.tolerate) << 40)
	for b in as.opts {
		stamp_mix(&h, u64(b))
	}
	stamp_mix(&h, u64(opts.enums) | u64(opts.rename) << 8 | u64(opts.model != nil) << 16 | u64(opts.checking) << 17)
	stamp_text(&h, opts.union_tag)
	for t in opts.tag_names {
		stamp_mix(&h, transmute(u64)t.type)
		stamp_text(&h, t.name)
	}
	for x in opts.hooks {
		stamp_mix(&h, transmute(u64)x.type)
		stamp_mix(&h, u64(uintptr(rawptr(x.read))))
		stamp_mix(&h, u64(uintptr(rawptr(x.write))))
	}
	return h
}

@(private)
stamp_mix :: proc(h: ^u64, x: u64) {
	h^ = (h^ ~ x) * 0x100000001b3
}

@(private)
stamp_text :: proc(h: ^u64, s: string) {
	stamp_mix(h, u64(len(s)))
	for c in transmute([]u8)s {
		stamp_mix(h, u64(c))
	}
}

// Frees what `plan_make` allocated and sets `p` to the zero value.
plan_destroy :: proc(p: ^Plan) {
	context.allocator = p.allocator
	for s in p.strings {
		delete(s)
	}
	delete(p.strings)
	for &m in p.meta {
		delete(m.arms)
		delete(m.required)
	}
	delete(p.fields)
	delete(p.solo)
	delete(p.meta)
	delete(p.zero)
	delete(p.options.hooks)
	delete(p.options.tag_names)
	delete(p.rule_sets)
	delete(p.leaves)
	if p.arena != nil {
		virtual.arena_destroy(p.arena)
		free(p.arena)
	}
	p^ = {}
}

// Adds a block of `n` records and returns its first, or -1 with the plan refused. The block is recorded under `key`.
@(private)
reserve_block :: proc(b: ^Builder, n: int, key: Block_Key) -> i32 {
	at := len(b.fields)
	_, slot, _, no_slot := map_entry(&b.blocks, key)
	if no_slot != nil || resize(&b.fields, at + n) != nil || resize(&b.meta, at + n) != nil {
		refuse_plan(b, .No_Memory)
		return -1
	}
	slot^ = i32(at)
	return i32(at)
}

@(private)
never :: proc(b: ^Builder, at: int) {
	f := &b.fields[at]
	f.mask = {max(u64), max(u64)}
	f.kind, f.meta = .Never, u32(at)
	b.meta[at] = {block = -1, capture = -1}
}

// Keeps `s` for as long as the plan, or frees it with the plan refused.
@(private)
owned :: proc(b: ^Builder, s: []u8) -> string {
	if _, failed := append(&b.p.strings, string(s)); failed != nil {
		refuse_plan(b, .No_Memory)
		delete(s)
		return ""
	}
	return string(s)
}

@(private)
owned_copy :: proc(b: ^Builder, s: string) -> string {
	text, failed := strings.clone(s)
	if failed != nil {
		refuse_plan(b, .No_Memory)
		return ""
	}
	return owned(b, transmute([]u8)text)
}

// Holds `name` as the format writes a key when the record can compare it. A format with no such writing, an element's
// record, which has no name, and a name with a byte a key may not hold as written leave `word` zero, for the hook to
// find.
@(private)
expect_name :: proc(b: ^Builder, f: ^Field, name: string) {
	f.mask = {max(u64), max(u64)}
	open, close := b.p.readers.key_open, b.p.readers.key_close
	if len(open) == 0 || len(name) == 0 {
		return
	}
	for i in 0 ..< len(name) {
		if name[i] < 0x20 || name[i] == '"' || name[i] == '\\' || name[i] >= 0x80 {
			return
		}
	}
	n := len(open) + len(name) + len(close)
	buf, failed := make([]u8, max(n, 16))
	if failed != nil {
		refuse_plan(b, .No_Memory)
		return
	}
	copy(buf[copy(buf, open):], name)
	copy(buf[len(open) + len(name):], close)
	f.word, f.mask = {}, {}
	for i in 0 ..< min(n, 16) {
		f.word[i / 8] |= u64(buf[i]) << uint(8 * (i % 8))
		f.mask[i / 8] |= 0xff << uint(8 * (i % 8))
	}
	f.rest = raw_data(buf[16:])
	f.n = u32(n)
	owned(b, buf)
}

// One of 64 bits for a key's text, which is not empty.
@(private)
name_bit :: #force_inline proc "contextless" (name: string) -> u64 #no_bounds_check {
	return 1 << ((u32(name[0]) * 31 + u32(name[len(name) - 1]) * 5 + u32(len(name))) & 63)
}

// Records the plan's first refusal, `kind` at the members being filled and then the member `at`, with `text` saying
// what the kind's message names.
@(private)
refuse_plan :: proc(b: ^Builder, kind: core.Typed_Error_Kind, at := "", text := "") {
	if b.err.kind != .None {
		return
	}
	b.err.kind = kind
	b.err.want.text = text
	b.err.truncated = b.depth > TRAIL_MAX
	if len(at) > 0 {
		path_add(&b.err, core.Name(at))
	}
	#reverse for name in b.trail[:min(b.depth, TRAIL_MAX)] {
		path_add(&b.err, core.Name(name))
	}
	path_close(&b.err)
}

// Adds a member's `name` to the path a refusal reports, and returns the depth that takes it off again.
@(private)
enter :: proc(b: ^Builder, name: string) -> int {
	depth := b.depth
	if len(name) > 0 {
		if b.depth < TRAIL_MAX {
			b.trail[b.depth] = name
		}
		b.depth += 1
	}
	return depth
}

// Fills record `at` for a value of `ti`. `rule_set` is the record's `Meta.rule_set`, which a `Maybe` or a pointer passes to
// its element.
@(private)
fill :: proc(b: ^Builder, at: int, ti: ^runtime.Type_Info, name: string, offset, stride: u32, rule_set := i32(0)) {
	depth := enter(b, name)
	defer b.depth = depth
	rule_set := rule_set
	if b.model != nil && rule_set == 0 && len(name) == 0 {
		if r := b.model.member(b.model, nil, "", ti.id, ""); r.rules != {} {
			rule_set = rule_set_of(b, r.rules)
		}
	}
	base := runtime.type_info_base(ti)
	f := Field{offset = offset, stride = stride, meta = u32(at)}
	m := Meta{name = name, type = ti.id, size = u32(base.size), block = -1, rule_set = rule_set}
	// A record holds a size, offset, stride or count in 32 bits, and each of them is at most its type's size.
	if base.size > int(max(u32)) {
		refuse_plan(b, .Unsupported)
	}
	expect_name(b, &f, name)
	if hook, hooked := hook_of(b, ti.id); hooked {
		f.kind, m.read, m.write, m.data = .Hook, hook.read, hook.write, hook.data
		m.key_kind = hooked_kind(base)
		if hook.read == nil && hook.write == nil {
			refuse_plan(b, .Unsupported)
		}
		b.fields[at], b.meta[at] = f, m
		return
	}
	switch ti.id {
	case typeid_of(Raw):
		f.kind = .Raw
	case typeid_of(core.Value):
		f.kind = .Value
	case typeid_of(core.Number_Text):
		f.kind = .Number_Text
	case typeid_of(core.Number):
		f.kind = .Number
	case typeid_of(Scalar):
		f.kind = .Scalar
	case typeid_of(any):
		f.kind = .Any
	case:
		// A distinct `core.Value` reads as one.
		if base == runtime.type_info_base(type_info_of(core.Value)) {
			f.kind = .Value
		} else {
			fill_base(b, &f, &m, ti, base)
		}
	}
	b.fields[at], b.meta[at] = f, m
	// A load reads a first-match union wherever it is, as a `.Before` with no call.
	if f.kind == .Union && b.model != nil && b.model.loading && b.model.unions != nil {
		if _, _, first_match := b.model.unions(b.model, ti.id); first_match {
			fm := Before{first_match = true, value = before_value}
			keep_before(b, at, &fm)
		}
	}
	if b.model != nil && b.model.loading && b.model.judge != nil {
		unique := rule_set > 0 && b.rule_sets[rule_set - 1].unique
		if j := b.model.judge(b.model, ti.id, unique); j != nil {
			if b.fields[at].kind == .Before {
				b.meta[at].before.judge = j
			} else {
				x := Before{value = before_value, judge = j}
				keep_before(b, at, &x)
			}
		}
	}
}

// The kind whose test for empty a hooked value of base type `base` takes, `.Never` for a type with none.
@(private)
hooked_kind :: proc(base: ^runtime.Type_Info) -> Read_Kind {
	#partial switch v in base.variant {
	case runtime.Type_Info_String:
		return .Cstring if v.is_cstring else .String
	case runtime.Type_Info_Slice:
		return .Slice
	case runtime.Type_Info_Dynamic_Array:
		return .Dynamic
	case runtime.Type_Info_Map:
		return .Map
	case runtime.Type_Info_Pointer:
		return .Ptr
	}
	return .Never
}

// Whether `ti` is an integer of at most `max_size` bytes that the plan's stores write.
@(private)
plain_integer :: proc(ti: ^runtime.Type_Info, max_size := 8) -> bool {
	base := runtime.type_info_base(ti)
	v := base.variant.(runtime.Type_Info_Integer)
	return base.size <= max_size && platform_order(v.endianness)
}

@(private)
platform_order :: proc(e: runtime.Platform_Endianness) -> bool {
	return e == .Platform || (e == .Little) == (ODIN_ENDIAN == .Little)
}

@(private)
integer_kind :: proc(base: ^runtime.Type_Info, v: runtime.Type_Info_Integer) -> Read_Kind {
	return Read_Kind(u8(Read_Kind.I8 if v.signed else Read_Kind.U8) + u8(intrinsics.count_trailing_zeros(base.size)))
}

// `fill` for a value the plan reads by its base type.
@(private)
fill_base :: proc(b: ^Builder, f: ^Field, m: ^Meta, ti, base: ^runtime.Type_Info) {
	#partial switch v in base.variant {
	case runtime.Type_Info_Boolean:
		f.kind = .Bool if base.size == 1 else .Bool_Wide
	case runtime.Type_Info_Integer:
		if !plain_integer(base) {
			refuse_plan(b, .Unsupported)
			return
		}
		f.kind = integer_kind(base, v)
	case runtime.Type_Info_Float:
		if base.size < 4 || !platform_order(v.endianness) {
			refuse_plan(b, .Unsupported)
			return
		}
		f.kind = .F64 if base.size == 8 else .F32
	case runtime.Type_Info_String:
		if v.encoding != .UTF_8 {
			refuse_plan(b, .Unsupported)
			return
		}
		f.kind = .Cstring if v.is_cstring else .String
	case runtime.Type_Info_Slice:
		f.kind = .Slice
		list(b, m, ti, v.elem, u32(v.elem_size))
	case runtime.Type_Info_Dynamic_Array:
		f.kind = .Dynamic
		list(b, m, ti, v.elem, u32(v.elem_size))
	case runtime.Type_Info_Array:
		f.kind = .Array
		m.count = u32(v.count)
		list(b, m, ti, v.elem, u32(v.elem_size))
	case runtime.Type_Info_Enumerated_Array:
		f.kind = .Array
		m.count = u32(v.count)
		list(b, m, ti, v.elem, u32(v.elem_size))
	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		f.kind = .Fixed_List
		m.count, m.tag = u32(v.capacity), u32(v.len_offset)
		list(b, m, ti, v.elem, u32(v.elem_size))
	case runtime.Type_Info_Map:
		f.kind = .Map
		m.map_info = v.map_info
		m.key_kind = map_key_kind(b, v.key)
		if m.key_kind == .Enum {
			m.enum_info = enum_of(b, v.key)
		}
		b.widest = max(b.widest, v.value.size)
		list(b, m, ti, v.value, 0)
	case runtime.Type_Info_Enum:
		if !plain_integer(v.base) {
			refuse_plan(b, .Unsupported)
			return
		}
		f.kind = .Enum
		m.enum_info = enum_of(b, ti)
	case runtime.Type_Info_Pointer:
		if v.elem == nil {
			refuse_plan(b, .Unsupported)
			return
		}
		f.kind = .Ptr
		list(b, m, ti, v.elem, 0, m.rule_set)
		m.rule_set = 0
	case runtime.Type_Info_Union:
		fill_union(b, f, m, ti, v)
	case runtime.Type_Info_Struct:
		if v.flags & {.raw_union} != {} || v.soa_kind != .None {
			refuse_plan(b, .Unsupported)
			return
		}
		fill_struct(b, f, m, ti, v)
	case runtime.Type_Info_Bit_Set:
		fill_bit_set(b, f, m, ti, v)
	case:
		refuse_plan(b, .Unsupported)
	}
	// A list's length is its stride's multiple, so an element of no size could spell no length.
	#partial switch f.kind {
	case .Slice, .Dynamic, .Array, .Fixed_List:
		if m.elem_size == 0 {
			refuse_plan(b, .Unsupported)
		}
	}
}

@(private)
map_key_kind :: proc(b: ^Builder, key: ^runtime.Type_Info) -> Read_Kind {
	base := runtime.type_info_base(key)
	#partial switch v in base.variant {
	case runtime.Type_Info_String:
		return .Cstring if v.is_cstring else .String
	case runtime.Type_Info_Enum:
		return .Enum
	case runtime.Type_Info_Integer:
		if plain_integer(base) {
			return integer_kind(base, v)
		}
	}
	refuse_plan(b, .Unsupported)
	return .Never
}

@(private)
fill_bit_set :: proc(b: ^Builder, f: ^Field, m: ^Meta, ti: ^runtime.Type_Info, v: runtime.Type_Info_Bit_Set) {
	elem := runtime.type_info_base(v.elem)
	_, is_int := elem.variant.(runtime.Type_Info_Integer)
	_, is_enum := elem.variant.(runtime.Type_Info_Enum)
	if !is_int && !is_enum || (v.underlying != nil && !plain_integer(v.underlying, 16)) {
		refuse_plan(b, .Unsupported)
		return
	}
	f.kind = .Bit_Set
	m.list = true
	if at, ok := b.blocks[{ti.id, 0, 0}]; ok {
		m.block = at
		return
	}
	m.block = reserve_block(b, 2, {ti.id, 0, 0})
	if m.block < 0 {
		return
	}
	never(b, int(m.block))
	never(b, int(m.block) + 1)
	e := &b.fields[m.block]
	e.kind, e.meta = .Bit_Elem, u32(m.block)
	em := &b.meta[m.block]
	em.lower, em.count = v.lower, u32(v.upper - v.lower + 1)
	if is_enum {
		em.enum_info = enum_of(b, v.elem)
	}
}

@(private)
list :: proc(b: ^Builder, m: ^Meta, ti, elem: ^runtime.Type_Info, stride: u32, rule_set := i32(0)) {
	base := runtime.type_info_base(elem)
	m.list = true
	m.elem_size = u32(base.size)
	m.align = u32(base.align)
	#partial switch _ in base.variant {
	case runtime.Type_Info_Boolean, runtime.Type_Info_Integer, runtime.Type_Info_Float, runtime.Type_Info_String:
		// A hook is handed the element as its `dest`, which must hold what the target held.
		_, m.zeroed = hook_of(b, elem.id)
	case:
		m.zeroed = true
	}
	if at, ok := b.blocks[{ti.id, rule_set, 0}]; ok {
		m.block = at
		return
	}
	m.block = reserve_block(b, 2, {ti.id, rule_set, 0})
	if m.block < 0 {
		return
	}
	never(b, int(m.block) + 1)
	fill(b, int(m.block), elem, "", 0, stride, rule_set)
}

// A union reads a value into the arm its class picks, so no two arms may take one class, except named struct arms under
// a `union_tag`, which leave objects to the tag.
@(private)
fill_union :: proc(b: ^Builder, f: ^Field, m: ^Meta, ti: ^runtime.Type_Info, v: runtime.Type_Info_Union) {
	f.kind = .Union
	m.tag, m.no_nil = u32(v.tag_offset), v.no_nil
	// A union of no arms has no tag, and holds only its nil.
	m.tag_size = 0 if v.tag_type == nil || reflect.type_info_union_is_pure_maybe(v) else u8(v.tag_type.size)
	// A `Maybe`, the one arm reads on the hot kinds' own path.
	if len(v.variants) == 1 && !v.no_nil {
		elem := runtime.type_info_base(v.variants[0])
		if p, is_ptr := elem.variant.(runtime.Type_Info_Pointer); is_ptr && p.elem != nil && m.tag_size == 0 {
			f.kind = .Ptr
			m.whole = true
			list(b, m, ti, p.elem, 0, m.rule_set)
			m.rule_set = 0
			return
		}
		if m.tag_size == 1 {
			f.kind = .Maybe
			list(b, m, ti, v.variants[0], 0, m.rule_set)
			m.rule_set = 0
			return
		}
	}
	// The arms take the union's rules, which apply to the value of whichever arm reads it.
	if at, ok := b.blocks[{ti.id, m.rule_set, 0}]; ok {
		m.block = at
	} else {
		m.block = reserve_block(b, len(v.variants) + 1, {ti.id, m.rule_set, 0})
		if m.block < 0 {
			return
		}
		never(b, int(m.block) + len(v.variants))
		for arm, k in v.variants {
			fill(b, int(m.block) + k, arm, "", 0, 0, arm_rules(b, arm, m.rule_set))
		}
	}
	arms, failed := make([]Arm, len(v.variants))
	if failed != nil {
		refuse_plan(b, .No_Memory)
		return
	}
	m.arms = arms
	named: int
	for arm, k in v.variants {
		n, is_named := arm.variant.(runtime.Type_Info_Named)
		_, is_struct := runtime.type_info_base(arm).variant.(runtime.Type_Info_Struct)
		m.arms[k] = {classes_of(b, arm, 0), u32(k if v.no_nil else k + 1), m.block + i32(k), ""}
		if is_named && is_struct {
			named += 1
			m.arms[k].name = n.name
			for t in b.tag_names {
				if t.type == arm.id {
					m.arms[k].name = t.name
				}
			}
		}
	}
	tag, first_match := b.union_tag, false
	if b.model != nil && b.model.unions != nil {
		named_tag, set := "", false
		if named_tag, set, first_match = b.model.unions(b.model, ti.id); set {
			tag = owned_copy(b, named_tag)
		}
	}
	m.tagged, m.union_tag = named >= 2 && len(tag) > 0, tag
	for &arm, k in m.arms {
		if m.tagged && len(arm.name) > 0 {
			b.meta[int(m.block) + k].tagged = true
			b.meta[int(m.block) + k].union_tag = tag
		} else {
			arm.name = ""
		}
	}
	if !first_match {
		refuse_overlap(b, m)
	}
}

// The rule set of a union's arm of type `arm`: the union's rules, `rule_set`, with a model's rules of the arm's type.
@(private)
arm_rules :: proc(b: ^Builder, arm: ^runtime.Type_Info, rule_set: i32) -> i32 {
	if b.model == nil || rule_set == 0 {
		return rule_set
	}
	own := rules.Node{rules = b.model.member(b.model, nil, "", arm.id, "").rules}
	joined, clash := rules.merged(&own, b.rule_sets[rule_set - 1])
	if clash != "" {
		refuse_plan(b, .Bad_Tag, text = clash)
	}
	return rule_set_of(b, joined)
}

// Refuses a union two of whose arms take one class of value, except objects that arms named by the union's tag take.
@(private)
refuse_overlap :: proc(b: ^Builder, m: ^Meta) {
	taken: bit_set[Value_Class]
	untagged_objects := 0
	for arm in m.arms {
		if len(arm.name) == 0 && .Object in arm.classes {
			untagged_objects += 1
		}
		if arm.classes & taken - {.Object} != {} {
			refuse_plan(b, .Ambiguous_Union, text = "two arms read the same kind of value")
		}
		taken |= arm.classes
	}
	if untagged_objects > 1 || (m.tagged && untagged_objects > 0) {
		refuse_plan(b, .Ambiguous_Union, text = "two arms read objects, so set Plan_Options.union_tag to the member that names the arm")
	}
}

// Refuses a struct arm of a union read by its tag that has a member keyed as the tag, which the tag's value would fill.
// The pass runs once the type is filled, since an arm that holds the union has its members filled after the union.
@(private)
refuse_tag_members :: proc(b: ^Builder) {
	for m in b.meta {
		for arm in m.arms {
			if len(arm.name) == 0 {
				continue
			}
			s := &b.meta[arm.fields]
			for j in 0 ..< int(s.members) {
				if name := b.meta[int(s.block) + j].name; name == m.union_tag {
					refuse_plan(b, .Unsupported, name)
				}
			}
		}
	}
}

// The classes of value `ti` reads. `depth` bounds a union that holds a pointer to itself.
@(private)
classes_of :: proc(b: ^Builder, ti: ^runtime.Type_Info, depth: int) -> (c: bit_set[Value_Class]) {
	if depth > 16 {
		return
	}
	if hook, hooked := hook_of(b, ti.id); hooked {
		return classes_of(b, type_info_of(hook.carrier), depth + 1) if hook.carrier != nil else EVERY_CLASS
	}
	switch ti.id {
	case typeid_of(Raw), typeid_of(any), typeid_of(core.Value):
		return EVERY_CLASS
	case typeid_of(core.Number_Text), typeid_of(core.Number):
		return {.Number}
	case typeid_of(Scalar):
		return {.String, .Bool, .Number}
	}
	base := runtime.type_info_base(ti)
	#partial switch v in base.variant {
	case runtime.Type_Info_Boolean:
		return {.Bool}
	case runtime.Type_Info_Integer, runtime.Type_Info_Float:
		return {.Number}
	case runtime.Type_Info_String:
		return {.String}
	case runtime.Type_Info_Struct, runtime.Type_Info_Map:
		return {.Object}
	case runtime.Type_Info_Slice, runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Array, runtime.Type_Info_Enumerated_Array, runtime.Type_Info_Fixed_Capacity_Dynamic_Array, runtime.Type_Info_Bit_Set:
		return {.Array}
	case runtime.Type_Info_Enum:
		return {.String, .Number}
	case runtime.Type_Info_Pointer:
		return classes_of(b, v.elem, depth + 1) if v.elem != nil else {}
	case runtime.Type_Info_Union:
		for arm in v.variants {
			c |= classes_of(b, arm, depth + 1)
		}
	}
	return
}

// A member as `lay_out` found it.
@(private)
Member :: struct {
	name:     string,
	type:     ^runtime.Type_Info,
	offset:   uintptr,
	required: bool,
	omit:     bool,
	rule_set: i32,
	access:   Access,
	alias:    string,
	make:     Make_Default,
	data:     rawptr,
	after:    Validator,
	before:   ^Before,
	not_null: bool,
}

// What `lay_out` found of a struct besides its members: the member that captures unknown members, 1 + the offset of
// its `Fields_Set` with the member's name, and the names a read_only member the plan leaves out is read by.
@(private)
Struct_Layout :: struct {
	capture:    Maybe(Member),
	fields_set: u32,
	set_name:   string,
	read_only:  [dynamic]string,
}

// A struct's block holds its members, a `Never` record that holds in its `Meta` what is true of every use of the struct,
// and, when it captures unknown members, the record of the capturing map and a `Never` record. The block's layout is
// fixed before any member's type is read, so a recursive type meets it whole.
@(private)
fill_struct :: proc(b: ^Builder, f: ^Field, m: ^Meta, ti: ^runtime.Type_Info, v: runtime.Type_Info_Struct) {
	if known_struct(b, {ti.id, 0, 0}, f, m) {
		return
	}
	members: [dynamic]Member
	defer delete(members)
	layout: Struct_Layout
	defer delete(layout.read_only)
	lay_out(b, ti.id, v, 0, &members, &layout)
	capture := layout.capture
	for x, i in members {
		for y in members[:i] {
			if x.name != y.name {
				continue
			}
			alias := x.alias if len(x.alias) > 0 else y.alias
			if len(alias) > 0 && b.err.kind == .None {
				refuse_plan(b, .Bad_Tag, x.name, alias)
				b.err.want.type = ti.id
			} else {
				refuse_plan(b, .Unsupported, x.name)
			}
		}
		// A write would leave out what the read then finds missing.
		if x.required && x.omit && x.access != .Write_Only {
			refuse_plan(b, .Unsupported, x.name)
		}
	}
	n := len(members)
	at := struct_block(b, {ti.id, 0, 0}, f, m, members[:], capture != nil)
	if at < 0 {
		return
	}
	if b.model != nil {
		forbid := b.model.forbids != nil && b.model.forbids(b.model, ti.id)
		// A struct that refuses the members it does not name has none to capture.
		if c, ok := capture.?; ok && forbid {
			refuse_plan(b, .Bad_Tag, c.name, "extra")
			b.err.want.type = ti.id
			return
		}
		b.meta[int(at) + n].forbid, m.forbid = forbid, forbid
		// The read judges a key it does not name only in a struct that requires members.
		if forbid {
			f.kind = .Required
		}
		if b.model.structs != nil {
			b.model.structs(b, ti.id, at, f, m, members[:], &layout)
		}
	}
	if c, ok := capture.?; ok {
		b.meta[int(at) + n].capture = at + i32(n) + 1
		fill(b, int(at) + n + 1, c.type, "", u32(c.offset), 0)
		f.kind, f.lists = .Required, true
	}
	sm := b.meta[int(at) + n].model
	bit := i8(0)
	for x, i in members {
		fill(b, int(at) + i, x.type, x.name, u32(x.offset), 0, x.rule_set)
		b.meta[int(at) + i].access = x.access
		b.meta[int(at) + i].no_nil ||= x.not_null
		if x.before != nil {
			keep_before(b, int(at) + i, x.before)
		}
		r := &b.fields[int(at) + i]
		mm := &b.meta[int(at) + i]
		mm.omit_empty, mm.optional, mm.bit, mm.owner = x.omit, !x.required, -1 if x.access == .Read_Only else bit, sm
		bit += 0 if x.access == .Read_Only else 1
		if sm != nil {
			for d, j in sm.defaults {
				mm.default = i32(j) + 1 if int(d.member) == i else mm.default
			}
		}
		// A model's write may leave out a member that can be null, has a default or whose struct records its loaded members.
		r.omit = x.omit || b.model != nil && !b.model.loading && (!x.required || layout.fields_set != 0 || nullable(x.type))
		if !r.omit && r.n <= KEY_SIZE_MAX && plain_name(x.name) {
			r.key_size = u8(r.n)
		}
	}
}

// Whether a value of `ti` can be null: a pointer, an `any`, a cstring or a union with a nil.
@(private)
nullable :: proc(ti: ^runtime.Type_Info) -> bool {
	#partial switch v in runtime.type_info_base(ti).variant {
	case runtime.Type_Info_Pointer, runtime.Type_Info_Any:
		return true
	case runtime.Type_Info_String:
		return v.is_cstring
	case runtime.Type_Info_Union:
		return !v.no_nil
	}
	return false
}

// Points `f` at the struct block recorded under `key`, if there is one.
@(private)
known_struct :: proc(b: ^Builder, key: Block_Key, f: ^Field, m: ^Meta) -> bool {
	at, ok := b.blocks[key]
	if !ok {
		return false
	}
	m.block, m.members = at, b.ends[at] - at
	end := &b.meta[b.ends[at]]
	m.required_end, m.model, m.forbid = end.required_end, end.model, end.forbid
	f.kind = .Required if len(end.required) > 0 || end.capture >= 0 || end.forbid || end.model != nil && end.model.settle != nil else .Struct
	f.lists = end.capture >= 0
	return true
}

// Adds the block of a struct with `members`, its `Never` record with the members that must be present, and room for a
// capturing map's record and its `Never` record. Returns the block's first record, or -1 with the plan refused.
@(private)
struct_block :: proc(b: ^Builder, key: Block_Key, f: ^Field, m: ^Meta, members: []$M, capture: bool) -> i32 {
	n := len(members)
	at := reserve_block(b, n + 1 + (2 if capture else 0), key)
	if at < 0 {
		return -1
	}
	_, end_slot, _, no_end := map_entry(&b.ends, at)
	if no_end != nil {
		refuse_plan(b, .No_Memory)
		return -1
	}
	end := int(at) + n
	end_slot^ = i32(end)
	m.block, m.members = at, i32(n)
	never(b, end)
	if capture {
		never(b, end + 2)
	}
	required: [dynamic]i32
	for x, i in members {
		if x.required {
			if _, failed := append(&required, i32(i)); failed != nil {
				refuse_plan(b, .No_Memory)
			}
		}
	}
	b.meta[end].required = required[:]
	f.kind = .Struct
	if len(required) > 0 {
		f.kind = .Required
		m.required_end = required[len(required) - 1] + 1
		b.meta[end].required_end = m.required_end
	}
	return at
}

// Whether a name's written text is its bytes whatever the options of a write: letters, digits, `_` and `-`.
@(private)
plain_name :: proc(name: string) -> bool {
	for c in transmute([]u8)name {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
		case:
			return false
		}
	}
	return true
}

// Collects the members of struct `owner`, with a `using` member its tag gives no name flattened into the struct that
// holds it, as the plan's model says when it has one.
@(private)
lay_out :: proc(b: ^Builder, owner: typeid, v: runtime.Type_Info_Struct, base: uintptr, out: ^[dynamic]Member, layout: ^Struct_Layout) {
	for i in 0 ..< int(v.field_count) {
		tag, bad_flag := field_tag(b, v.names[i], v.tags[i])
		if len(bad_flag) > 0 {
			refuse_plan(b, .Bad_Tag, v.names[i], bad_flag)
			return
		}
		if !tag.keep {
			continue
		}
		if b.model != nil && v.types[i].id == typeid_of(Fields_Set) {
			layout.fields_set, layout.set_name = u32(base + v.offsets[i]) + 1, v.names[i]
			continue
		}
		_, hooked := hook_of(b, v.types[i].id)
		model: Member_Rule
		if b.model != nil {
			model = b.model.member(b.model, owner, v.names[i], v.types[i].id, v.tags[i])
			if len(model.refused) > 0 {
				if b.err.kind == .None {
					refuse_plan(b, .Bad_Tag, v.names[i], model.refused)
					b.err.want.type = owner
				}
				return
			}
			if model.skip {
				// A member `-` leaves out is read_write, so this is one the plan leaves out for its role.
				if model.access == .Read_Only {
					for name in ([2]string{model.name if len(model.name) > 0 else tag.name, model.alias}) {
						if len(name) > 0 {
							append(&layout.read_only, owned_copy(b, name))
						}
					}
				}
				continue
			}
			if len(model.name) > 0 {
				tag.name = owned_copy(b, model.name)
			}
			tag.unknown ||= model.extra
			tag.required ||= !tag.unknown && !model.optional && model.make == nil && model.access != .Read_Only
		}
		// A flattened or capturing member is no value of its own for rules to hold.
		rule_set := rule_set_of(b, model.rules) if model.rules != {} else 0
		if inner, is_struct := runtime.type_info_base(v.types[i]).variant.(runtime.Type_Info_Struct); is_struct && v.usings[i] && !tag.named && !hooked && .raw_union not_in inner.flags && inner.soa_kind == .None {
			if rule_set > 0 {
				refuse_plan(b, .Bad_Tag, tag.name, "model")
			}
			lay_out(b, v.types[i].id, inner, base + v.offsets[i], out, layout)
			continue
		}
		x := Member{tag.name, v.types[i], base + v.offsets[i], tag.required, tag.omit || model.access == .Write_Only, rule_set, model.access, model.alias, model.make, model.data, model.after, model.before, model.not_null}
		if tag.unknown {
			if tag.required || rule_set > 0 {
				refuse_plan(b, .Bad_Tag, tag.name, "required" if tag.required else "model")
			}
			if captures, is_map := runtime.type_info_base(v.types[i]).variant.(runtime.Type_Info_Map); !is_map || runtime.type_info_base(captures.key).id != typeid_of(string) || layout.capture != nil {
				refuse_plan(b, .Unsupported, tag.name)
			}
			layout.capture = x
			continue
		}
		if _, failed := append(out, x); failed != nil {
			refuse_plan(b, .No_Memory)
			return
		}
	}
}

@(private)
hook_of :: proc(b: ^Builder, T: typeid) -> (hook: Type_Hook, ok: bool) {
	for h in b.hooks {
		if h.type == T {
			return h, true
		}
	}
	return
}

// The address and type a pointer held in `target` points at, false for a value that is no non-nil pointer.
pointer_target :: proc "contextless" (target: any) -> (data: rawptr, T: typeid, pointer: bool) {
	if target.data == nil || target.id == nil {
		return
	}
	info := runtime.type_info_base(type_info_of(target.id)).variant.(runtime.Type_Info_Pointer) or_return
	data = (^rawptr)(target.data)^
	return data, info.elem.id, info.elem != nil && data != nil
}
