package tests

import "core:testing"

import "src:common"

import test "src:testing"

@(test)
ast_goto_fixed_array_swizzle_through_package_alias_chain :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
import co "co_pkg"
Pos :: co.Pos2d
use :: proc(pos: Pos) {
	_ = pos.x{*}
}
`,
		packages = {{
			pkg = "co_pkg",
			source = `package co_pkg
p2vec :: [2]i16
Pos2d :: p2vec
`,
		}},
	}
	test.expect_definition_locations(t, &source, {common.Location {
		uri = "file://test/co_pkg/package.odin",
		range = {{line = 1, character = 0}, {line = 1, character = 5}},
	}})
}

@(test)
ast_goto_fixed_array_swizzle_through_generated_reexport :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
use :: proc(key: Chunk_Key) {
	_ = key.x{*}
}
`,
		files = {{
			name = "@tox_reexport.generated.odin",
			source = `package test
import other "other"
import tox "tox"
Chunk_Key :: tox.Chunk_Key
`,
		}},
		packages = {{
			pkg = "tox",
			source = `package tox
pvec :: [2]i16
Chunk_Key :: distinct pvec
`,
		}, {
			pkg = "other",
			source = `package other
Chunk_Key :: distinct [2]i16
`,
		}},
	}
	test.expect_definition_locations(t, &source, {common.Location {
		uri = "file://test/tox/package.odin",
		range = {{line = 2, character = 0}, {line = 2, character = 9}},
	}})
}
