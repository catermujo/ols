package tests

import "core:testing"

import "src:common"

import test "src:testing"

@(test)
ast_rename_struct_field_not_named_proc_arg_inside_struct_usage :: proc(t: ^testing.T) {
	source := test.Source{
		main = `package test

Foo :: struct {
bar{*}: int,
}

make :: proc(bar: int) -> int {
return bar
}

main :: proc() {
_ = Foo{
bar = make(bar = 1),
}
}
`,
	}

	locations := []common.Location{
		{range = {start = {line = 3, character = 0}, end = {line = 3, character = 3}}},
		{range = {start = {line = 12, character = 0}, end = {line = 12, character = 3}}},
	}
	excluded := []common.Location{
		{range = {start = {line = 6, character = 13}, end = {line = 6, character = 16}}},
		{range = {start = {line = 7, character = 7}, end = {line = 7, character = 10}}},
		{range = {start = {line = 12, character = 11}, end = {line = 12, character = 14}}},
	}

	test.expect_rename_locations(t, &source, "renamed", locations[:], excluded)
}

@(test)
ast_rename_proc_param_not_struct_field_inside_struct_usage :: proc(t: ^testing.T) {
	source := test.Source{
		main = `package test

Foo :: struct {
bar: int,
}

make :: proc(bar{*}: int) -> int {
return bar
}

main :: proc() {
_ = Foo{
bar = make(bar = 1),
}
}
`,
	}

	locations := []common.Location{
		{range = {start = {line = 6, character = 13}, end = {line = 6, character = 16}}},
		{range = {start = {line = 7, character = 7}, end = {line = 7, character = 10}}},
		{range = {start = {line = 12, character = 11}, end = {line = 12, character = 14}}},
	}
	excluded := []common.Location{
		{range = {start = {line = 3, character = 0}, end = {line = 3, character = 3}}},
		{range = {start = {line = 12, character = 0}, end = {line = 12, character = 3}}},
	}

	test.expect_rename_locations(t, &source, "renamed", locations[:], excluded)
}
