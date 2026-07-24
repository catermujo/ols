package tests

import "core:log"
import "core:os"
import path "core:path/slashpath"
import "core:testing"

import "src:common"
import "src:server"

@(test)
reference_cache_uses_indexed_reverse_package_graph :: proc(t: ^testing.T) {
	server.reference_import_cache_reset()
	defer server.reference_import_cache_reset()

	server.setup_index(server.get_builtin_path())
	defer server.free_index()

	root, err := os.make_directory_temp("", "ols-ref-graph-*", context.temp_allocator)
	if err != nil {
		log.errorf("failed to create temporary directory: %v", err)
		return
	}
	defer os.remove_all(root)

	target_dir := path.join({root, "target"}, context.temp_allocator)
	app_dir := path.join({root, "app"}, context.temp_allocator)
	dependency_dir := path.join({root, "dependency"}, context.temp_allocator)
	other_dir := path.join({root, "other"}, context.temp_allocator)
	dirs := []string{target_dir, app_dir, dependency_dir, other_dir}
	for dir in dirs {
		if err = os.mkdir_all(dir); err != nil {
			log.errorf("failed to create package directory: %v", err)
			return
		}
	}

	target_file := path.join({target_dir, "target.odin"}, context.temp_allocator)
	app_file := path.join({app_dir, "main.odin"}, context.temp_allocator)
	dependency_file := path.join({dependency_dir, "main.odin"}, context.temp_allocator)
	other_file := path.join({other_dir, "main.odin"}, context.temp_allocator)

	sources := []struct {
		file: string,
		source: string,
	}{
		{target_file, `package target
Value :: 1
`},
		{app_file, `package app
import "../target"
`},
		{dependency_file, `package dependency
import "../other"
`},
		{other_file, `package other
`},
	}

	for item in sources {
		if err = os.write_entire_file(item.file, item.source); err != nil {
			log.errorf("failed to write source file: %v", err)
			return
		}
		if index_err := server.index_file(common.create_uri(item.file, context.temp_allocator), item.source);
		   index_err != .None {
			log.errorf("failed to index source file: %v", index_err)
			return
		}
	}

	server.reference_import_cache_ensure_initialized()
	if len(server.reference_import_cache.scanned_roots) != 0 {
		log.errorf("reference cache scanned roots during lazy initialization: %v", server.reference_import_cache.scanned_roots)
	}

	paths := make(map[string]struct{}, context.temp_allocator)
	server.collect_reference_cached_importers(target_dir, &paths)

	if _, ok := paths[app_file]; !ok {
		log.errorf("expected indexed importer %q in candidates: %v", app_file, paths)
	}
	if _, ok := paths[dependency_file]; ok {
		log.errorf("unexpected unrelated dependency %q in candidates", dependency_file)
	}
	if len(server.reference_import_cache.scanned_roots) != 0 {
		log.errorf("reference cache scanned roots for indexed package: %v", server.reference_import_cache.scanned_roots)
	}
}
