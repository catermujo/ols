package tests

import "core:testing"

import "src:common"

import test "src:testing"

@(test)
ast_goto_fixed_array_swizzle_through_package_alias_chain :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)

	append(&packages, test.Package{
		pkg = "co_pkg",
		source = `package co_pkg
p2vec :: [2]i16
Pos2d :: p2vec
`,
	})

	source := test.Source{
		main = `package test
import co "co_pkg"

Pos :: co.Pos2d

use :: proc(pos: Pos) {
	_ = pos.x{*}
}
`,
		packages = packages[:],
	}

	locations := []common.Location{
		{
			uri = "file://test/co_pkg/package.odin",
			range = {start = {line = 1, character = 0}, end = {line = 1, character = 5}},
		},
	}

	test.expect_definition_locations(t, &source, locations[:])
}
