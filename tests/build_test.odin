package tests

import "base:runtime"

import "core:encoding/json"
import "core:os"
import "core:mem/virtual"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "src:common"
import "src:server"

@(test)
document_index_tracks_open_change_and_close :: proc(t: ^testing.T) {
	previous_allocator := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = previous_allocator

	root, err := os.make_directory_temp("", "ols-document-index-*", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)
	file_path, _ := filepath.join({root, "main.odin"})
	disk_text := "package lifecycle\nDisk_Value :: 1\n"
	if !testing.expect(t, os.write_entire_file(file_path, transmute([]u8)disk_text) == nil) do return

	old_documents := server.document_storage.documents
	old_free_allocators := server.document_storage.free_allocators
	server.document_storage.documents = make(map[string]server.Document)
	server.document_storage.free_allocators = nil
	defer {
		server.document_storage_shutdown()
		server.document_storage.documents = old_documents
		server.document_storage.free_allocators = old_free_allocators
	}

	server.setup_index(server.get_builtin_path())
	defer server.free_index()
	uri := common.create_uri(file_path, context.temp_allocator)
	_ = server.index_file(uri, disk_text)
	_, found := server.lookup("Disk_Value", root, file_path)
	testing.expect(t, found)

	open_text := strings.clone("package lifecycle\nOpen_Value :: 1\n")
	if !testing.expect(t, server.document_open(uri.uri, open_text, &common.config, nil) == .None) do return
	_, found = server.lookup("Disk_Value", root, file_path)
	testing.expect(t, !found)
	_, found = server.lookup("Open_Value", root, file_path)
	testing.expect(t, found)
	watcher_text := "package lifecycle\nWatcher_Value :: 1\n"
	if !testing.expect(t, os.write_entire_file(file_path, transmute([]u8)watcher_text) == nil) do return
	watcher_params_text := strings.join(
		{`{"changes":[{"uri":"`, uri.uri, `","type":2}]}`},
		"",
		context.temp_allocator,
	)
	watcher_params, watcher_parse_error := json.parse_string(watcher_params_text, parse_integers = true)
	if !testing.expect(t, watcher_parse_error == .None) do return
	if !testing.expect(
		t,
		server.notification_did_change_watched_files(
			watcher_params,
			i64(0),
			&common.config,
			nil,
		) == .None,
	) {
		return
	}
	_, found = server.lookup("Open_Value", root, file_path)
	testing.expect(t, found)
	_, found = server.lookup("Watcher_Value", root, file_path)
	testing.expect(t, !found)
	delete_params_text := strings.join(
		{`{"changes":[{"uri":"`, uri.uri, `","type":3}]}`},
		"",
		context.temp_allocator,
	)
	delete_params, delete_parse_error := json.parse_string(delete_params_text, parse_integers = true)
	if !testing.expect(t, delete_parse_error == .None) do return
	if !testing.expect(
		t,
		server.notification_did_change_watched_files(delete_params, i64(0), &common.config, nil) == .None,
	) {
		return
	}
	_, found = server.lookup("Open_Value", root, file_path)
	testing.expect(t, found)
	save_params_text := strings.join(
		{`{"textDocument":{"uri":"`, uri.uri, `"}}`},
		"",
		context.temp_allocator,
	)
	save_params, parse_error := json.parse_string(save_params_text, parse_integers = true)
	if !testing.expect(t, parse_error == .None) do return
	if !testing.expect(
		t,
		server.notification_did_save(save_params, i64(0), &common.config, nil) == .None,
	) {
		return
	}
	_, found = server.lookup("Open_Value", root, file_path)
	testing.expect(t, found)

	changed_text := strings.clone("package lifecycle\nChanged_Value :: 1\n")
	changes := make([dynamic]server.TextDocumentContentChangeEvent, context.temp_allocator)
	append(&changes, server.TextDocumentContentChangeEvent{text = changed_text})
	if !testing.expect(
		t,
		server.document_apply_changes(uri.uri, changes, nil, &common.config, nil) == .None,
	) {
		return
	}
	_, found = server.lookup("Open_Value", root, file_path)
	testing.expect(t, !found)
	_, found = server.lookup("Changed_Value", root, file_path)
	testing.expect(t, found)

	if !testing.expect(t, server.document_close(uri.uri) == .None) do return
	_, found = server.lookup("Changed_Value", root, file_path)
	testing.expect(t, !found)
	_, found = server.lookup("Watcher_Value", root, file_path)
	testing.expect(t, found)
}

