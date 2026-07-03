package tests

import "core:testing"

import "src:common"

import test "src:testing"

@(test)
ast_goto_proc_group_with_selector_can_disable_overload_resolution :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)

	append(&packages, test.Package{pkg = "my_package", source = `package my_package
			push_back :: proc(arr: ^[dynamic]int, val: int) {}
			push_back_elems :: proc(arr: ^[dynamic]int, vals: ..int) {}
			append :: proc{push_back, push_back_elems}
		`})
	source := test.Source{
		main = `package test
		import mp "my_package"

		main :: proc() {
			arr: [dynamic]int
			mp.app{*}end(&arr, 1)
		}
	`,
		packages = packages[:],
		config = {enable_overload_resolution = false},
	}

	locations := []common.Location{
		{
			uri = "file://test/my_package/package.odin",
			range = {start = {line = 3, character = 3}, end = {line = 3, character = 9}},
		},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_proc_group_identifier_can_disable_overload_resolution :: proc(t: ^testing.T) {
	source := test.Source{
		main = `package test
		push_back :: proc(arr: ^[dynamic]int, val: int) {}
		push_back_elems :: proc(arr: ^[dynamic]int, vals: ..int) {}
		append :: proc{push_back, push_back_elems}

		main :: proc() {
			arr: [dynamic]int
			app{*}end(&arr, 1)
		}
	`,
		config = {enable_overload_resolution = false},
	}

	locations := []common.Location{
		{
			range = {start = {line = 3, character = 2}, end = {line = 3, character = 8}},
		},
	}

	test.expect_definition_locations(t, &source, locations[:])
}
