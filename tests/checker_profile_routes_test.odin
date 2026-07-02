package tests

import path "core:path/slashpath"
import "core:os"
import "core:testing"

import "src:common"
import "src:server"

checker_profile_test_root_path :: proc() -> string {
	when ODIN_OS == .Windows {
		return "C:/repo"
	} else {
		return "/repo"
	}
}

@(test)
checker_profile_routes_select_longest_match :: proc(t: ^testing.T) {
	root := checker_profile_test_root_path()

	config := common.Config{}
	config.checker_profiles = make([dynamic]common.ConfigProfile, context.temp_allocator)

	default_profile := common.ConfigProfile{name = "default"}
	default_profile.checker_path = make([dynamic]string, context.temp_allocator)
	config.profile = default_profile

	lib_profile := common.ConfigProfile{name = "lib"}
	lib_profile.checker_path = make([dynamic]string, context.temp_allocator)
	lib_profile.checker_match_paths = make([dynamic]string, context.temp_allocator)
	append(&lib_profile.checker_path, path.join({root, "entry", "lib.odin"}, context.temp_allocator))
	append(&lib_profile.checker_match_paths, path.join({root, "rt"}, context.temp_allocator))
	append(&config.checker_profiles, lib_profile)

	game_profile := common.ConfigProfile{name = "game"}
	game_profile.checker_path = make([dynamic]string, context.temp_allocator)
	game_profile.checker_match_paths = make([dynamic]string, context.temp_allocator)
	append(&game_profile.checker_path, path.join({root, "entry", "cold.odin"}, context.temp_allocator))
	append(&game_profile.checker_match_paths, path.join({root, "conurbation"}, context.temp_allocator))
	append(&game_profile.checker_match_paths, path.join({root, "conurbation", "game"}, context.temp_allocator))
	append(&config.checker_profiles, game_profile)

	saved_file := path.join({root, "conurbation", "game", "init.odin"}, context.temp_allocator)
	targets := server.resolve_check_targets(.Saved, {saved_file}, &config)

	testing.expect_value(t, 1, len(targets))
	testing.expect_value(t, targets[0].path, path.join({root, "entry", "cold.odin"}, context.temp_allocator))
	testing.expect_value(t, targets[0].profile_index, 1)
}

@(test)
checker_profile_routes_fallback_to_default_profile :: proc(t: ^testing.T) {
	root := checker_profile_test_root_path()

	config := common.Config{}
	config.checker_profiles = make([dynamic]common.ConfigProfile, context.temp_allocator)
	config.profile = common.ConfigProfile{name = "default"}
	config.profile.checker_path = make([dynamic]string, context.temp_allocator)
	append(&config.profile.checker_path, path.join({root, "examples", "single.odin"}, context.temp_allocator))

	saved_file := path.join({root, "misc", "test.odin"}, context.temp_allocator)
	targets := server.resolve_check_targets(.Saved, {saved_file}, &config)

	testing.expect_value(t, 1, len(targets))
	testing.expect_value(t, targets[0].path, path.join({root, "examples", "single.odin"}, context.temp_allocator))
	testing.expect_value(t, targets[0].profile_index, -1)
}

@(test)
checker_profile_routes_can_check_directory_without_checker_path :: proc(t: ^testing.T) {
	root := checker_profile_test_root_path()

	config := common.Config{}
	config.checker_profiles = make([dynamic]common.ConfigProfile, context.temp_allocator)
	config.profile = common.ConfigProfile{name = "default"}
	config.profile.checker_path = make([dynamic]string, context.temp_allocator)

	rt_profile := common.ConfigProfile{name = "rt"}
	rt_profile.checker_path = make([dynamic]string, context.temp_allocator)
	rt_profile.checker_match_paths = make([dynamic]string, context.temp_allocator)
	append(&rt_profile.checker_match_paths, path.join({root, "rt", "drift"}, context.temp_allocator))
	append(&config.checker_profiles, rt_profile)

	saved_file := path.join({root, "rt", "drift", "math", "noise.odin"}, context.temp_allocator)
	targets := server.resolve_check_targets(.Saved, {saved_file}, &config)

	testing.expect_value(t, 1, len(targets))
	testing.expect_value(t, targets[0].path, path.join({root, "rt", "drift", "math"}, context.temp_allocator))
	testing.expect_value(t, targets[0].profile_index, 0)
}

@(test)
checker_profile_routes_expands_home_dir_in_checker_path :: proc(t: ^testing.T) {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return
	}

	config := common.Config{}
	config.checker_profiles = make([dynamic]common.ConfigProfile, context.temp_allocator)
	config.profile = common.ConfigProfile{name = "default"}
	config.profile.checker_path = make([dynamic]string, context.temp_allocator)
	append(&config.profile.checker_path, "~/repo/entry/main.odin")

	saved_file := path.join({home, "repo", "src", "foo.odin"}, context.temp_allocator)
	targets := server.resolve_check_targets(.Saved, {saved_file}, &config)

	testing.expect_value(t, 1, len(targets))
	testing.expect_value(t, targets[0].path, path.join({home, "repo", "entry", "main.odin"}, context.temp_allocator))
	testing.expect_value(t, targets[0].profile_index, -1)
}

@(test)
checker_profile_routes_expands_home_dir_in_checker_match_paths :: proc(t: ^testing.T) {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		return
	}

	config := common.Config{}
	config.checker_profiles = make([dynamic]common.ConfigProfile, context.temp_allocator)
	config.profile = common.ConfigProfile{name = "default"}
	config.profile.checker_path = make([dynamic]string, context.temp_allocator)

	rt_profile := common.ConfigProfile{name = "rt"}
	rt_profile.checker_path = make([dynamic]string, context.temp_allocator)
	rt_profile.checker_match_paths = make([dynamic]string, context.temp_allocator)
	append(&rt_profile.checker_path, path.join({home, "entry", "rt.odin"}, context.temp_allocator))
	append(&rt_profile.checker_match_paths, "~/repo/rt")
	append(&config.checker_profiles, rt_profile)

	saved_file := path.join({home, "repo", "rt", "dio", "mixer.odin"}, context.temp_allocator)
	targets := server.resolve_check_targets(.Saved, {saved_file}, &config)

	testing.expect_value(t, 1, len(targets))
	testing.expect_value(t, targets[0].path, path.join({home, "entry", "rt.odin"}, context.temp_allocator))
	testing.expect_value(t, targets[0].profile_index, 0)
}
