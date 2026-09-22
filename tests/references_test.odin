package tests

import "base:runtime"

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "src:common"
import "src:server"

import test "src:testing"

@(test)
reference_candidate_same_package :: proc(t: ^testing.T) {
	testing.expect(t, server.source_may_reference_package(
		"/repo/pkg/main.odin", "/repo/pkg", "package pkg\nuse :: proc() { Target() }",
	))
}

@(test)
ast_references_identifier_inside_with :: proc(t: ^testing.T) {
	source := test.Source{
		main = `package test
cleanup :: proc() {}
scoped :: proc() #scope_exit(.implicit, cleanup()) {}
target :: proc() {}
main :: proc() {
	target()
	with scoped() {
		tar{*}get()
	}
}
`,
	}

	locations := []common.Location{
		{range = {start = {line = 3, character = 0}, end = {line = 3, character = 6}}},
		{range = {start = {line = 5, character = 1}, end = {line = 5, character = 7}}},
		{range = {start = {line = 7, character = 2}, end = {line = 7, character = 8}}},
	}
	test.expect_reference_locations(t, &source, locations)
}

@(test)
ast_references_skip_aliases_without_dropping_target_reference :: proc(t: ^testing.T) {
	source := test.Source{
		main = `package test
Target :: struct {}
Alias :: Target
main :: proc() {
	x: Alias
	y: Tar{*}get
}
`,
		config = {enable_definition_skip_aliases = true},
	}

	locations := []common.Location{
		{range = {start = {line = 1, character = 0}, end = {line = 1, character = 6}}},
		{range = {start = {line = 2, character = 9}, end = {line = 2, character = 15}}},
		{range = {start = {line = 4, character = 4}, end = {line = 4, character = 9}}},
		{range = {start = {line = 5, character = 4}, end = {line = 5, character = 10}}},
	}
	test.expect_reference_locations(t, &source, locations)
}

@(test)
reference_candidate_relative_import :: proc(t: ^testing.T) {
	testing.expect(t, server.source_may_reference_package(
		"/repo/app/main.odin", "/repo/lib/math",
		"package app\nimport math \"../lib/math\"\nuse :: proc() { math.Target() }",
	))
}

@(test)
reference_candidate_skips_unrelated_package :: proc(t: ^testing.T) {
	testing.expect(t, !server.source_may_reference_package(
		"/repo/app/main.odin", "/repo/lib/math",
		"package app\nuse :: proc() { Target() }",
	))
}

@(test)
reference_candidate_cache_reuses_and_invalidates_scan :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "ols-reference-cache-*", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)
	lib, _ := filepath.join({root, "lib"}, context.temp_allocator)
	app, _ := filepath.join({root, "app"}, context.temp_allocator)
	if !testing.expect(t, os.make_directory(lib) == nil) do return
	if !testing.expect(t, os.make_directory(app) == nil) do return
	file, _ := filepath.join({app, "main.odin"}, context.temp_allocator)
	source := "package app\nimport \"../lib\"\n"
	if !testing.expect(t, os.write_entire_file(file, source) == nil) do return
	testing.expect(t, server.source_may_reference_package(file, lib, source))

	old_folders := common.config.workspace_folders
	common.config.workspace_folders = make([dynamic]common.WorkspaceFolder, context.temp_allocator)
	append(&common.config.workspace_folders, common.WorkspaceFolder{uri = common.create_uri(root, context.temp_allocator).uri})
	defer {
		server.reference_candidate_cache_reset()
		common.config.workspace_folders = old_folders
	}

	first := make(map[string]struct{}, context.temp_allocator)
	server.collect_workspace_reference_candidates(lib, &first)
	_, found := first[file]
	testing.expect(t, found)

	if !testing.expect(t, os.write_entire_file(file, "package app\n") == nil) do return
	cached := make(map[string]struct{}, context.temp_allocator)
	server.collect_workspace_reference_candidates(lib, &cached)
	_, found = cached[file]
	testing.expect(t, found)

	server.reference_candidate_cache_reset()
	refreshed := make(map[string]struct{}, context.temp_allocator)
	server.collect_workspace_reference_candidates(lib, &refreshed)
	_, found = refreshed[file]
	testing.expect(t, !found)
}

