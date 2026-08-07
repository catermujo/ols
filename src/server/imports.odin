package server

import "core:mem"

import "base:runtime"

// Full-file resolution for unused-import diagnostics can become explosively
// expensive on large generated/gameplay files. Keep this optional diagnostic
// bounded; the normal document/index features still process those files.
UNUSED_IMPORT_RESOLVE_MAX_SOURCE_BYTES :: 64 * 1024

find_unused_imports :: proc(document: ^Document, allocator := context.temp_allocator) -> []Package {
	if document == nil || document.used_text > UNUSED_IMPORT_RESOLVE_MAX_SOURCE_BYTES {
		return nil
	}

	arena: runtime.Arena

	_ = runtime.arena_init(&arena, mem.Megabyte * 40, runtime.default_allocator())

	defer runtime.arena_destroy(&arena)
	old_allocator := context.allocator
	defer context.allocator = old_allocator

	context.allocator = runtime.arena_allocator(&arena)

	symbols_and_nodes := resolve_entire_file(document)

	pkgs := make(map[string]struct{}, context.temp_allocator)

	for _, v in symbols_and_nodes {
		pkgs[v.symbol.pkg] = {}
	}

	unused := make([dynamic]Package, allocator)

	for imp in document.imports {
		if imp.base != "_" && imp.name not_in pkgs {
			append(&unused, imp)
		}
	}

	return unused[:]
}
