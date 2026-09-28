package tests

import "core:encoding/json"
import path "core:path/slashpath"
import "core:testing"

import "src:common"
import "src:server"

checker_test_root :: proc() -> string {
	when ODIN_OS == .Windows do return "C:/repo"
	return "/repo"
}

@(test)
checker_routes_select_longest_path_prefix :: proc(t: ^testing.T) {
	root := checker_test_root()
	config := common.Config{}
	config.checker_profiles = make([dynamic]common.ConfigProfile)

	general := common.ConfigProfile{name = "general"}
	general.checker_match_paths = make([dynamic]string)
	append(&general.checker_match_paths, path.join({root, "game"}))
	general.checker_path = make([dynamic]string)
	append(&general.checker_path, path.join({root, "entry", "general.odin"}))
	append(&config.checker_profiles, general)

	specific := common.ConfigProfile{name = "specific"}
	specific.checker_match_paths = make([dynamic]string)
	append(&specific.checker_match_paths, path.join({root, "game", "ui", "**"}))
	specific.checker_path = make([dynamic]string)
	append(&specific.checker_path, path.join({root, "entry", "ui.odin"}))
	append(&config.checker_profiles, specific)

	saved := path.join({root, "game", "ui", "main.odin"})
	targets := server.resolve_check_targets(.Saved, {saved, saved}, &config)
	if !testing.expect(t, len(targets) == 1) do return
	testing.expect_value(t, targets[0].profile_index, 1)
	testing.expect_value(t, targets[0].path, path.join({root, "entry", "ui.odin"}))

	boundary := path.join({root, "gameplay", "main.odin"})
	targets = server.resolve_check_targets(.Saved, {boundary}, &config)
	if !testing.expect(t, len(targets) == 1) do return
	testing.expect_value(t, targets[0].profile_index, -1)
	testing.expect_value(t, targets[0].path, path.join({root, "gameplay"}))
}

@(test)
checker_routes_keep_per_profile_defines :: proc(t: ^testing.T) {
	root := checker_test_root()
	config := common.Config{}
	config.profile = common.ConfigProfile{name = "default", defines = make(map[string]string)}
	config.profile.defines["MODE"] = "default"
	config.checker_profiles = make([dynamic]common.ConfigProfile)

	matched := common.ConfigProfile{name = "matched", defines = make(map[string]string)}
	matched.defines["MODE"] = "matched"
	matched.checker_match_paths = make([dynamic]string)
	append(&matched.checker_match_paths, path.join({root, "rt"}))
	append(&config.checker_profiles, matched)

	saved := path.join({root, "rt", "math", "main.odin"})
	targets := server.resolve_check_targets(.Saved, {saved}, &config)
	if !testing.expect(t, len(targets) == 1) do return
	testing.expect_value(t, targets[0].path, path.join({root, "rt", "math"}))
	profile := server.checker_profile_for_target(&config, targets[0].profile_index)
	testing.expect_value(t, profile.defines["MODE"], "matched")

	other := path.join({root, "misc", "main.odin"})
	targets = server.resolve_check_targets(.Saved, {other}, &config)
	if !testing.expect(t, len(targets) == 1) do return
	profile = server.checker_profile_for_target(&config, targets[0].profile_index)
	testing.expect_value(t, profile.defines["MODE"], "default")
}

@(test)
checker_routes_resolve_relative_configuration_paths :: proc(t: ^testing.T) {
	root := checker_test_root()
	config := common.Config{}
	options: server.OlsConfig
	data := `{"profile":"ui","profiles":[{"name":"ui","checker_match_paths":["game/ui"],"checker_path":["entry/ui.odin"],"defines":{"MODE":"ui"}}]}`
	if !testing.expect(t, json.unmarshal(transmute([]u8)data, &options, allocator = context.temp_allocator) == nil) do return
	uri := common.create_uri(root, context.temp_allocator)
	server.read_ols_initialize_options(&config, options, uri)

	testing.expect_value(t, config.checker_profiles[0].checker_match_paths[0], path.join({root, "game", "ui"}))
	testing.expect_value(t, config.checker_profiles[0].defines["MODE"], "ui")
	saved := path.join({root, "game", "ui", "main.odin"})
	targets := server.resolve_check_targets(.Saved, {saved}, &config)
	if !testing.expect(t, len(targets) == 1) do return
	testing.expect_value(t, targets[0].path, path.join({root, "entry", "ui.odin"}))
}

@(test)
checker_routes_preserve_explicit_workspace_check_path :: proc(t: ^testing.T) {
	root := checker_test_root()
	config := common.Config{enable_checker_only_saved = true}
	config.profile.checker_path = make([dynamic]string)
	append(&config.profile.checker_path, path.join({root, "entry", "main.odin"}))

	targets := server.resolve_check_targets(.Workspace, {}, &config)
	if !testing.expect(t, len(targets) == 1) do return
	testing.expect_value(t, targets[0].path, path.join({root, "entry", "main.odin"}))
	testing.expect_value(t, targets[0].profile_index, -1)
}