@(test)
reference_candidate_graph_reaches_importers_without_unrelated_reads :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "ols-reference-graph-*", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)

	lib, _ := filepath.join({root, "lib"}, context.temp_allocator)
	direct, _ := filepath.join({root, "direct"}, context.temp_allocator)
	transitive, _ := filepath.join({root, "transitive"}, context.temp_allocator)
	app, _ := filepath.join({root, "app"}, context.temp_allocator)
	unrelated, _ := filepath.join({root, "unrelated"}, context.temp_allocator)
	collection, _ := filepath.join({root, "collection"}, context.temp_allocator)
	dep, _ := filepath.join({collection, "dep"}, context.temp_allocator)
	if !testing.expect(t, os.make_directory(lib) == nil) do return
	if !testing.expect(t, os.make_directory(direct) == nil) do return
	if !testing.expect(t, os.make_directory(transitive) == nil) do return
	if !testing.expect(t, os.make_directory(app) == nil) do return
	if !testing.expect(t, os.make_directory(unrelated) == nil) do return
	if !testing.expect(t, os.make_directory(collection) == nil) do return
	if !testing.expect(t, os.make_directory(dep) == nil) do return

	lib_file, _ := filepath.join({lib, "source.odin"}, context.temp_allocator)
	direct_file, _ := filepath.join({direct, "main.odin"}, context.temp_allocator)
	sibling_file, _ := filepath.join({direct, "sibling.odin"}, context.temp_allocator)
	transitive_file, _ := filepath.join({transitive, "main.odin"}, context.temp_allocator)
	app_file, _ := filepath.join({app, "main.odin"}, context.temp_allocator)
	unrelated_file, _ := filepath.join({unrelated, "main.odin"}, context.temp_allocator)
	dep_file, _ := filepath.join({dep, "source.odin"}, context.temp_allocator)

	testing.expect(t, os.write_entire_file(lib_file, "package lib\nTarget :: 1\n") == nil)
	testing.expect(t, os.write_entire_file(direct_file, "package direct\nimport \"../lib\"\n") == nil)
	testing.expect(t, os.write_entire_file(sibling_file, "package direct\n") == nil)
	testing.expect(t, os.write_entire_file(transitive_file, "package transitive\nimport \"../direct\"\n") == nil)
	testing.expect(t, os.write_entire_file(app_file, "package app\nimport \"col:dep\"\n") == nil)
	testing.expect(t, os.write_entire_file(unrelated_file, "package unrelated\nTarget :: 1\n") == nil)
	testing.expect(t, os.write_entire_file(dep_file, "package dep\nTarget :: 1\n") == nil)

	old_folders := common.config.workspace_folders
	old_collections := common.config.collections
	common.config.workspace_folders = make([dynamic]common.WorkspaceFolder, context.temp_allocator)
	append(&common.config.workspace_folders, common.WorkspaceFolder{uri = common.create_uri(root, context.temp_allocator).uri})
	common.config.collections = make(map[string]string, context.temp_allocator)
	common.config.collections["col"] = collection
	defer {
		server.reference_candidate_cache_reset()
		common.config.workspace_folders = old_folders
		common.config.collections = old_collections
	}

	server.reference_candidate_cache_reset()
	lib_candidates := make(map[string]struct{}, context.temp_allocator)
	server.collect_workspace_reference_candidates(lib, &lib_candidates)
	_, found := lib_candidates[lib_file]
	testing.expect(t, found)
	_, found = lib_candidates[direct_file]
	testing.expect(t, found)
	_, found = lib_candidates[sibling_file]
	testing.expect(t, found)
	_, found = lib_candidates[transitive_file]
	testing.expect(t, found)
	_, found = lib_candidates[app_file]
	testing.expect(t, !found)
	_, found = lib_candidates[unrelated_file]
	testing.expect(t, !found)

	if !testing.expect(t, os.write_entire_file(unrelated_file, "package unrelated\n\"\n") == nil) do return
	dep_candidates := make(map[string]struct{}, context.temp_allocator)
	server.collect_workspace_reference_candidates(dep, &dep_candidates)
	_, found = dep_candidates[dep_file]
	testing.expect(t, found)
	_, found = dep_candidates[app_file]
	testing.expect(t, found)
	_, found = dep_candidates[unrelated_file]
	testing.expect(t, !found)
}

@(test)
reference_candidate_graph_invalidates_on_document_open_and_close :: proc(t: ^testing.T) {
	previous_allocator := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = previous_allocator
	root, err := os.make_directory_temp("", "ols-reference-open-close-*", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)

	lib, _ := filepath.join({root, "lib"}, context.temp_allocator)
	existing, _ := filepath.join({root, "existing"}, context.temp_allocator)
	new_pkg, _ := filepath.join({root, "new"}, context.temp_allocator)
	node_modules, _ := filepath.join({root, "node_modules"}, context.temp_allocator)
	hidden_pkg, _ := filepath.join({node_modules, "hidden"}, context.temp_allocator)
	if !testing.expect(t, os.make_directory(lib) == nil) do return
	if !testing.expect(t, os.make_directory(existing) == nil) do return
	if !testing.expect(t, os.make_directory(new_pkg) == nil) do return
	if !testing.expect(t, os.make_directory(node_modules) == nil) do return
	if !testing.expect(t, os.make_directory(hidden_pkg) == nil) do return

	lib_file, _ := filepath.join({lib, "source.odin"}, context.temp_allocator)
	existing_file, _ := filepath.join({existing, "main.odin"}, context.temp_allocator)
	new_file, _ := filepath.join({new_pkg, "main.odin"}, context.temp_allocator)
	hidden_file, _ := filepath.join({hidden_pkg, "main.odin"}, context.temp_allocator)
	if !testing.expect(t, os.write_entire_file(lib_file, "package lib\nTarget :: 1\n") == nil) do return
	if !testing.expect(t, os.write_entire_file(existing_file, "package existing\nimport \"../lib\"\n") == nil) do return

	old_folders := common.config.workspace_folders
	old_collections := common.config.collections
	old_documents := server.document_storage.documents
	old_free_allocators := server.document_storage.free_allocators
	common.config.workspace_folders = make([dynamic]common.WorkspaceFolder, context.temp_allocator)
	append(&common.config.workspace_folders, common.WorkspaceFolder{uri = common.create_uri(root, context.temp_allocator).uri})
	common.config.collections = make(map[string]string, context.temp_allocator)
	server.document_storage.documents = make(map[string]server.Document)
	server.document_storage.free_allocators = nil
	defer {
		server.reference_candidate_cache_reset()
		server.document_storage_shutdown()
		server.free_index()
		server.document_storage.documents = old_documents
		server.document_storage.free_allocators = old_free_allocators
		common.config.workspace_folders = old_folders
		common.config.collections = old_collections
	}

	server.reference_candidate_cache_reset()
	server.setup_index(server.get_builtin_path())
	initial := make(map[string]struct{}, context.temp_allocator)
	server.collect_workspace_reference_candidates(lib, &initial)

	new_source := strings.clone("package new\nimport \"../lib\"\n")
	uri := common.create_uri(new_file, context.temp_allocator)
	if !testing.expect(t, server.document_open(uri.uri, new_source, &common.config, nil) == .None) do return

	opened := make(map[string]struct{}, context.temp_allocator)
	server.collect_workspace_reference_candidates(lib, &opened)
	_, found := opened[new_file]
	testing.expect(t, found)
	_, found = opened[existing_file]
	testing.expect(t, found)

	hidden_source := strings.clone("package hidden\nimport \"../../lib\"\n")
	hidden_uri := common.create_uri(hidden_file, context.temp_allocator)
	if !testing.expect(t, server.document_open(hidden_uri.uri, hidden_source, &common.config, nil) == .None) do return
	blacklisted := make(map[string]struct{}, context.temp_allocator)
	server.collect_workspace_reference_candidates(lib, &blacklisted)
	_, found = blacklisted[hidden_file]
	testing.expect(t, !found)
	_, found = blacklisted[new_file]
	testing.expect(t, found)
	if !testing.expect(t, server.document_close(hidden_uri.uri) == .None) do return

	without_import := make([dynamic]server.TextDocumentContentChangeEvent, context.temp_allocator)
	append(&without_import, server.TextDocumentContentChangeEvent{text = "package new\n"})
	if !testing.expect(t, server.document_apply_changes(uri.uri, without_import, 1, &common.config, nil) == .None) do return
	changed := make(map[string]struct{}, context.temp_allocator)
	server.collect_workspace_reference_candidates(lib, &changed)
	_, found = changed[new_file]
	testing.expect(t, !found)

	with_import := make([dynamic]server.TextDocumentContentChangeEvent, context.temp_allocator)
	append(&with_import, server.TextDocumentContentChangeEvent{text = new_source})
	if !testing.expect(t, server.document_apply_changes(uri.uri, with_import, 2, &common.config, nil) == .None) do return
	changed = make(map[string]struct{}, context.temp_allocator)
	server.collect_workspace_reference_candidates(lib, &changed)
	_, found = changed[new_file]
	testing.expect(t, found)

	if !testing.expect(t, os.write_entire_file(new_file, "package new\n") == nil) do return
	if !testing.expect(t, server.document_close(uri.uri) == .None) do return
	closed := make(map[string]struct{}, context.temp_allocator)
	server.collect_workspace_reference_candidates(lib, &closed)
	_, found = closed[new_file]
	testing.expect(t, !found)
	_, found = closed[existing_file]
	testing.expect(t, found)
}

