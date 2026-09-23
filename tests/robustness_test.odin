package tests

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:testing"

import "src:common"
import "src:server"

@(test)
relative_collection_path_does_not_crash_initialize :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "ols-relative-collection-*", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)
	want, _ := filepath.join({root, "rt"}, context.temp_allocator)
	if !testing.expect(t, os.make_directory(want) == nil) do return

	config := common.Config {
		collections = make(map[string]string),
	}
	defer delete(config.collections)
	options := server.OlsConfig {odin_root_override = root}
	append(&options.collections, server.OlsConfigCollection{name = "rt", path = "./rt"})
	uri := common.create_uri(root, context.temp_allocator)

	server.read_ols_initialize_options(&config, options, uri)
	abs_want, abs_err := filepath.abs(want, context.temp_allocator)
	if !testing.expect(t, abs_err == nil) do return
	testing.expect_value(t, config.collections["rt"], abs_want)
}

@(test)
change_missing_document_returns_invalid_request :: proc(t: ^testing.T) {
	uri := common.create_uri("/tmp/ols-missing-document.odin", context.temp_allocator)
	changes := make([dynamic]server.TextDocumentContentChangeEvent, context.temp_allocator)
	append(&changes, server.TextDocumentContentChangeEvent {text = "package test\n"})
	config: common.Config
	testing.expect_value(t, server.document_apply_changes(uri.uri, changes, 1, &config, nil), common.Error.InvalidRequest)
}

@(test)
workspace_config_change_without_folder :: proc(t: ^testing.T) {
	params_json := "{\"settings\":{\"enable_hover\":false}}"
	params, err := json.parse(data = transmute([]u8)params_json, allocator = context.temp_allocator, parse_integers = true)
	if !testing.expect(t, err == .None) do return
	defer json.destroy_value(params)

	config := common.Config {enable_hover = true}
	testing.expect_value(t, server.notification_workspace_did_change_configuration(params, 0, &config, nil), common.Error.None)
	testing.expect(t, !config.enable_hover)
}

@(test)
package_index_skips_parser_recovery_file :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "ols-index-recovery-*", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	defer os.remove_all(root)
	good_file, _ := filepath.join({root, "good.odin"}, context.temp_allocator)
	bad_file, _ := filepath.join({root, "bad.odin"}, context.temp_allocator)
	good_written := testing.expect(t, os.write_entire_file(good_file, "package recovery\nGood :: 1\n") == nil)
	bad_written := testing.expect(t, os.write_entire_file(bad_file, "package recovery\nimport \"core:fmt\"\nBad ::\n") == nil)
	if !good_written || !bad_written {
		return
	}

	server.setup_index(server.get_builtin_path())
	defer server.free_index()
	server.try_build_package(root)
	_, good := server.lookup("Good", root, good_file)
	_, bad := server.lookup("Bad", root, bad_file)
	testing.expect(t, good)
	testing.expect(t, !bad)
}