@(test)
ignore_file_tag_only_in_header :: proc(t: ^testing.T) {
	testing.expect(t, common.has_ignore_file_tag("#+ignore\npackage test\ninvalid code"))
	testing.expect(t, common.has_ignore_file_tag("// comment\n#+ignore // comment\npackage test"))
	testing.expect(t, common.has_ignore_file_tag("#+ignore,other\npackage test"))
	testing.expect(t, !common.has_ignore_file_tag("#+ignored\npackage test"))
	testing.expect(t, !common.has_ignore_file_tag("// #+ignore\npackage test"))
	testing.expect(t, !common.has_ignore_file_tag("package test\n#+ignore"))
}

@(test)
ignored_document_skips_parser :: proc(t: ^testing.T) {
	source := "#+ignore\npackage test\ninvalid code"
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) {
		return
	}
	defer virtual.arena_destroy(&arena)
	allocator := context.allocator
	defer context.allocator = allocator

	document := server.Document {
		fullpath  = "test/ignored.odin",
		text      = transmute([]u8)source,
		used_text = len(source),
		allocator = &arena,
	}
	config: common.Config
	errors, ok := server.parse_document(&document, &config)
	testing.expect(t, ok)
	testing.expect_value(t, len(errors), 0)
	testing.expect_value(t, len(document.ast.decls), 0)
}

@(test)
ignored_file_removes_indexed_symbols :: proc(t: ^testing.T) {
	server.setup_index(server.get_builtin_path())
	defer server.free_index()

	fullpath := "test/ignored.odin"
	uri := common.create_uri(fullpath, context.temp_allocator)
	server.index_file(uri, "package test\nVisible :: 1")
	_, found := server.lookup("Visible", "test", fullpath)
	testing.expect(t, found)

	server.index_file(uri, "#+ignore\npackage test\ninvalid code")
	_, found = server.lookup("Visible", "test", fullpath)
	testing.expect(t, !found)
}

@(test)
when_file_tag_filters_indexed_symbols :: proc(t: ^testing.T) {
	server.setup_index(server.get_builtin_path())
	defer server.free_index()

	previous_defines := common.config.profile.defines
	common.config.profile.defines = make(map[string]string, context.temp_allocator)
	defer common.config.profile.defines = previous_defines
	common.config.profile.defines["FEATURE"] = "true"
	common.config.profile.defines["LEVEL"] = "3"

	fullpath := "test/when_tag.odin"
	uri := common.create_uri(fullpath, context.temp_allocator)
	server.index_file(uri, "#+when FEATURE && (LEVEL >= 2)\npackage test\nEnabled :: 1")
	_, found := server.lookup("Enabled", "test", fullpath)
	testing.expect(t, found)

	server.index_file(uri, "#+when FEATURE\n#+when LEVEL < 2\npackage test\nDisabled :: 1")
	_, found = server.lookup("Enabled", "test", fullpath)
	testing.expect(t, !found)
	_, found = server.lookup("Disabled", "test", fullpath)
	testing.expect(t, !found)

	server.index_file(uri, "#+when !FEATURE || LEVEL == 3\npackage test\nRestored :: 1")
	_, found = server.lookup("Restored", "test", fullpath)
	testing.expect(t, found)

	server.index_file(uri, "#+when LOCAL\npackage test\nLOCAL :: true\nLocal :: 1")
	_, found = server.lookup("Local", "test", fullpath)
	testing.expect(t, found)

	server.index_file(uri, "#+when UNRESOLVED\npackage test\nMissing :: 1")
	_, found = server.lookup("Missing", "test", fullpath)
	testing.expect(t, !found)
}