@(test)
reference_open_document_normalizes_ancestor_checks :: proc(t: ^testing.T) {
	previous_allocator := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = previous_allocator
	root, err := os.make_directory_temp("", "ols-reference-normalized-path-*", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)

	lib, _ := filepath.join({root, "lib"}, context.temp_allocator)
	if !testing.expect(t, os.make_directory(lib) == nil) do return
	lib_file, _ := filepath.join({lib, "source.odin"}, context.temp_allocator)
	if !testing.expect(t, os.write_entire_file(lib_file, "package lib\nTarget :: 1\n") == nil) do return

	old_folders := common.config.workspace_folders
	old_collections := common.config.collections
	old_documents := server.document_storage.documents
	old_free_allocators := server.document_storage.free_allocators
	common.config.workspace_folders = make([dynamic]common.WorkspaceFolder, context.temp_allocator)
	append(&common.config.workspace_folders, common.WorkspaceFolder{uri = common.create_uri(root, context.temp_allocator).uri})
	common.config.collections = make(map[string]string, context.temp_allocator)
	server.document_storage.documents = make(map[string]server.Document)
	server.document_storage.free_allocators = nil
	defer {
		server.reference_candidate_cache_reset()
		server.document_storage_shutdown()
		server.free_index()
		server.document_storage.documents = old_documents
		server.document_storage.free_allocators = old_free_allocators
		common.config.workspace_folders = old_folders
		common.config.collections = old_collections
	}

	server.reference_candidate_cache_reset()
	server.setup_index(server.get_builtin_path())
	initial := make(map[string]struct{}, context.temp_allocator)
	server.collect_workspace_reference_candidates(lib, &initial)

	unsaved_path := strings.concatenate({root, "/node_modules/../allowed/main.odin"}, context.temp_allocator)
	source := strings.clone("package allowed\nimport \"../lib\"\n")
	uri := common.create_uri(unsaved_path, context.temp_allocator)
	if !testing.expect(t, server.document_open(uri.uri, source, &common.config, nil) == .None) do return

	candidates := make(map[string]struct{}, context.temp_allocator)
	server.collect_workspace_reference_candidates(lib, &candidates)
	_, found := candidates[unsaved_path]
	testing.expect(t, found)
}

