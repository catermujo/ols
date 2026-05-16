package tests

import path "core:path/slashpath"
import "core:testing"

import "src:common"
import "src:server"

test_root_path :: proc() -> string {
	when ODIN_OS == .Windows {
		return "C:/repo"
	} else {
		return "/repo"
	}
}

@(test)
checker_profile_routes_select_longest_match :: proc(t: ^testing.T) {
	root := test_root_path()

	config := common.Config{}
	config.checker_profiles = make([dynamic]common.ConfigProfile)

	default_profile := common.ConfigProfile{name = "default"}
	default_profile.checker_path = make([dynamic]string)
	config.profile = default_profile

	lib_profile := common.ConfigProfile{name = "lib"}
	lib_profile.checker_path = make([dynamic]string)
	lib_profile.checker_match_paths = make([dynamic]string)
	append(&lib_profile.checker_path, path.join({root, "entry", "lib.odin"}))
	append(&lib_profile.checker_match_paths, path.join({root, "rt"}))
	append(&config.checker_profiles, lib_profile)

	game_profile := common.ConfigProfile{name = "game"}
	game_profile.checker_path = make([dynamic]string)
	game_profile.checker_match_paths = make([dynamic]string)
	append(&game_profile.checker_path, path.join({root, "entry", "cold.odin"}))
	append(&game_profile.checker_match_paths, path.join({root, "conurbation"}))
	append(&game_profile.checker_match_paths, path.join({root, "conurbation", "game"}))
	append(&config.checker_profiles, game_profile)

	saved_file := path.join({root, "conurbation", "game", "init.odin"})
	targets := server.resolve_check_targets(.Saved, {saved_file}, &config)

	testing.expect_value(t, 1, len(targets))
	testing.expect_value(t, targets[0].path, path.join({root, "entry", "cold.odin"}))
	testing.expect_value(t, targets[0].profile_index, 1)
}

@(test)
checker_profile_routes_fallback_to_default_profile :: proc(t: ^testing.T) {
	root := test_root_path()

	config := common.Config{}
	config.checker_profiles = make([dynamic]common.ConfigProfile)
	config.profile = common.ConfigProfile{name = "default"}
	config.profile.checker_path = make([dynamic]string)
	append(&config.profile.checker_path, path.join({root, "examples", "single.odin"}))

	saved_file := path.join({root, "misc", "test.odin"})
	targets := server.resolve_check_targets(.Saved, {saved_file}, &config)

	testing.expect_value(t, 1, len(targets))
	testing.expect_value(t, targets[0].path, path.join({root, "examples", "single.odin"}))
	testing.expect_value(t, targets[0].profile_index, -1)
}

@(test)
checker_profile_routes_can_check_directory_without_checker_path :: proc(t: ^testing.T) {
	root := test_root_path()

	config := common.Config{}
	config.checker_profiles = make([dynamic]common.ConfigProfile)
	config.profile = common.ConfigProfile{name = "default"}
	config.profile.checker_path = make([dynamic]string)

	rt_profile := common.ConfigProfile{name = "rt"}
	rt_profile.checker_path = make([dynamic]string)
	rt_profile.checker_match_paths = make([dynamic]string)
	append(&rt_profile.checker_match_paths, path.join({root, "rt", "drift"}))
	append(&config.checker_profiles, rt_profile)

	saved_file := path.join({root, "rt", "drift", "math", "noise.odin"})
	targets := server.resolve_check_targets(.Saved, {saved_file}, &config)

	testing.expect_value(t, 1, len(targets))
	testing.expect_value(t, targets[0].path, path.join({root, "rt", "drift", "math"}))
	testing.expect_value(t, targets[0].profile_index, 0)
}
