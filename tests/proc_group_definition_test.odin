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

@(test)
ast_goto_proc_group_overload_identifier_with_proc_literal_arg :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
Foo :: enum { A }
f0 :: proc(s: string, opts: []string, v: ^int) -> bool { return false }
f1 :: proc(s: string, $E: typeid, v: ^int, p: proc(value: E) -> string) -> bool { return false }
g :: proc{f0, f1}

main :: proc() {
	x := 0
	g{*}("x", Foo, &x, proc(v: Foo) -> string { return "" })
}
`,
		config = {enable_overload_resolution = true},
	}

	locations := []common.Location {
		{
			range = {start = {line = 3, character = 0}, end = {line = 3, character = 2}},
		},
	}

	test.expect_definition_locations(t, &source, locations[:])
}

@(test)
ast_goto_proc_group_overload_identifier_with_typeid_arg :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
Foo :: enum { A }
f0 :: proc(s: string, opts: []string, v: ^int) -> bool { return false }
f1 :: proc(s: string, $E: typeid, v: ^int) -> bool { return false }
g :: proc{f0, f1}

main :: proc() {
	x := 0
	g{*}("x", Foo, &x)
}
`,
		config = {enable_overload_resolution = true},
	}

	locations := []common.Location {
		{
			range = {start = {line = 3, character = 0}, end = {line = 3, character = 2}},
		},
	}

	test.expect_definition_locations(t, &source, locations[:])
}