@(test)
reference_open_document_alias_uses_live_reference_and_rename_results :: proc(t: ^testing.T) {
	previous_allocator := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = previous_allocator
	root, err := os.make_directory_temp("", "ols-reference-open-alias-*", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)

	lib, _ := filepath.join({root, "lib"}, context.temp_allocator)
	node_modules, _ := filepath.join({root, "node_modules"}, context.temp_allocator)
	if !testing.expect(t, os.make_directory(lib) == nil) do return
	if !testing.expect(t, os.make_directory(node_modules) == nil) do return
	source_file, _ := filepath.join({lib, "source.odin"}, context.temp_allocator)
	disk_file, _ := filepath.join({lib, "main.odin"}, context.temp_allocator)
	if !testing.expect(t, os.write_entire_file(source_file, "package lib\nTarget :: 1\n") == nil) do return
	if !testing.expect(t, os.write_entire_file(disk_file, "package lib\nstale := Target\n") == nil) do return

	old_folders := common.config.workspace_folders
	old_collections := common.config.collections
	old_documents := server.document_storage.documents
	old_free_allocators := server.document_storage.free_allocators
	common.config.workspace_folders = make([dynamic]common.WorkspaceFolder, context.temp_allocator)
	append(&common.config.workspace_folders, common.WorkspaceFolder{uri = common.create_uri(root, context.temp_allocator).uri})
	common.config.collections = make(map[string]string, context.temp_allocator)
	server.document_storage.documents = make(map[string]server.Document)
	server.document_storage.free_allocators = nil
	defer {
		server.reference_candidate_cache_reset()
		server.document_storage_shutdown()
		server.free_index()
		server.document_storage.documents = old_documents
		server.document_storage.free_allocators = old_free_allocators
		common.config.workspace_folders = old_folders
		common.config.collections = old_collections
	}

	server.reference_candidate_cache_reset()
	server.setup_index(server.get_builtin_path())
	source_uri := common.create_uri(source_file, context.temp_allocator)
	if !testing.expect(t, server.document_open(source_uri.uri, strings.clone("package lib\nTarget :: 1\n"), &common.config, nil) == .None) do return
	disk_uri := common.create_uri(disk_file, context.temp_allocator)
	document := server.document_get(source_uri.uri)
	if !testing.expect(t, document != nil) do return
	server.reference_resolution_test_reset()
	fresh_locations, fresh_ok := server.get_references(document, {line = 1, character = 0}, config = &common.config)
	if !testing.expect(t, fresh_ok) do return
	first_parse_count := server.reference_resolution_test_parse_count_get()
	testing.expect(t, first_parse_count > 0)
	fresh_disk_locations := 0
	for location in fresh_locations {
		if strings.equal_fold(location.uri, disk_uri.uri) do fresh_disk_locations += 1
	}
	testing.expect(t, len(fresh_locations) == 2)
	testing.expect(t, fresh_disk_locations == 1)
	fresh_workspace, fresh_rename_ok := server.get_rename(document, "Renamed", {line = 1, character = 0}, &common.config)
	if !testing.expect(t, fresh_rename_ok) do return
	fresh_disk_edits, fresh_disk_found := fresh_workspace.changes[disk_uri.uri]
	testing.expect(t, fresh_disk_found)
	testing.expect(t, len(fresh_disk_edits) == 1)
	testing.expect(t, server.reference_resolution_test_parse_count_get() == first_parse_count)
	testing.expect(t, server.reference_resolved_cache_test_entry_count() <= 32)
	server.document_release(document)

	live_path := strings.concatenate({root, "/node_modules/../lib/main.odin"}, context.temp_allocator)
	live_uri := common.create_uri(live_path, context.temp_allocator)
	if !testing.expect(t, server.document_open(live_uri.uri, strings.clone("package lib\nfirst := Target\nsecond := Target\n"), &common.config, nil) == .None) do return
	document = server.document_get(source_uri.uri)
	if !testing.expect(t, document != nil) do return
	defer server.document_release(document)

	locations, ok := server.get_references(document, {line = 1, character = 0}, config = &common.config)
	if !testing.expect(t, ok) do return
	live_locations := 0
	for location in locations {
		if strings.equal_fold(location.uri, live_uri.uri) do live_locations += 1
		if strings.equal_fold(location.uri, disk_uri.uri) do testing.expect(t, false)
	}
	testing.expect(t, len(locations) == 3)
	testing.expect(t, live_locations == 2)

	workspace, rename_ok := server.get_rename(document, "Renamed", {line = 1, character = 0}, &common.config)
	if !testing.expect(t, rename_ok) do return
	_, disk_found := workspace.changes[disk_uri.uri]
	testing.expect(t, !disk_found)
	live_edits, live_found := workspace.changes[live_uri.uri]
	testing.expect(t, live_found)
	testing.expect(t, len(live_edits) == 2)

	if !testing.expect(t, server.document_close(live_uri.uri) == .None) do return
	closed_locations, closed_ok := server.get_references(document, {line = 1, character = 0}, config = &common.config)
	if !testing.expect(t, closed_ok) do return
	closed_disk_locations := 0
	for location in closed_locations {
		if strings.equal_fold(location.uri, disk_uri.uri) do closed_disk_locations += 1
	}
	testing.expect(t, len(closed_locations) == 2)
	testing.expect(t, closed_disk_locations == 1)
	closed_workspace, closed_rename_ok := server.get_rename(document, "Renamed", {line = 1, character = 0}, &common.config)
	if !testing.expect(t, closed_rename_ok) do return
	closed_disk_edits, closed_disk_found := closed_workspace.changes[disk_uri.uri]
	testing.expect(t, closed_disk_found)
	testing.expect(t, len(closed_disk_edits) == 1)
}

@(test)
reference_enum_value_initialize_rhs :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		main :: proc() {
			a := e.Chang{*}e_Me
		}

		e :: enum { Change_Me }
		`,
	}

	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 10}, end = {line = 2, character = 19}}},
			{range = {start = {line = 5, character = 14}, end = {line = 5, character = 23}}},
		},
	)
}

@(test)
reference_enum_type_field :: proc(t: ^testing.T) {
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

		my_proc :: proc() -> u32 {
			arr :: EnumIndexedArray
			return arr[.valueOne]
		}
		`,
	}

	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 3}, end = {line = 2, character = 11}}},
			{range = {start = {line = 7, character = 4}, end = {line = 7, character = 12}}},
			{range = {start = {line = 13, character = 15}, end = {line = 13, character = 23}}},
		},
	)
}

@(test)
reference_variables_in_function :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		my_function :: proc() {
			a := 2
			b := a
			c := 2 + b{*}
		}
		`,
	}

	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 3, character = 3}, end = {line = 3, character = 4}}},
			{range = {start = {line = 4, character = 12}, end = {line = 4, character = 13}}},
		},
	)
}

@(test)
reference_variables_in_function_with_empty_line_at_top_of_file :: proc(t: ^testing.T) {
	source := test.Source {
		main = `
		package test
		my_function :: proc() {
			a := 2
			b := a
			c := 2 + b{*}
		}
		`,
	}

	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 4, character = 3}, end = {line = 4, character = 4}}},
			{range = {start = {line = 5, character = 12}, end = {line = 5, character = 13}}},
		},
	)
}

@(test)
reference_variables_in_function_parameters :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		my_function :: proc(a: int) {
			b := a{*}
		}
		`,
	}

	test.expect_reference_locations(t, &source, {
		{range = {start = {line = 1, character = 22}, end = {line = 1, character = 23}}},
		{range = {start = {line = 2, character = 8}, end = {line = 2, character = 9}}},
	})
}