@(test)
when_file_tag_resolves_sibling_config_constant :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "ols-when-*", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)
	root, err = os.get_absolute_path(root, context.temp_allocator)
	if !testing.expect(t, err == nil) do return

	config_path, _ := filepath.join({root, "z_config.odin"}, context.temp_allocator)
	if !testing.expect(t, os.write_entire_file(config_path, "package when_tag_test\nENABLED :: #config(ENABLED, true)\nDISABLED :: #config(DISABLED, false)\nLATER :: true") == nil) do return
	chain_path, _ := filepath.join({root, "b_chain.odin"}, context.temp_allocator)
	if !testing.expect(t, os.write_entire_file(chain_path, "package when_tag_test\nCHAIN :: LATER") == nil) do return

	server.setup_index(server.get_builtin_path())
	defer server.free_index()

	active_path, _ := filepath.join({root, "a_active.odin"}, context.temp_allocator)
	inactive_path, _ := filepath.join({root, "b_inactive.odin"}, context.temp_allocator)
	chained_path, _ := filepath.join({root, "c_chained.odin"}, context.temp_allocator)
	server.index_file(common.create_uri(active_path, context.temp_allocator), "#+when ENABLED\npackage when_tag_test\nActive :: 1")
	server.index_file(common.create_uri(inactive_path, context.temp_allocator), "#+when DISABLED\npackage when_tag_test\nInactive :: 1")
	server.index_file(common.create_uri(chained_path, context.temp_allocator), "#+when CHAIN\npackage when_tag_test\nChained :: 1")
	_, found := server.lookup("Active", root, active_path)
	testing.expect(t, found)
	_, found = server.lookup("Inactive", root, inactive_path)
	testing.expect(t, !found)
	_, found = server.lookup("Chained", root, chained_path)
	testing.expect(t, found)

	source := "#+when DISABLED\npackage when_tag_test\ninvalid code"
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)
	document := server.Document {
		fullpath  = inactive_path,
		text      = transmute([]u8)source,
		used_text = len(source),
		allocator = &arena,
	}
	config: common.Config
	errors, ok := server.parse_document(&document, &config)
	testing.expect(t, ok)
	testing.expect_value(t, len(errors), 0)
}

@(test)
when_file_tag_skips_excluded_body :: proc(t: ^testing.T) {
	source := "#+when false\npackage test\ninvalid code"
	arena: virtual.Arena
	if !testing.expect(t, virtual.arena_init_growing(&arena) == nil) do return
	defer virtual.arena_destroy(&arena)

	document := server.Document {
		fullpath  = "test/excluded.odin",
		text      = transmute([]u8)source,
		used_text = len(source),
		allocator = &arena,
	}
	config: common.Config
	errors, ok := server.parse_document(&document, &config)
	testing.expect(t, ok)
	testing.expect_value(t, len(errors), 0)
	testing.expect_value(t, len(document.ast.decls), 0)
}

