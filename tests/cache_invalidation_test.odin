package tests

import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import path "core:path/slashpath"
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

@(test)
index_file_preserves_symbols_after_parse_failure :: proc(t: ^testing.T) {
	server.setup_index(server.get_builtin_path())
	defer server.free_index()

	fullpath := "/tmp/index-parse-failure-test.odin"
	uri := common.create_uri(fullpath, context.temp_allocator)

	if result := server.index_file(uri, "package test\nValue :: int\n"); result != .None {
		log.errorf("initial index_file failed: %v", result)
		return
	}

	pkg, ok := server.indexer.index.collection.packages["/tmp"]
	if !ok {
		log.error(t, "expected indexed package")
		return
	}
	if _, ok := pkg.symbols["Value"]; !ok {
		log.error(t, "expected initial symbol")
		return
	}

	if result := server.index_file(uri, "package test\nValue ::\n"); result != .None {
		log.errorf("failed index_file returned error: %v", result)
		return
	}

	pkg, ok = server.indexer.index.collection.packages["/tmp"]
	if !ok {
		log.error(t, "expected package after failed reindex")
		return
	}
	if _, ok := pkg.symbols["Value"]; !ok {
		log.error(t, "failed reindex removed valid symbol")
	}

	if result := server.index_file(uri, "Value :: int\n"); result != .None {
		log.errorf("missing-package index_file returned error: %v", result)
		return
	}

	pkg, ok = server.indexer.index.collection.packages["/tmp"]
	if !ok {
		log.error(t, "expected package after missing-package reindex")
		return
	}
	if _, ok := pkg.symbols["Value"]; !ok {
		log.error(t, "missing-package reindex removed valid symbol")
	}
}

@(test)
try_build_package_skips_parser_recovery_ast :: proc(t: ^testing.T) {
	server.setup_index(server.get_builtin_path())
	defer server.free_index()

	root, err := os.make_directory_temp("", "ols-index-recovery-*", context.temp_allocator)
	if err != nil {
		log.errorf("failed to create temporary package: %v", err)
		return
	}
	defer os.remove_all(root)

	good_file := path.join({root, "good.odin"}, context.temp_allocator)
	bad_file := path.join({root, "recovery.odin"}, context.temp_allocator)
	if err = os.write_entire_file(good_file, "package recovery\nValue :: int\n"); err != nil {
		log.errorf("failed to write valid package file: %v", err)
		return
	}
	if err = os.write_entire_file(bad_file, "package recovery\nimport \"core:fmt\"\nValue ::\n"); err != nil {
		log.errorf("failed to write recovery package file: %v", err)
		return
	}

	server.try_build_package(root)

	if server.build_cache.indexed_files[bad_file] {
		log.error(t, "parser recovery AST was indexed")
	}
	if !server.build_cache.indexed_files[good_file] {
		log.error(t, "valid package file was not indexed")
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

@(test)
document_refresh_restores_context_allocator :: proc(t: ^testing.T) {
	old_allocator := context.allocator
	allocator := new(virtual.Arena, context.temp_allocator)
	_ = virtual.arena_init_growing(allocator)
	defer virtual.arena_destroy(allocator)
	defer context.allocator = old_allocator

	fullpath := "/tmp/ols-document-allocator-test.odin"
	source := "package test\nValue :: int\n"
	document := server.Document {
		fullpath  = fullpath,
		uri       = common.create_uri(fullpath, context.temp_allocator),
		text      = transmute([]u8)source,
		used_text = len(source),
		allocator = allocator,
	}

	config := common.Config{enable_unused_imports_reporting = true}
	if err := server.document_refresh(&document, &config, nil); err != .None {
		log.errorf("document_refresh failed: %v", err)
		return
	}

	if context.allocator.data != old_allocator.data {
		log.error(t, "document_refresh changed the caller allocator")
	}
}

@(test)
setup_index_restores_context_allocator :: proc(t: ^testing.T) {
	old_allocator := context.allocator
	server.setup_index(server.get_builtin_path())
	defer server.free_index()

	if context.allocator.data != old_allocator.data {
		log.error(t, "setup_index changed the caller allocator")
	}
}

@(test)
document_refresh_stops_parser_recovery :: proc(t: ^testing.T) {
	allocator := new(virtual.Arena, context.temp_allocator)
	_ = virtual.arena_init_growing(allocator)
	defer virtual.arena_destroy(allocator)

	source := "package test\nwith value {}\n"
	document := server.Document {
		fullpath  = "/tmp/ols-parser-recovery-test.odin",
		uri       = common.create_uri("/tmp/ols-parser-recovery-test.odin", context.temp_allocator),
		text      = transmute([]u8)source,
		used_text = len(source),
		allocator = allocator,
	}

	if err := server.document_refresh(&document, &common.Config{}, nil); err != .None {
		log.errorf("document_refresh failed: %v", err)
	}
}