@(test)
reference_selectors_in_function :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		My_Struct :: struct {
			a: int,
		}

		my_function :: proc() {
			my: My_Struct
			my.a{*} = 2
		}
		`,
	}

	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 3}, end = {line = 2, character = 4}}},
			{range = {start = {line = 7, character = 6}, end = {line = 7, character = 7}}},
		},
	)
}


@(test)
reference_field_comp_lit :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: struct {
			soo_many_cases: int,
		}

		My_Struct :: struct {
			foo: Foo,
		}

		my_function :: proc(my_struct: My_Struct) {
			my := My_Struct {
				foo = {soo_many_cases{*} = 2},
			}
		}
		`,
	}

	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 3}, end = {line = 2, character = 17}}},
			{range = {start = {line = 11, character = 11}, end = {line = 11, character = 25}}},
		},
	)
}

@(test)
reference_field_comp_lit_infer_from_function :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: struct {
			soo_many_cases: int,
		}

		My_Struct :: struct {
			foo: Foo,
		}

		my_function :: proc(my_struct: My_Struct) {
			my_function({foo = {soo_many_cases{*} = 2}})
		}
		`,
	}

	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 3}, end = {line = 2, character = 17}}},
			{range = {start = {line = 10, character = 23}, end = {line = 10, character = 37}}},
		},
	)
}

@(test)
reference_field_comp_lit_infer_from_return :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: struct {
			soo_many_cases: int,
		}

		My_Struct :: struct {
			foo: Foo,
		}

		my_function :: proc() -> My_Struct {
			return {foo = {soo_many_cases{*} = 2}}
		}
		`,
	}

	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 3}, end = {line = 2, character = 17}}},
			{range = {start = {line = 10, character = 18}, end = {line = 10, character = 32}}},
		},
	)
}


@(test)
reference_enum_field_infer_from_assignment :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
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
	}

	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 3}, end = {line = 2, character = 6}}},
			{range = {start = {line = 15, character = 14}, end = {line = 15, character = 17}}},
		},
	)
}


