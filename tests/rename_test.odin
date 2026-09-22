package tests

import "core:fmt"
import "core:testing"

import "src:common"

import test "src:testing"

@(test)
ast_prepare_rename_enum_field_list :: proc (t: ^testing.T) {
	source := test.Source {
		main     = `package test

		Foo :: enum {
			a = 1,
		}

		main :: proc() {
			foo: Foo
			foo = .a{*}
		}
		`,
	}
	range := common.Range{start = {line = 8, character = 10}, end = {line = 8, character = 11}}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_rename_implicit_enum_in_proc_default :: proc(t: ^testing.T) {
	source := test.Source{
		main = `package test
My_Enum :: enum {
	One,
	Four,
}
my_fn :: proc(value: My_Enum = .Fo{*}ur) {}
`,
	}
	test.expect_rename_text(t, &source, "Renamed", `package test
My_Enum :: enum {
	One,
	Renamed,
}
my_fn :: proc(value: My_Enum = .Renamed) {}
`)
}

@(test)
ast_rename_struct_field_in_map_literal_value :: proc(t: ^testing.T) {
	source := test.Source{
		main = `package test
Foo :: struct {
	foo{*}: int,
}
main :: proc() {
	values: map[int]Foo = {0 = {foo = 1}}
	_ = values
}
`,
	}
	test.expect_rename_text(t, &source, "renamed", `package test
Foo :: struct {
	renamed: int,
}
main :: proc() {
	values: map[int]Foo = {0 = {renamed = 1}}
	_ = values
}
`)
}

@(test)
ast_rename_nested_named_arguments_by_owner :: proc(t: ^testing.T) {
	struct_source := test.Source{
		main = `package test
Foo :: struct {
	bar{*}: int,
}
make :: proc(bar: int) -> int {
	return bar
}
main :: proc() {
	_ = Foo{bar = make(bar = 1)}
}
`,
	}
	test.expect_rename_text(t, &struct_source, "field", `package test
Foo :: struct {
	field: int,
}
make :: proc(bar: int) -> int {
	return bar
}
main :: proc() {
	_ = Foo{field = make(bar = 1)}
}
`)

	param_source := test.Source{
		main = `package test
Foo :: struct {
	bar: int,
}
make :: proc(bar{*}: int) -> int {
	return bar
}
main :: proc() {
	_ = Foo{bar = make(bar = 1)}
}
`,
	}
	test.expect_rename_text(t, &param_source, "param", `package test
Foo :: struct {
	bar: int,
}
make :: proc(param: int) -> int {
	return param
}
main :: proc() {
	_ = Foo{bar = make(param = 1)}
}
`)
}

@(test)
ast_prepare_rename_enum_field_list_with_constant :: proc (t: ^testing.T) {
	source := test.Source {
		main     = `package test

		one :: 1

		Foo :: enum {
			a = on{*}e,
		}
		`,
	}

	range := common.Range{start = {line = 5, character = 7}, end = {line = 5, character = 10}}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_prepare_rename_struct_field :: proc (t: ^testing.T) {
	source := test.Source {
		main     = `package test

		Foo :: struct {
			bar: int,
		}

		main :: proc() {
			foo := Foo{
				b{*}ar = 1,
			}
		}
		`,
	}

	range := common.Range{start = {line = 8, character = 4}, end = {line = 8, character = 7}}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_prepare_rename_struct_field_selector :: proc (t: ^testing.T) {
	source := test.Source {
		main     = `package test

		Foo :: struct {
			bar: int,
		}

		main :: proc() {
			foo := Foo{}
			foo.ba{*}r = 1
		}
		`,
	}

	range := common.Range{start = {line = 8, character = 7}, end = {line = 8, character = 10}}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_prepare_rename_struct :: proc (t: ^testing.T) {
	source := test.Source {
		main     = `package test

		Foo :: struct {
			bar: int,
		}

		main :: proc() {
			foo := Fo{*}o{}
		}
		`,
	}

	range := common.Range{start = {line = 7, character = 10}, end = {line = 7, character = 13}}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_prepare_rename_alias_with_definition_skip :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
Target :: struct {}
Alias :: Target
main :: proc() {
x := Ali{*}as{}
}
`,
		config = {enable_definition_skip_aliases = true},
	}

	test.expect_prepare_rename_range(t, &source, {{line = 4, character = 5}, {line = 4, character = 10}})
}

@(test)
ast_rename_alias_with_definition_skip :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
Target :: struct {}
Alias :: Target
main :: proc() {
x: Alias
y := Al{*}ias{}
}
`,
		config = {enable_definition_skip_aliases = true},
	}
	test.expect_rename_text(t, &source, "Renamed", `package test
Renamed :: struct {}
Alias :: Renamed
main :: proc() {
x: Renamed
y := Renamed{}
}
`)
}

@(test)
ast_rename_alias_without_definition_skip :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
Target :: struct {}
Alias :: Target
main :: proc() {
x: Alias
y := Al{*}ias{}
}
`,
		config = {enable_definition_skip_aliases = false},
	}
	test.expect_rename_text(t, &source, "Renamed", `package test
Target :: struct {}
Renamed :: Target
main :: proc() {
x: Renamed
y := Renamed{}
}
`)
}

@(test)
ast_prepare_rename_struct_field_type :: proc (t: ^testing.T) {
	source := test.Source {
		main     = `package test

		Bar :: struct {}

		Foo :: struct {
			bar: B{*}ar,
		}
		`,
	}

	range := common.Range{start = {line = 5, character = 8}, end = {line = 5, character = 11}}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_prepare_rename_struct_field_type_package :: proc (t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)

	append(
		&packages,
		test.Package {
			pkg = "my_package",
			source = `package my_package
		My_Struct :: struct {}
		`,
		},
	)
	source := test.Source {
		main     = `package test
		import "my_package"

		Foo :: struct {
			bar: my_package.My_Stru{*}ct,
		}
		`,
		packages = packages[:],
	}

	range := common.Range{start = {line = 4, character = 19}, end = {line = 4, character = 28}}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_prepare_rename_union_type :: proc (t: ^testing.T) {
	source := test.Source {
		main     = `package test

		Foo :: struct {
			bar: int,
		}
		
		Bar :: struct {}

		Foo_Bar :: union {
			Fo{*}o,
			Bar,
		}
		`,
	}

	range := common.Range{start = {line = 9, character = 3}, end = {line = 9, character = 6}}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_prepare_rename_symbol_behind_for :: proc (t: ^testing.T) {
	source := test.Source {
		main     = `package test
		
		main :: proc() {
			foos := [5]int{1,2,3,4,5}
			for f{*}oo in foos {
			}
		}
		`,
	}

	range := common.Range{start = {line = 4, character = 7}, end = {line = 4, character = 10}}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_prepare_rename_symbol_behind_for_with_label :: proc (t: ^testing.T) {
	source := test.Source {
		main     = `package test
		
		main :: proc() {
			foos := [5]int{1,2,3,4,5}
			my_for: for f{*}oo in foos {
			}
		}
		`,
	}

	range := common.Range{start = {line = 4, character = 15}, end = {line = 4, character = 18}}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_prepare_rename_enumerated_array :: proc (t: ^testing.T) {
	source := test.Source {
		main     = `package test

		Foo :: enum {
			A,
			B,
		}

		main :: proc() {
			foos := [Foo]Foo {
				.A{*} = .B,
			}
		}
		`,
	}

	range := common.Range{start = {line = 9, character = 5}, end = {line = 9, character = 6}}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_prepare_rename_struct_field_ptr :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: struct {
			bar: ^Ba{*}r
		}

		Bar :: struct {}
		`,
	}

	range := common.Range{start = {line = 3, character = 9}, end = {line = 3, character = 12}}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_prepare_rename_struct_field_enumerated_array :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			A,
			B,
		}

		Bar :: struct {
			foos: [F{*}oo]int
		}
		`,
	}

	range := common.Range{start = {line = 8, character = 10}, end = {line = 8, character = 13}}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_prepare_rename_struct_field_map :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			A,
			B,
		}

		Bar :: struct {
			foos: map[F{*}oo]int
		}
		`,
	}

	range := common.Range{start = {line = 8, character = 13}, end = {line = 8, character = 16}}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_prepare_rename_struct_field_dynamic_array :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			A,
			B,
		}

		Bar :: struct {
			foos: [dynamic]Fo{*}o
		}
		`,
	}

	range := common.Range{start = {line = 8, character = 18}, end = {line = 8, character = 21}}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_prepare_rename_struct_field_bit_set :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			A,
			B,
		}

		Bar :: struct {
			foos: bit_set[Fo{*}o]
		}
		`,
	}

	range := common.Range{start = {line = 8, character = 17}, end = {line = 8, character = 20}}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_rename_struct_field_in_map_literal_key :: proc(t: ^testing.T) {
	source := test.Source{
		main = `package test
Foo :: struct {
	key{*}: int,
}
main :: proc() {
	values: map[Foo]int = {{key = 1} = 2}
	_ = values
}
`,
	}
	test.expect_rename_text(t, &source, "renamed", `package test
Foo :: struct {
	renamed: int,
}
main :: proc() {
	values: map[Foo]int = {{renamed = 1} = 2}
	_ = values
}
`)
}
