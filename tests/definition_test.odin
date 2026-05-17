package tests

import "core:fmt"
import "core:testing"

import "src:common"

import test "src:testing"

@(test)
ast_goto_bit_set_comp_literal :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		TestEnum :: enum {
			valueOne,
			valueTwo,
		}
		
		EnumIndexedArray :: [TestEnum]u32 {
			.value{*}One = 1,
			.valueTwo = 2,
		}
		`,
	}

	location := common.Location {
		range = {start = {line = 2, character = 3}, end = {line = 2, character = 11}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_bit_set_index_enumerated_array :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		TestEnum :: enum {
			valueOne,
			valueTwo,
		}

		EnumIndexedArray :: [TestEnum]u32 {
			.valueOne = 1,
			.valueTwo = 2,
		}

		my_proc :: proc() -> u32 {
			arr :: EnumIndexedArray
			return arr[.valueO{*}ne]
		}
		`,
	}

	location := common.Location {
		range = {start = {line = 2, character = 3}, end = {line = 2, character = 11}},
	}

	test.expect_definition_locations(t, &source, {location})
}


@(test)
ast_goto_comp_lit_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
        Point :: struct {
            x, y, z : f32,
        }

        main :: proc() {
            point := Point {
                x{*} = 2, y = 5, z = 0,
            }
        }
		`,
	}

	location := common.Location {
		range = {start = {line = 2, character = 12}, end = {line = 2, character = 13}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_struct_definition :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
        Point :: struct {
            x, y, z : f32,
        }

        main :: proc() {
            point := Po{*}int {
                x = 2, y = 5, z = 0,
            }
        }
		`,
	}

	location := common.Location {
		range = {start = {line = 1, character = 8}, end = {line = 1, character = 13}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_comp_lit_field_indexed :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
        Point :: struct {
            x, y, z : f32,
        }

        main :: proc() {
            point := [2]Point {
                {x{*} = 2, y = 5, z = 0},
                {y = 10, y = 20, z = 10},
            }
        }
		`,
	}

	location := common.Location {
		range = {start = {line = 2, character = 12}, end = {line = 2, character = 13}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_untyped_comp_lit_in_proc :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test	
			My_Struct :: struct {
				one: int,
				two: int,
			}

			my_function :: proc(my_struct: My_Struct) {

			}

			main :: proc() {
				my_function({on{*}e = 2, two = 3})
			}
		`,
		packages = {},
	}

	location := common.Location {
		range = {start = {line = 2, character = 4}, end = {line = 2, character = 7}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_bit_field_definition :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test	
			My_Bit_Field :: bit_field uint {
				one: int | 1,
				two: int | 1,
			}

			main :: proc() {
				it: My_B{*}it_Field
			}
		`,
		packages = {},
	}

	location := common.Location {
		range = {start = {line = 1, character = 3}, end = {line = 1, character = 15}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_bit_field_field_definition :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test	
			My_Bit_Field :: bit_field uint {
				one: int | 1,
				two: int | 1,
			}

			main :: proc() {
				it: My_Bit_Field
				it.on{*}e
			}
		`,
		packages = {},
	}

	location := common.Location {
		range = {start = {line = 2, character = 4}, end = {line = 2, character = 7}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_bit_field_field_in_proc :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test	
			My_Struct :: bit_field uint {
				one: int | 1,
				two: int | 2,
			}

			my_function :: proc(my_struct: My_Struct) {

			}

			main :: proc() {
				my_function({on{*}e = 2, two = 3})
			}
		`,
		packages = {},
	}

	location := common.Location {
		range = {start = {line = 2, character = 4}, end = {line = 2, character = 7}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_shadowed_value_decls :: proc(t: ^testing.T) {
	source0 := test.Source {
		main     = `package test
			main :: proc() {
				foo := 1
				
				{
					fo{*}o := 2
				}
			}
		`,
		packages = {},
	}
	test.expect_definition_locations(t, &source0, {{range = {{line = 5, character = 5}, {line = 5, character = 8}}}})

	source1 := test.Source {
		main     = `package test
			main :: proc() {
				foo := 1
				
				{
					foo := 2
					fo{*}o
				}
			}
		`,
		packages = {},
	}
	test.expect_definition_locations(t, &source1, {{range = {{line = 5, character = 5}, {line = 5, character = 8}}}})

	source3 := test.Source {
		main     = `package test
			main :: proc() {
				foo := 1
				
				{
					foo := fo{*}o
				}
			}
		`,
		packages = {},
	}
test.expect_definition_locations(t, &source3, {{range = {{line = 2, character = 4}, {line = 2, character = 7}}}})
}

@(test)
ast_goto_unresolved_call_multi_value_decl_local :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
main :: proc() {
	slot_idx, found := does_not_exist()
	if fo{*}und {
		_ = slot_idx
	}
}
`,
	}

	location := common.Location {
		range = {start = {line = 2, character = 11}, end = {line = 2, character = 16}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_implicit_super_enum_infer_from_assignment :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test	
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
		packages = {},
	}

	location := common.Location {
		range = {start = {line = 2, character = 3}, end = {line = 2, character = 6}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_implicit_enum_infer_from_assignment :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test	
		My_Enum :: enum {
			One,
			Two,
			Three,
			Four,
		}

		my_function :: proc() {
			my_enum: My_Enum
			my_enum = .Fo{*}ur
		}
		`,
		packages = {},
	}

	location := common.Location {
		range = {start = {line = 5, character = 3}, end = {line = 5, character = 7}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_implicit_enum_infer_from_return :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test	
		My_Enum :: enum {
			One,
			Two,
			Three,
			Four,
		}

		my_function :: proc() -> My_Enum {
			return .Fo{*}ur
		}
		`,
		packages = {},
	}

	location := common.Location {
		range = {start = {line = 5, character = 3}, end = {line = 5, character = 7}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_implicit_enum_infer_from_function :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test	
		My_Enum :: enum {
			One,
			Two,
			Three,
			Four,
		}

		my_fn :: proc(my_enum: My_Enum) {

		}

		my_function :: proc() {
			my_fn(.Fo{*}ur)
		}
		`,
		packages = {},
	}

	location := common.Location {
		range = {start = {line = 5, character = 3}, end = {line = 5, character = 7}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_implicit_enum_infer_from_proc_param_default :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test
		My_Enum :: enum {
			One,
			Two,
			Three,
			Four,
		}

		my_fn :: proc(my_enum: My_Enum = .Fo{*}ur) {}
		`,
		packages = {},
	}

	location := common.Location {
		range = {start = {line = 5, character = 3}, end = {line = 5, character = 7}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_implicit_enum_infer_from_assignment_within_switch :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test
		Bar :: enum {
			Bar1,
			Bar2,
		}

		Foo :: enum {
			Foo1,
			Foo2,
		}


		main :: proc() {
			my_foo: Foo
			my_bar: Bar
			switch my_foo {
			case .Foo1:
				my_bar = .B{*}ar2
			case .Foo2:
				my_bar = .Bar1
			}
		}
		`,
		packages = {},
	}

	location := common.Location {
		range = {start = {line = 3, character = 3}, end = {line = 3, character = 7}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_variable_declaration_with_selector_expr :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

		Bar :: struct {
			foo: int,
		}

		main :: proc() {
			bar: [1]Bar
			b{*}ar[0].foo = 5
		}
		`,
		packages = {},
	}

	location := common.Location {
		range = {start = {line = 7, character = 3}, end = {line = 7, character = 6}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_variable_field_definition_with_selector_expr :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

		Bar :: struct {
			foo: int,
		}

		main :: proc() {
			bar: [1]Bar
			bar[0].fo{*}o = 5
		}
		`,
		packages = {},
	}

	location := common.Location {
		range = {start = {line = 3, character = 3}, end = {line = 3, character = 6}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_struct_definition_with_empty_line_at_top_of_file :: proc(t: ^testing.T) {
	source := test.Source {
		main = `
		package test

		Foo :: struct {
			bar: int,
		}

		main :: proc() {
			foo := F{*}oo{}
		}
		`,
	}

	location := common.Location {
		range = {start = {line = 3, character = 2}, end = {line = 3, character = 5}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_enum_from_map_key :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			A,
			B,
		}

		main :: proc() {
			m: map[Foo]int
			m[.A{*}] = 2
		}
		`,
	}

	location := common.Location {
		range = {start = {line = 3, character = 3}, end = {line = 3, character = 4}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_field_definition_with_selector_expr_using_cross_file_global :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

		use :: proc() {
			g.particle.splas{*}h
		}
		`,
		packages = {
			{
				pkg = "",
				source = `package test

				GFX :: struct {
					particle: struct {
						splash: int,
					},
				}

				State :: struct {
					using _: GFX,
				}

				g: ^State
				`,
			},
		},
	}

	location := common.Location {
		range = {start = {line = 4, character = 6}, end = {line = 4, character = 12}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_field_definition_with_selector_expr_cross_file_global_no_using :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

		use :: proc() {
			g.particl{*}e.splash
		}
		`,
		packages = {
			{
				pkg = "",
				source = `package test

				State :: struct {
					particle: struct {
						splash: int,
					},
				}

				g: ^State
				`,
			},
		},
	}

	location := common.Location {
		range = {start = {line = 3, character = 5}, end = {line = 3, character = 13}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_global_definition_cross_file_selector_base :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

		use :: proc() {
			g{*}.particle.splash
		}
		`,
		packages = {
			{
				pkg = "",
				source = `package test

				State :: struct {
					particle: struct {
						splash: int,
					},
				}

				g: ^State
				`,
			},
		},
	}

	location := common.Location {
		range = {start = {line = 8, character = 4}, end = {line = 8, character = 5}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_nested_field_definition_cross_file_global_no_using :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

		use :: proc() {
			g.particle.splas{*}h
		}
		`,
		packages = {
			{
				pkg = "",
				source = `package test

				State :: struct {
					particle: struct {
						splash: int,
					},
				}

				g: ^State
				`,
			},
		},
	}

	location := common.Location {
		range = {start = {line = 4, character = 6}, end = {line = 4, character = 12}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_field_definition_with_selector_expr_using_cross_file_global_uri :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

		use :: proc() {
			g.pip{*}e
		}
		`,
		packages = {
			{
				pkg = "",
				source = `package test

				GFX :: struct {
					pipe: int,
				}

				State :: struct {
					using _: GFX,
				}

				g: ^State
				`,
			},
		},
	}

	location := common.Location {
		uri = "file://test//package.odin",
		range = {start = {line = 3, character = 5}, end = {line = 3, character = 9}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_field_definition_with_selector_expr_using_imported_package_uri :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test
		import gp "gfxpkg"

		State :: struct {
			using _: gp.GFX,
		}

		g: ^State

		use :: proc() {
			g.pip{*}e
		}
		`,
		packages = {
			{
				pkg = "gfxpkg",
				source = `package gfxpkg

				GFX :: struct {
					pipe: int,
				}
				`,
			},
		},
	}

	location := common.Location {
		uri = "file://test/gfxpkg/package.odin",
		range = {start = {line = 3, character = 5}, end = {line = 3, character = 9}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_struct_field_from_proc :: proc (t: ^testing.T) {
	source := test.Source {
		main     = `package test

		Bar :: struct {
			bar: int,
		}

		foo :: proc() -> Bar {
			return Bar{}
		}

		main :: proc() {
			bar := foo().b{*}ar
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 6}}},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_nested_struct_field_selector_definition :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Clock :: struct {
			now: int,
		}

		Sim :: struct {
			cal: Clock,
		}

		GUI :: struct {
			sim: Sim,
		}

		g: GUI

		main :: proc() {
			_ = g.sim.cal.no{*}w
		}
		`,
	}

	location := common.Location {
		range = {start = {line = 3, character = 3}, end = {line = 3, character = 6}},
	}

	test.expect_definition_locations(t, &source, {location})
}

@(test)
ast_goto_proc_named_param :: proc (t: ^testing.T) {
	source := test.Source {
		main     = `package test

		foo :: proc(a: int) {}

		main :: proc() {
			a := "hellope"
			foo(a{*} = 0)
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 14}, end = {line = 2, character = 15}}},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_param_inside_where_clause :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		foo :: proc(x: [2]int)
			where len(x) > 1,
				  type_of(x{*}) == [2]int {
		}
	`,
	}
	locations := []common.Location {
		{range = {start = {line = 1, character = 14}, end = {line = 1, character = 15}}},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_enum_struct_field_without_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: enum {
			A,
			B,
		}

		Bar :: struct {
			foo: Foo,
		}

		main :: proc() {
			bar: Bar = {.A{*}}
		}
	`,
	}
	locations := []common.Location {
		{range = {start = {line = 2, character = 3}, end = {line = 2, character = 4}}},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_soa_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: struct {
			x, y: int,
		}

		main :: proc() {
			foos: #soa[]Foo
			x := foos.x{*}
		}
	`,
	}
	locations := []common.Location {
		{range = {start = {line = 2, character = 3}, end = {line = 2, character = 4}}},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_nested_using_bit_field_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: struct {
			a: int,
			using _: bit_field u8 {
				b: u8 | 4
			}
		}

		main :: proc() {
			foo: Foo
			b := foo.b{*}
		}
	`,
	}
	locations := []common.Location {
		{range = {start = {line = 4, character = 4}, end = {line = 4, character = 5}}},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_nested_using_struct_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: struct {
			a: int,
			using _: struct {
				b: u8
			}
		}

		main :: proc() {
			foo: Foo
			b := foo.b{*}
		}
	`,
	}
	locations := []common.Location {
		{range = {start = {line = 4, character = 4}, end = {line = 4, character = 5}}},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_package_declaration :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)

	append(&packages, test.Package{pkg = "my_package", source = `package my_package
			Bar :: struct{}
		`})
	source := test.Source {
		main = `package test
		import "my_package"

		main :: proc() {
			bar: m{*}y_package.Bar
		}
	`,
		packages = packages[:],
	}
	locations := []common.Location {
		{range = {start = {line = 1, character = 9}, end = {line = 1, character = 21}}},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_package_declaration_with_alias :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)

	append(&packages, test.Package{pkg = "my_package", source = `package my_package
			Bar :: struct{}
		`})
	source := test.Source {
		main = `package test
		import mp "my_package"

		main :: proc() {
			bar: m{*}p.Bar
		}
	`,
		packages = packages[:],
	}
	locations := []common.Location {
		{range = {start = {line = 1, character = 9}, end = {line = 1, character = 11}}},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_selector_reexported_through_package_alias :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)

	append(&packages, test.Package {
		pkg = "bitlib",
		source = `package bitlib
			count_leading_zeros :: proc(x: int) -> int {
				return x
			}
		`,
	})
	append(&packages, test.Package {
		pkg = "rt",
		source = `package rt
			using import bitlib "bitlib"
		`,
	})

	source := test.Source {
		main = `package test
		import rt "rt"

		main :: proc() {
			x := 1
			rt.count_leading_zeros{*}(x)
		}
	`,
		packages = packages[:],
	}
	locations := []common.Location {
		{range = {start = {line = 1, character = 3}, end = {line = 1, character = 22}}},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_proc_group_overload_with_selector :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)

	append(&packages, test.Package{pkg = "my_package", source = `package my_package
			push_back :: proc(arr: ^[dynamic]int, val: int) {}
			push_back_elems :: proc(arr: ^[dynamic]int, vals: ..int) {}
			append :: proc{push_back, push_back_elems}
		`})
	source := test.Source {
		main = `package test
		import mp "my_package"

		main :: proc() {
			arr: [dynamic]int
			mp.app{*}end(&arr, 1)
		}
	`,
		packages = packages[:],
		config = {enable_overload_resolution = true},
	}
	// Should go to push_back (line 1, character 3) instead of append (line 3)
	// because push_back is the overload being used with a single value argument
	locations := []common.Location {
		{range = {start = {line = 1, character = 3}, end = {line = 1, character = 12}}},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_proc_group_overload_identifier :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		push_back :: proc(arr: ^[dynamic]int, val: int) {}
		push_back_elems :: proc(arr: ^[dynamic]int, vals: ..int) {}
		append :: proc{push_back, push_back_elems}

		main :: proc() {
			arr: [dynamic]int
			app{*}end(&arr, 1)
		}
	`,
		config = {enable_overload_resolution = true},
	}
	// Should go to push_back (line 1, character 2) instead of append (line 3)
	// because push_back is the overload being used with a single value argument
	locations := []common.Location {
		{range = {start = {line = 1, character = 2}, end = {line = 1, character = 11}}},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_selector_package_alias_chain_prefers_resolved_target :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)

	append(&packages, test.Package {
		pkg = "backend_sokol",
		source = `package backend_sokol
			make_buffer :: proc(desc: int) -> int {
				return desc
			}
		`,
	})

	append(&packages, test.Package {
		pkg = "backend",
		source = `package backend
			import vsg "backend_sokol"
			make_buffer :: vsg.make_buffer
		`,
	})

	source := test.Source {
		main = `package test
		import sg "backend"

		main :: proc() {
			sg.make_buf{*}fer(1)
		}
	`,
		packages = packages[:],
	}

	locations := []common.Location {
		{
			uri = "file://test/backend_sokol/package.odin",
			range = {start = {line = 1, character = 3}, end = {line = 1, character = 14}},
		},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_identifier_definition_skip_alias_global :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)

	append(&packages, test.Package {
		pkg = "co_pkg",
		source = `package co_pkg
vpos2 :: proc(x: int) -> int {
	return x
}
`,
	})

	source := test.Source {
		main = `package test
import co "co_pkg"

vpos :: co.vpos2

main :: proc() {
	vpo{*}s(1)
}
`,
		packages = packages[:],
		config = {enable_definition_skip_alias = true},
	}

	locations := []common.Location {
		{
			uri = "file://test/co_pkg/package.odin",
			range = {start = {line = 1, character = 0}, end = {line = 1, character = 5}},
		},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_selector_field_nested_using_skip_alias :: proc(t: ^testing.T) {
	source := test.Source{
		main = `package test
Config :: struct {
    seed: int,
}
Gen_Persist :: struct {
    using cfg: Config,
}
Sim :: struct {
    using saved: Gen_Persist,
}
use :: proc(s: ^Sim) {
    _ = s.c{*}fg.seed
}
`,
		config = {enable_definition_skip_alias = true},
	}

	locations := []common.Location{
		{
			range = {start = {line = 5, character = 10}, end = {line = 5, character = 13}},
		},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_identifier_definition_skip_alias_when_config_alias_preserves_location :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)

	append(&packages, test.Package{
		pkg = "toxpkg",
		source = `package toxpkg
EDITOR :: #config(EDITOR, false)
`,
	})

	source := test.Source{
		main = `package test
import tox "toxpkg"

EDITOR :: tox.EDITOR

when EDI{*}TOR {
}
`,
		packages = packages[:],
		config = {enable_definition_skip_alias = true},
	}

	locations := []common.Location{
		{
			uri = "file://test/test.odin",
			range = {start = {line = 3, character = 0}, end = {line = 3, character = 6}},
		},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_fixed_cap_dyn_array_capacity :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: 5

		Bar :: [dynamic; Fo{*}o]int
	`,
	}
	locations := []common.Location {
		{range = {start = {line = 1, character = 2}, end = {line = 1, character = 5}}},
	}

	test.expect_definition_locations(t, &source, locations[:])
}