@(test)
reference_struct_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Mouse :: struct {
			x, y: f32,
		}

		mouse: Mouse

		random_procedure :: proc(x, y: f32) {
			mouse.x += x{*}
			mouse.y += y
		}
		`,
	}

	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 8, character = 14}, end = {line = 8, character = 15}}},
			{range = {start = {line = 7, character = 27}, end = {line = 7, character = 28}}},
		},
	)
}

@(test)
ast_reference_variable_declaration_with_selector_expr :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

		Bar :: struct {
			foo: int,
		}

		main :: proc() {
			bar: [2]Bar
			bar[0].foo = 5
			b{*}ar[1].foo = 6
		}
		`,
		packages = {},
	}

	locations := []common.Location {
		{range = {start = {line = 7, character = 3}, end = {line = 7, character = 6}}},
		{range = {start = {line = 8, character = 3}, end = {line = 8, character = 6}}},
		{range = {start = {line = 9, character = 3}, end = {line = 9, character = 6}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_variable_uses_from_declaration :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

		Bar :: struct {
			foo: int,
		}

		main :: proc() {
			b{*}ar: Bar
			bar.foo = 5
			bar.foo = 6
		}
		`,
		packages = {},
	}

	locations := []common.Location {
		{range = {start = {line = 7, character = 3}, end = {line = 7, character = 6}}},
		{range = {start = {line = 8, character = 3}, end = {line = 8, character = 6}}},
		{range = {start = {line = 9, character = 3}, end = {line = 9, character = 6}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_variable_uses_from_declaration_with_selector_expr :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

		Bar :: struct {
			foo: int,
		}

		main :: proc() {
			b{*}ar: [2]Bar
			bar[0].foo = 5
			bar[1].foo = 6
		}
		`,
		packages = {},
	}

	locations := []common.Location {
		{range = {start = {line = 7, character = 3}, end = {line = 7, character = 6}}},
		{range = {start = {line = 8, character = 3}, end = {line = 8, character = 6}}},
		{range = {start = {line = 9, character = 3}, end = {line = 9, character = 6}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_variable_declaration_field_with_selector_expr :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

		Bar :: struct {
			foo: int,
		}

		main :: proc() {
			bar: [2]Bar
			bar[0].foo = 5
			bar[1].f{*}oo = 6
		}
		`,
		packages = {},
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 6}}},
		{range = {start = {line = 8, character = 10}, end = {line = 8, character = 13}}},
		{range = {start = {line = 9, character = 10}, end = {line = 9, character = 13}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_cast_proc_param_with_param_expr :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: struct{
			data: int,
			len: int,
		}

		Bar :: struct{
			data: int,
			len: int,
		}

		foo :: proc(bu{*}f: ^Foo, n: int) {
			(cast(^Bar)&buf.data).len -= n
			buf.r_offset = (buf.r_offset + n) % cap(buf.data)
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 12, character = 14}, end = {line = 12, character = 17}}},
		{range = {start = {line = 13, character = 15}, end = {line = 13, character = 18}}},
		{range = {start = {line = 14, character = 19}, end = {line = 14, character = 22}}},
		{range = {start = {line = 14, character = 43}, end = {line = 14, character = 46}}},
		{range = {start = {line = 14, character = 3}, end = {line = 14, character = 6}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_variable_in_switch_case :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Bar :: enum {
			Bar1,
			Bar2,
		}

		Foo :: struct {
			foo1: int,
		}

		main :: proc() {
			bar: Bar

			#partial switch bar {
			case .Bar1:
				foo := Foo{}
				f{*}oo.foo1 = 2
			}
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 16, character = 4}, end = {line = 16, character = 7}}},
		{range = {start = {line = 17, character = 4}, end = {line = 17, character = 7}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_shouldnt_reference_variable_outside_body :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: struct {
			foo1: int,
		}

		main :: proc() {
			foo: Foo
			{
				fo{*}o := Foo{}
				foo.foo1 = 2
			}
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 9, character = 4}, end = {line = 9, character = 7}}},
		{range = {start = {line = 10, character = 4}, end = {line = 10, character = 7}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_shouldnt_reference_variable_inside_body :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: struct {
			foo1: int,
		}

		main :: proc() {
			fo{*}o: Foo
			{
				foo := Foo{}
				foo.foo1 = 2
			}
		}
		`,
	}

	locations := []common.Location{{range = {start = {line = 7, character = 3}, end = {line = 7, character = 6}}}}

	test.expect_reference_locations(t, &source, locations[:])
}


@(test)
ast_reference_should_reference_variable_inside_body :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: struct {
			foo1: int,
		}

		main :: proc() {
			fo{*}o: Foo
			{
				foo.foo1 = 2
			}
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 7, character = 3}, end = {line = 7, character = 6}}},
		{range = {start = {line = 9, character = 4}, end = {line = 9, character = 7}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_struct_within_proc :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: struct {
			foo1: int,
		}

		main :: proc() {
			InnerFoo :: struct {
				foo: Fo{*}o,
			}
			foo := Foo{}

			ifoo := InnerFoo {foo = foo}
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 2}, end = {line = 2, character = 5}}},
		{range = {start = {line = 8, character = 9}, end = {line = 8, character = 12}}},
		{range = {start = {line = 10, character = 10}, end = {line = 10, character = 13}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_enum_field_list :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			a = 1,
		}

		main :: proc() {
			foo: Foo
			foo = .a{*}
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 4}}},
		{range = {start = {line = 8, character = 10}, end = {line = 8, character = 11}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_enum_field_list_with_constant :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		one :: 1

		Foo :: enum {
			a = on{*}e,
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 2}, end = {line = 2, character = 5}}},
		{range = {start = {line = 5, character = 7}, end = {line = 5, character = 10}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_enum_bitset :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			Aaa,
			Bbb,
		}

		Foos :: bit_set[Foo]

		main :: proc() {
			foos: Foos
			foos += {.A{*}aa}
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 6}}},
		{range = {start = {line = 11, character = 13}, end = {line = 11, character = 16}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_struct_field_from_proc :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

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
		{range = {start = {line = 11, character = 16}, end = {line = 11, character = 19}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_proc_with_immediate_return_field_access :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Bar :: struct {
			bar: int,
		}

		foo :: proc() -> Bar {
			return Bar{}
		}

		main :: proc() {
			bar := f{*}oo().bar
			bar2 := foo().bar
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 6, character = 2}, end = {line = 6, character = 5}}},
		{range = {start = {line = 11, character = 10}, end = {line = 11, character = 13}}},
		{range = {start = {line = 12, character = 11}, end = {line = 12, character = 14}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_enumerated_array :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			A,
			B,
		}

		main :: proc() {
			foos := [Foo][Foo][Foo][Foo]Foo {
				.A = {
					.B = {
						.A = {
							.A{*} = .B
						}
					}
				}
			}
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 4}}},
		{range = {start = {line = 9, character = 5}, end = {line = 9, character = 6}}},
		{range = {start = {line = 11, character = 7}, end = {line = 11, character = 8}}},
		{range = {start = {line = 12, character = 8}, end = {line = 12, character = 9}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_struct_field_ptr :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: struct {
			bar: ^Ba{*}r
		}

		Bar :: struct {}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 9}, end = {line = 3, character = 12}}},
		{range = {start = {line = 6, character = 2}, end = {line = 6, character = 5}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_struct_and_enum_variant_same_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			Bar,
			Bazz
		}

		Bar :: struct {}

		main :: proc() {
			f: Foo
			f = .Bar
			b := B{*}ar{}
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 7, character = 2}, end = {line = 7, character = 5}}},
		{range = {start = {line = 12, character = 8}, end = {line = 12, character = 11}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_enum_variants_comp_lit_return :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			A,
			B,
		}

		Bar :: struct {
			foo: Foo,
		}

		foo :: proc() -> Bar {
			return Bar {
				foo = .A{*},
			}
		}

		`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 4}}},
		{range = {start = {line = 13, character = 11}, end = {line = 13, character = 12}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_enum_variants_comp_lit_return_implicit :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			A,
			B,
		}

		Bar :: struct {
			foo: Foo,
		}

		foo :: proc() -> Bar {
			return {
				foo = .A{*},
			}
		}

		`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 4}}},
		{range = {start = {line = 13, character = 11}, end = {line = 13, character = 12}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_enum_indexed_array_return_value :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			A,
			B,
		}

		foo :: proc() -> [Foo]int {
			return {
				.A{*} = 2,
				.B = 1,
			}
		}

		`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 4}}},
		{range = {start = {line = 9, character = 5}, end = {line = 9, character = 6}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_enum_conflict_switch_statement :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			A{*},
			B,
		}

		Bar :: struct {
			foo: Foo,
		}

		foo :: proc() {
			s := "test"
			switch s {
			case "test2":
			}

			bar := Bar{
				foo = .A
			}
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 4}}},
		{range = {start = {line = 18, character = 11}, end = {line = 18, character = 12}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_enum_nested_with_switch :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			A{*},
			B,
		}

		foo :: proc() -> Foo {
			f := Foo.A
			switch f {
			case .A:
				return .B
			case .B
				return .A
			}
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 4}}},
		{range = {start = {line = 8, character = 12}, end = {line = 8, character = 13}}},
		{range = {start = {line = 10, character = 9}, end = {line = 10, character = 10}}},
		{range = {start = {line = 13, character = 12}, end = {line = 13, character = 13}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_struct_field_enumerated_array :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			A,
			B,
		}

		Bar :: struct {
			foos: [F{*}oo]Bazz
		}

		Bazz :: struct {}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 2}, end = {line = 2, character = 5}}},
		{range = {start = {line = 8, character = 10}, end = {line = 8, character = 13}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_struct_field_map_key :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: int

		Bar :: struct {}

		Bazz :: struct {
			bars: map[Fo{*}o]Bar
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 2}, end = {line = 2, character = 5}}},
		{range = {start = {line = 7, character = 13}, end = {line = 7, character = 16}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_struct_field_map_value :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: int

		Bar :: struct {}

		Bazz :: struct {
			bars: map[Foo]B{*}ar
		}

		`,
	}

	locations := []common.Location {
		{range = {start = {line = 4, character = 2}, end = {line = 4, character = 5}}},
		{range = {start = {line = 7, character = 17}, end = {line = 7, character = 20}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_named_parameter_same_as_variable :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		foo :: proc(a: int) {}

		main :: proc() {
			a := "hellope"
			foo(a{*} = 0)
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 14}, end = {line = 2, character = 15}}},
		{range = {start = {line = 6, character = 7}, end = {line = 6, character = 8}}},
	}
	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_struct_comp_lit_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
			A,
			B,
		}

		Bar :: struct {
			foo: Foo,
		}

		foo :: proc() -> Bar {
			return Bar {
				fo{*}o = .A,
			}
		}

		`,
	}

	locations := []common.Location {
		{range = {start = {line = 8, character = 3}, end = {line = 8, character = 6}}},
		{range = {start = {line = 13, character = 4}, end = {line = 13, character = 7}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_inside_where_clause :: proc(t: ^testing.T) {
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
		{range = {start = {line = 2, character = 13}, end = {line = 2, character = 14}}},
		{range = {start = {line = 3, character = 14}, end = {line = 3, character = 15}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_union_switch_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: union {
			int,
			string
		}

		main :: proc() {
			foo: Foo
			#partial switch v{*} in foo {
			case int:
				bar := v + 1
			case string:
				bar := "test" + v
			}
		}
	`,
	}

	locations := []common.Location {
		{range = {start = {line = 8, character = 19}, end = {line = 8, character = 20}}},
		{range = {start = {line = 10, character = 11}, end = {line = 10, character = 12}}},
		{range = {start = {line = 12, character = 20}, end = {line = 12, character = 21}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_enum_struct_field_without_name :: proc(t: ^testing.T) {
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
		{range = {start = {line = 11, character = 16}, end = {line = 11, character = 17}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_poly_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		foo :: proc(array: $A/[dynamic]^$T) {
			for e{*}lem, i in array {
				elem
			}
		}
	`,
	}
	locations := []common.Location {
		{range = {start = {line = 2, character = 7}, end = {line = 2, character = 11}}},
		{range = {start = {line = 3, character = 4}, end = {line = 3, character = 8}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_soa_field :: proc(t: ^testing.T) {
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
		{range = {start = {line = 7, character = 13}, end = {line = 7, character = 14}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_soa_pointer_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: struct {
			x, y: int,
		}

		main :: proc() {
			foos: #soa^#soa[]Foo
			x := foos.x{*}
		}
	`,
	}
	locations := []common.Location {
		{range = {start = {line = 2, character = 3}, end = {line = 2, character = 4}}},
		{range = {start = {line = 7, character = 13}, end = {line = 7, character = 14}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_nested_switch_cases :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: enum {
			A,
			B{*},
		}

		Bar :: enum {
			C,
			D,
		}

		main :: proc() {
			foo: Foo
			bar: Bar

			switch foo {
			case .A:
				#partial switch bar {
				case .D:
				}
			case .B:
			}
		}
	`,
	}
	locations := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 4}}},
		{range = {start = {line = 20, character = 9}, end = {line = 20, character = 10}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_switch_cases_binary_expr :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: enum {
			A,
			B{*},
		}

		Bar :: enum {
			C,
			D,
		}

		main :: proc() {
			foo: Foo
			bar: Bar

			switch foo {
			case .A:
				if bar == .C {}
			case .B:
			}
		}
	`,
	}
	locations := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 4}}},
		{range = {start = {line = 18, character = 9}, end = {line = 18, character = 10}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_struct_field_matrix_row :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: int

		Bar :: struct {}

		Bazz :: struct {
			bars: matrix[Fo{*}o, 2]Bar
		}

		`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 2}, end = {line = 2, character = 5}}},
		{range = {start = {line = 7, character = 16}, end = {line = 7, character = 19}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_reference_struct_field_bitfield_backing_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: int

		Bar :: struct {}

		Bazz :: struct {
			bars: bit_field Fo{*}o {
			}
		}

		`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 2}, end = {line = 2, character = 5}}},
		{range = {start = {line = 7, character = 19}, end = {line = 7, character = 22}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_comp_lit_map_key :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test
		Foo :: struct {
			a{*}: int,
		}

		Bar :: struct {
			b: int,
		}

		main :: proc() {
			m: map[Foo]Bar
			m[{a = 1}] = {b = 2}
		}
		`,
	}
	locations := []common.Location {
		{range = {start = {line = 2, character = 3}, end = {line = 2, character = 4}}},
		{range = {start = {line = 11, character = 6}, end = {line = 11, character = 7}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_comp_lit_map_value :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test
		Foo :: struct {
			a: int,
		}

		Bar :: struct {
			b{*}: int,
		}

		main :: proc() {
			m: map[Foo]Bar
			m[{a = 1}] = {b = 2}
		}
		`,
	}
	locations := []common.Location {
		{range = {start = {line = 6, character = 3}, end = {line = 6, character = 4}}},
		{range = {start = {line = 11, character = 17}, end = {line = 11, character = 18}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_nested_using_struct_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: struct {
			a: int,
			using _: struct {
				b: u8,
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
		{range = {start = {line = 10, character = 12}, end = {line = 10, character = 13}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_nested_using_bit_field_field :: proc(t: ^testing.T) {
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
		{range = {start = {line = 10, character = 12}, end = {line = 10, character = 13}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_nested_using_bit_field_field_from_declaration :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: struct {
			a: int,
			using _: bit_field u8 {
				b{*}: u8 | 4
			}
		}

		main :: proc() {
			foo: Foo
			b := foo.b
		}
	`,
	}
	locations := []common.Location {
		{range = {start = {line = 4, character = 4}, end = {line = 4, character = 5}}},
		{range = {start = {line = 10, character = 12}, end = {line = 10, character = 13}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_union_member_pointer :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: struct{}

		Foos :: union {
			Foo,
			^F{*}oo,
		}
	`,
	}
	locations := []common.Location {
		{range = {start = {line = 1, character = 2}, end = {line = 1, character = 5}}},
		{range = {start = {line = 4, character = 3}, end = {line = 4, character = 6}}},
		{range = {start = {line = 5, character = 4}, end = {line = 5, character = 7}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_enum_with_enumerated_array :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		Foo :: enum {
		  A, B,
		}

		Bar :: enum {
		  C, D,
		}

		Bazz :: struct {
		  foobars: [Bar]Foo
		}

		main :: proc() {
		  bazz: Bazz
		  bar: Bar

		  foo: Foo
		  foo = .A{*}

		  switch bazz.foobars[bar] {
		  case .A:
		  case .B:
		  }
		}
	`,
	}
	locations := []common.Location {
		{range = {start = {line = 3, character = 4}, end = {line = 3, character = 5}}},
		{range = {start = {line = 19, character = 11}, end = {line = 19, character = 12}}},
		{range = {start = {line = 22, character = 10}, end = {line = 22, character = 11}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_deferred_attributes :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		foo :: proc() {}

		@(deferred_in = fo{*}o)
		bar :: proc() {}
		`,
	}
	locations := []common.Location {
		{range = {start = {line = 1, character = 2}, end = {line = 1, character = 5}}},
		{range = {start = {line = 3, character = 18}, end = {line = 3, character = 21}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}

@(test)
ast_references_should_include_declaration :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: struct{}

		main :: proc() {
			foo: Fo{*}o
		}
		`,
	}
	locations := []common.Location {
		{range = {start = {line = 1, character = 2}, end = {line = 1, character = 5}}},
		{range = {start = {line = 4, character = 8}, end = {line = 4, character = 11}}},
	}

	test.expect_reference_locations(t, &source, locations[:], include_declaration = true)
}

@(test)
ast_references_should_skip_declaration :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: struct{}

		main :: proc() {
			foo: Fo{*}o
		}
		`,
	}
	locations := []common.Location {
		{range = {start = {line = 4, character = 8}, end = {line = 4, character = 11}}},
	}

	test.expect_reference_locations(t, &source, locations, include_declaration = false)
}

@(test)
ast_references_struct_poly_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: enum {
			A,
			B,
		}

		Bar :: struct($F: Foo = .A) {}

		main :: proc() {
			bar: Bar(.A{*})
		}
		`,
	}
	locations := []common.Location {
		{range = {start = {line = 2, character = 3}, end = {line = 2, character = 4}}},
		{range = {start = {line = 6, character = 27}, end = {line = 6, character = 28}}},
		{range = {start = {line = 9, character = 13}, end = {line = 9, character = 14}}},
	}

	test.expect_reference_locations(t, &source, locations)
}

@(test)
ast_reference_iterator_index_union_switch_case :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: union {
		    int,
			[]string,
		}

		main :: proc() {
			foo: Foo
			#partial switch v in foo {
			case []string:
				for s, i{*} in v {
					if i == 0 {
					}
				}
			}
		}

		`,
	}
	locations := []common.Location {
		{range = {start = {line = 10, character = 11}, end = {line = 10, character = 12}}},
		{range = {start = {line = 11, character = 8}, end = {line = 11, character = 9}}},
	}

	test.expect_reference_locations(t, &source, locations)
}

@(test)
ast_reference_enum_field_value_reference  :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: enum {
			Bar,
			Baz = B{*}ar,
		}
		`,
	}
	locations := []common.Location {
		{range = {start = {line = 2, character = 3}, end = {line = 2, character = 6}}},
		{range = {start = {line = 3, character = 9}, end = {line = 3, character = 12}}},
	}

	test.expect_reference_locations(t, &source, locations)
}

@(test)
ast_references_chained_generic_alias :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test
		Foo :: struct($T:typeid){foo: T}
		Bar :: Foo(f32)
		Baz :: Bar
		Qux :: Baz

		main :: proc() {
			q: Qu{*}x
		}
		`,
	}
	locations := []common.Location {
		{range = {start = {line = 4, character = 2}, end = {line = 4, character = 5}}},
		{range = {start = {line = 7, character = 6}, end = {line = 7, character = 9}}},
	}

	test.expect_reference_locations(t, &source, locations[:], include_declaration = true)
}

@(test)
ast_references_shadowed_variable_unresolved_call :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		main :: proc() {
			foo: int

			{
				fo{*}o := bar()
			}
		}
		`,
	}

	locations := []common.Location {
		{range = {start = {line = 6, character = 4}, end = {line = 6, character = 7}}},
	}

	test.expect_reference_locations(t, &source, locations[:])
}
