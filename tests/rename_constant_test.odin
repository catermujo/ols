package tests

import "core:testing"

import "src:common"

import test "src:testing"

@(test)
ast_rename_global_constant_from_declaration :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Answer{*} :: 42

main :: proc() {
_ = Answer
_ = Answer
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 0}, end = {line = 2, character = 6}}},
		{range = {start = {line = 5, character = 4}, end = {line = 5, character = 10}}},
		{range = {start = {line = 6, character = 4}, end = {line = 6, character = 10}}},
	}

	test.expect_rename_locations(t, &source, "Renamed_Answer", locations[:])
}

@(test)
ast_rename_constant_in_expression_and_alias :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Base :: 2
Derived :: Ba{*}se + 3
Alias :: Base

main :: proc() {
_ = Base
_ = Derived
_ = Alias
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 0}, end = {line = 2, character = 4}}},
		{range = {start = {line = 3, character = 11}, end = {line = 3, character = 15}}},
		{range = {start = {line = 4, character = 9}, end = {line = 4, character = 13}}},
		{range = {start = {line = 7, character = 4}, end = {line = 7, character = 8}}},
	}

	test.expect_rename_locations(t, &source, "Renamed_Base", locations[:])
}

@(test)
ast_rename_local_constant :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
Local{*} :: 7
_ = Local
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 0}, end = {line = 3, character = 5}}},
		{range = {start = {line = 4, character = 4}, end = {line = 4, character = 9}}},
	}

	test.expect_rename_locations(t, &source, "Renamed_Local", locations[:])
}

@(test)
ast_rename_typed_constant_value :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Limit :: u32(4)

main :: proc() {
_ = Li{*}mit
if 1 < Limit {
}
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 0}, end = {line = 2, character = 5}}},
		{range = {start = {line = 5, character = 4}, end = {line = 5, character = 9}}},
		{range = {start = {line = 6, character = 7}, end = {line = 6, character = 12}}},
	}

	test.expect_rename_locations(t, &source, "Renamed_Limit", locations[:])
}

@(test)
ast_rename_boolean_constant_in_when :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Enabled :: true

when En{*}abled {
main :: proc() {
}
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 0}, end = {line = 2, character = 7}}},
		{range = {start = {line = 4, character = 5}, end = {line = 4, character = 12}}},
	}

	test.expect_rename_locations(t, &source, "Renamed_Enabled", locations[:])
}

@(test)
ast_rename_constant_in_array_length :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Size :: 4
Values :: [Si{*}ze]int

main :: proc() {
values: Values
_ = Size
_ = values
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 0}, end = {line = 2, character = 4}}},
		{range = {start = {line = 3, character = 11}, end = {line = 3, character = 15}}},
		{range = {start = {line = 7, character = 4}, end = {line = 7, character = 8}}},
	}

	test.expect_rename_locations(t, &source, "Renamed_Size", locations[:])
}

@(test)
ast_rename_string_constant_value :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Message :: "hello"

main :: proc() {
_ = Mes{*}sage
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 0}, end = {line = 2, character = 7}}},
		{range = {start = {line = 5, character = 4}, end = {line = 5, character = 11}}},
	}

	test.expect_rename_locations(t, &source, "Renamed_Message", locations[:])
}

@(test)
ast_rename_constant_used_as_enum_value :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

One{*} :: 1
Numbers :: enum {
A = One,
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 0}, end = {line = 2, character = 3}}},
		{range = {start = {line = 4, character = 4}, end = {line = 4, character = 7}}},
	}

	test.expect_rename_locations(t, &source, "Renamed_One", locations[:])
}

@(test)
ast_rename_simple_constant_with_editor_config :: proc(t: ^testing.T) {
	source := test.Source {
		config = {enable_definition_skip_alias = true},
		main = `package test

FLAG :: 1

main :: proc() {
_ = FL{*}AG
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 0}, end = {line = 2, character = 4}}},
		{range = {start = {line = 5, character = 4}, end = {line = 5, character = 8}}},
	}

	test.expect_rename_locations(t, &source, "RENAMED_FLAG", locations[:])
}

@(test)
ast_prepare_rename_global_constant_declaration :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

FLAG{*} :: 1
`,
	}

	range := common.Range {
		start = {line = 2, character = 0},
		end = {line = 2, character = 4},
	}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_prepare_rename_global_constant_use :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

FLAG :: 1

main :: proc() {
_ = FL{*}AG
}
`,
	}

	range := common.Range {
		start = {line = 5, character = 4},
		end = {line = 5, character = 8},
	}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_rename_warmup_simple_constant_alias :: proc(t: ^testing.T) {
	source := test.Source {
		config = {enable_definition_skip_alias = true},
		main = `package main

A{*} :: true
B :: A
`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 0}, end = {line = 2, character = 1}}},
		{range = {start = {line = 3, character = 5}, end = {line = 3, character = 6}}},
	}

	test.expect_rename_locations(t, &source, "Renamed_A", locations[:])
}

@(test)
ast_rename_warmup_simple_constant_alias_use :: proc(t: ^testing.T) {
	source := test.Source {
		config = {enable_definition_skip_alias = true},
		main = `package main

A :: true
B :: A{*}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 0}, end = {line = 2, character = 1}}},
		{range = {start = {line = 3, character = 5}, end = {line = 3, character = 6}}},
	}

	test.expect_rename_locations(t, &source, "Renamed_A", locations[:])
}