@(test)
append_packages_skip_directories :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "ols-packages-*", context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to create temporary directory: %v", err) {
		return
	}
	defer os.remove_all(root)
	root, err = os.get_absolute_path(root, context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to resolve temporary directory: %v", err) {
		return
	}

	included, _ := filepath.join({root, "included"}, context.temp_allocator)
	excluded, _ := filepath.join({root, "excluded"}, context.temp_allocator)
	hidden, _ := filepath.join({root, ".hidden"}, context.temp_allocator)
	ignored, _ := filepath.join({root, "ignored"}, context.temp_allocator)
	when_excluded, _ := filepath.join({root, "when_excluded"}, context.temp_allocator)
	if !testing.expect(t, os.make_directory(included) == nil) ||
	   !testing.expect(t, os.make_directory(excluded) == nil) ||
	   !testing.expect(t, os.make_directory(hidden) == nil) ||
	   !testing.expect(t, os.make_directory(ignored) == nil) ||
	   !testing.expect(t, os.make_directory(when_excluded) == nil) {
		return
	}

	included_file, _ := filepath.join({included, "included.odin"}, context.temp_allocator)
	excluded_file, _ := filepath.join({excluded, "excluded.odin"}, context.temp_allocator)
	hidden_file, _ := filepath.join({hidden, "hidden.odin"}, context.temp_allocator)
	ignored_file, _ := filepath.join({ignored, "ignored.odin"}, context.temp_allocator)
	when_excluded_file, _ := filepath.join({when_excluded, "excluded.odin"}, context.temp_allocator)
	if !testing.expect(t, os.write_entire_file(included_file, "package included") == nil) ||
	   !testing.expect(t, os.write_entire_file(excluded_file, "package excluded") == nil) ||
	   !testing.expect(t, os.write_entire_file(hidden_file, "package hidden") == nil) ||
	   !testing.expect(t, os.write_entire_file(ignored_file, "#+ignore\npackage ignored\ninvalid code") == nil) ||
	   !testing.expect(t, os.write_entire_file(when_excluded_file, "#+when false\npackage when_excluded\ninvalid code") == nil) {
		return
	}

	skip := make(map[string]struct{}, context.temp_allocator)
	skip[excluded] = {}

	packages := make([dynamic]string, context.temp_allocator)
	server.append_packages(root, &packages, skip, context.temp_allocator, skip_hidden = true)

	testing.expect_value(t, len(packages), 1)
	if len(packages) == 1 {
		testing.expect_value(t, packages[0], included)
	}

	clear(&packages)
	server.append_packages(root, &packages, skip, context.temp_allocator, skip_hidden = false)
	testing.expect_value(t, len(packages), 2)

	skip[root] = {}
	clear(&packages)
	server.append_packages(root, &packages, skip, context.temp_allocator, skip_hidden = false)
	testing.expect_value(t, len(packages), 0)
}

@(test)
refresh_package_aliases_when_hidden_path_setting_changes :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "ols-aliases-*", context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to create temporary directory: %v", err) {
		return
	}
	defer os.remove_all(root)
	root, err = os.get_absolute_path(root, context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to resolve temporary directory: %v", err) {
		return
	}

	included, _ := filepath.join({root, "included"}, context.temp_allocator)
	hidden, _ := filepath.join({root, ".hidden"}, context.temp_allocator)
	if !testing.expect(t, os.make_directory(included) == nil) ||
	   !testing.expect(t, os.make_directory(hidden) == nil) {
		return
	}

	included_file, _ := filepath.join({included, "included.odin"}, context.temp_allocator)
	hidden_file, _ := filepath.join({hidden, "hidden.odin"}, context.temp_allocator)
	if !testing.expect(t, os.write_entire_file(included_file, "package included") == nil) ||
	   !testing.expect(t, os.write_entire_file(hidden_file, "package hidden") == nil) {
		return
	}

	config: common.Config
	config.collections = make(map[string]string, context.temp_allocator)
	config.collections["test"] = root
	config.enable_auto_import_skip_hidden_paths = false

	previous_aliases := server.build_cache.pkg_aliases
	server.build_cache.pkg_aliases = make(map[string][dynamic]string, context.temp_allocator)
	defer {
		server.clear_all_package_aliases()
		delete(server.build_cache.pkg_aliases)
		server.build_cache.pkg_aliases = previous_aliases
	}

	server.find_all_package_aliases(&config)
	aliases := server.build_cache.pkg_aliases["test"]
	testing.expect_value(t, len(aliases), 2)

	previous_value := config.enable_auto_import_skip_hidden_paths
	config.enable_auto_import_skip_hidden_paths = true
	testing.expect(
		t,
		server.refresh_package_aliases_if_hidden_paths_changed(previous_value, &config),
	)

	aliases = server.build_cache.pkg_aliases["test"]
	testing.expect_value(t, len(aliases), 1)
	if len(aliases) == 1 {
		testing.expect_value(t, aliases[0], "included")
	}

	testing.expect(
		t,
		!server.refresh_package_aliases_if_hidden_paths_changed(config.enable_auto_import_skip_hidden_paths, &config),
	)
}
