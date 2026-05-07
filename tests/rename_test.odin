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
ast_rename_enum_variant_nested_with_switch :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			A{*},
			B,
		}

		foo :: proc() -> Foo {
			f := Foo.A
			switch f {
			case .A:
				return .B
			case .B
				return .A
			}
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 4}}},
		{range = {start = {line = 8, character = 12}, end = {line = 8, character = 13}}},
		{range = {start = {line = 10, character = 9}, end = {line = 10, character = 10}}},
		{range = {start = {line = 13, character = 12}, end = {line = 13, character = 13}}},
	}

	test.expect_rename_locations(t, &source, "Renamed", locations[:])
}

@(test)
ast_rename_enum_variant_same_name_other_enum :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			A{*},
		}

		Bar :: enum {
			A,
		}

		main :: proc() {
			foo: Foo
			bar: Bar
			foo = .A
			bar = .A
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 4}}},
		{range = {start = {line = 13, character = 10}, end = {line = 13, character = 11}}},
	}
	excluded := []common.Location {
		{range = {start = {line = 7, character = 3}, end = {line = 7, character = 4}}},
		{range = {start = {line = 14, character = 10}, end = {line = 14, character = 11}}},
	}

	test.expect_rename_locations(t, &source, "Renamed", locations[:], excluded)
}

@(test)
ast_rename_enum_variant_infer_from_union_assignment :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Sub_Enum1 :: enum {
			ONE,
		}
		Sub_Enum2 :: enum {
			TWO,
		}

		Super_Enum :: union {
			Sub_Enum1,
			Sub_Enum2,
		}

		main :: proc() {
			my_enum: Super_Enum
			my_enum = .ON{*}E
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 3}, end = {line = 2, character = 6}}},
		{range = {start = {line = 15, character = 14}, end = {line = 15, character = 17}}},
	}

	test.expect_rename_locations(t, &source, "RENAMED_ONE", locations[:])
}

@(test)
ast_rename_struct_and_enum_variant_same_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			Bar,
			Bazz
		}

		Bar :: struct {}

		main :: proc() {
			f: Foo
			f = .Ba{*}r
			b := Bar{}
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 6}}},
		{range = {start = {line = 11, character = 8}, end = {line = 11, character = 11}}},
	}
	excluded := []common.Location {
		{range = {start = {line = 7, character = 2}, end = {line = 7, character = 5}}},
		{range = {start = {line = 12, character = 8}, end = {line = 12, character = 11}}},
	}

	test.expect_rename_locations(t, &source, "RenamedBar", locations[:], excluded)
}

@(test)
ast_rename_enum_variant_enumerated_array :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			A,
			B,
		}

		main :: proc() {
			foos := [Foo][Foo][Foo][Foo]Foo {
				.A = {
					.B = {
						.A = {
							.A{*} = .B
						}
					}
				}
			}
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 4}}},
		{range = {start = {line = 9, character = 5}, end = {line = 9, character = 6}}},
		{range = {start = {line = 11, character = 7}, end = {line = 11, character = 8}}},
		{range = {start = {line = 12, character = 8}, end = {line = 12, character = 9}}},
	}

	test.expect_rename_locations(t, &source, "RenamedA", locations[:])
}

@(test)
ast_rename_implicit_enum_infer_from_proc_param_default :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		My_Enum :: enum {
			One,
			Two,
			Three,
			Four,
		}

		my_fn :: proc(my_enum: My_Enum = .Fo{*}ur) {}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 5, character = 3}, end = {line = 5, character = 7}}},
		{range = {start = {line = 8, character = 36}, end = {line = 8, character = 40}}},
	}

	test.expect_rename_locations(t, &source, "RenamedFour", locations[:])
}
