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

@(test)
ast_goto_fixed_array_swizzle_through_generated_same_package_distinct_reexport :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)

	append(&packages, test.Package{
		pkg = "tox",
		source = `package tox
pvec :: [2]i16
Chunk_Key :: distinct pvec
`,
	})
	append(&packages, test.Package{
		pkg = "",
		file = "test/@tox_reexport.generated.odin",
		source = `package test
import tox "tox"

Chunk_Key :: tox.Chunk_Key
`,
	})

	source := test.Source{
		main = `package test
use :: proc(key: Chunk_Key) {
	_ = key.x{*}
}
`,
		packages = packages[:],
	}

	locations := []common.Location{
		{
			uri = "file://test/tox/package.odin",
			range = {start = {line = 2, character = 0}, end = {line = 2, character = 9}},
		},
	}

	test.expect_definition_locations(t, &source, locations[:])
}
