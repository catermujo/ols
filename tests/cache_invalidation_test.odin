package tests

import "core:log"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:testing"

import "src:common"
import "src:server"

@(test)
index_file_clears_cross_file_resolve_cache :: proc(t: ^testing.T) {
	server.setup_index(server.get_builtin_path())
	defer server.free_index()

	server.file_resolve_cache.files = make(map[string]server.FileResolve)
	server.file_resolve_cache.files["file:///tmp/other.odin"] = {}

	uri := common.create_uri("/tmp/index-cache-test.odin", context.temp_allocator)
	if result := server.index_file(uri, "package test\nID :: u32\n"); result != .None {
		log.errorf("index_file failed: %v", result)
	}

	if len(server.file_resolve_cache.files) != 0 {
		log.error(t, "expected cross-file resolve cache to be cleared")
	}
}

parse_index_test_file :: proc(fullpath, source: string) -> (ast.File, bool) {
	pkg := new(ast.Package, context.temp_allocator)
	pkg.kind = .Normal
	pkg.fullpath = fullpath
	pkg.name = "test"

	file := ast.File{
		fullpath = fullpath,
		src      = source,
		pkg      = pkg,
	}

	parser_state := parser.Parser{
		flags = {.Optional_Semicolons},
	}

	allocator := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = allocator

	return file, parser.parse_file(&parser_state, &file)
}

@(test)
collect_symbols_remove_reclaims_symbol_allocations :: proc(t: ^testing.T) {
	old_allocator := context.allocator
	tracking_allocator: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracking_allocator, old_allocator)
	context.allocator = mem.tracking_allocator(&tracking_allocator)
	defer {
		context.allocator = old_allocator
		mem.tracking_allocator_destroy(&tracking_allocator)
	}

	server.indexer.index = server.make_memory_index(server.make_symbol_collection(context.allocator, &common.config))
	defer server.indexer.index = {}

	fullpath := "/tmp/ols-symbol-leak-test.odin"
	uri := common.create_uri(fullpath, context.temp_allocator)

	source := `package test

// type docs
Thing :: struct {
	field: int,
}

Flags :: enum { A, B }
Variant :: union { int, Thing }
Bits :: bit_field u32 {
	enabled: bool | 1,
}

Numbers :: map[string]int
Buffer :: [dynamic]int
Names :: []string
Multi :: [^]Thing
Alias :: distinct Thing

Make_Thing :: proc(input: Thing) -> Thing {
	return input
}

Value :: Thing{field = 1}
`

	for _ in 0..<3 {
		file, ok := parse_index_test_file(fullpath, source)
		if !ok {
			log.error(t, "failed to parse test source")
			return
		}

		if err := server.collect_symbols(&server.indexer.index.collection, file, uri.uri); err != .None {
			log.errorf("collect_symbols failed: %v", err)
			return
		}

		server.remove_indexed_file_data(uri.uri)
		free_all(context.temp_allocator)
	}

	server.free_index()

	if len(tracking_allocator.allocation_map) != 0 {
		log.errorf("expected no tracked symbol allocations, found %v", len(tracking_allocator.allocation_map))
	}
}
