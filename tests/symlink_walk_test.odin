package tests

import "core:log"
import "core:os"
import "core:slice"
import "core:testing"
import path "core:path/slashpath"

import "src:common"
import "src:server"

make_symlink_tree :: proc(t: ^testing.T) -> (root, target: string) {
	err: os.Error

	root, err = os.make_directory_temp("", "ols-symlink-root-*", context.temp_allocator)
	if err != nil {
		log.error(t, "failed to create temp root", err)
		return
	}

	target, err = os.make_directory_temp("", "ols-symlink-target-*", context.temp_allocator)
	if err != nil {
		log.error(t, "failed to create temp target", err)
		return
	}

	return
}

reset_walk_config :: proc() {
	delete(common.config.workspace_folders)
	common.config.workspace_folders = nil
	delete(common.config.collections)
	common.config.collections = nil
	delete(common.config.profile.exclude_path)
	common.config.profile.exclude_path = nil
	server.reference_import_cache_reset()
}

@(test)
append_packages_follows_symlinked_directories :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}

	root, target := make_symlink_tree(t)
	defer os.remove_all(root)
	defer os.remove_all(target)

	target_pkg := path.join({target, "pkg"}, context.temp_allocator)
	if err := os.mkdir_all(target_pkg); err != nil {
		log.error(t, "failed to create target package dir", err)
		return
	}

	target_file := path.join({target_pkg, "main.odin"}, context.temp_allocator)
	if err := os.write_entire_file(target_file, "package pkg\n"); err != nil {
		log.error(t, "failed to write target file", err)
		return
	}

	logical_vendor := path.join({root, "vendor"}, context.temp_allocator)
	if err := os.symlink(target, logical_vendor); err != nil {
		log.error(t, "failed to create symlink", err)
		return
	}

	pkgs := make([dynamic]string, context.temp_allocator)
	server.append_packages(root, &pkgs, {}, context.temp_allocator)

	logical_pkg := path.join({root, "vendor", "pkg"}, context.temp_allocator)
	if !slice.contains(pkgs[:], logical_pkg) {
		log.errorf("expected symlinked package path %q in %v", logical_pkg, pkgs[:])
	}

	if slice.contains(pkgs[:], target_pkg) {
		log.errorf("expected logical package path, got physical path %q", target_pkg)
	}
}

@(test)
reference_import_cache_scan_tree_uses_logical_symlink_paths :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}

	defer reset_reference_config()

	root, target := make_symlink_tree(t)
	defer os.remove_all(root)
	defer os.remove_all(target)

	target_pkg := path.join({target, "vendor_pkg"}, context.temp_allocator)
	if err := os.mkdir_all(target_pkg); err != nil {
		log.error(t, "failed to create target package dir", err)
		return
	}

	target_file := path.join({target_pkg, "main.odin"}, context.temp_allocator)
	if err := os.write_entire_file(target_file, "package vendor_pkg\n"); err != nil {
		log.error(t, "failed to write target file", err)
		return
	}

	logical_vendor := path.join({root, "vendor"}, context.temp_allocator)
	if err := os.symlink(target, logical_vendor); err != nil {
		log.error(t, "failed to create symlink", err)
		return
	}

	server.reference_import_cache_scan_tree(root)

	logical_pkg := path.join({root, "vendor", "vendor_pkg"}, context.temp_allocator)
	logical_file := path.join({logical_pkg, "main.odin"}, context.temp_allocator)

	files, ok := server.reference_import_cache.package_files[logical_pkg]
	if !ok {
		log.errorf("expected cached package files for %q", logical_pkg)
		return
	}

	if !slice.contains(files[:], logical_file) {
		log.errorf("expected logical file path %q in %v", logical_file, files[:])
	}

	if _, physical_ok := server.reference_import_cache.package_files[target_pkg]; physical_ok {
		log.errorf("unexpected physical package cache entry for %q", target_pkg)
	}
}

@(test)
append_packages_honors_nested_profile_excludes :: proc(t: ^testing.T) {
	defer reset_walk_config()

	root, err := os.make_directory_temp("", "ols-exclude-root-*", context.temp_allocator)
	if err != nil {
		log.error(t, "failed to create temp root", err)
		return
	}
	defer os.remove_all(root)

	excluded_pkg := path.join({root, "breakout", "build", "tmp_pkg"}, context.temp_allocator)
	if err := os.mkdir_all(excluded_pkg); err != nil {
		log.error(t, "failed to create excluded package dir", err)
		return
	}

	excluded_file := path.join({excluded_pkg, "main.odin"}, context.temp_allocator)
	if err := os.write_entire_file(excluded_file, "package tmp_pkg\n"); err != nil {
		log.error(t, "failed to write excluded package file", err)
		return
	}

	included_pkg := path.join({root, "game", "pkg"}, context.temp_allocator)
	if err := os.mkdir_all(included_pkg); err != nil {
		log.error(t, "failed to create included package dir", err)
		return
	}

	included_file := path.join({included_pkg, "main.odin"}, context.temp_allocator)
	if err := os.write_entire_file(included_file, "package pkg\n"); err != nil {
		log.error(t, "failed to write included package file", err)
		return
	}

	common.config.profile.exclude_path = make([dynamic]string, context.temp_allocator)
	append(&common.config.profile.exclude_path, path.join({root, "build", "**"}, context.temp_allocator))

	pkgs := make([dynamic]string, context.temp_allocator)
	server.append_packages(root, &pkgs, {}, context.temp_allocator)

	if slice.contains(pkgs[:], excluded_pkg) {
		log.errorf("expected nested build package %q to be excluded", excluded_pkg)
	}

	if !slice.contains(pkgs[:], included_pkg) {
		log.errorf("expected included package %q in %v", included_pkg, pkgs[:])
	}
}

@(test)
reference_path_is_excluded_matches_nested_profile_excludes :: proc(t: ^testing.T) {
	defer reset_walk_config()

	root, err := os.make_directory_temp("", "ols-exclude-root-*", context.temp_allocator)
	if err != nil {
		log.error(t, "failed to create temp root", err)
		return
	}
	defer os.remove_all(root)

	uri := common.create_uri(root, context.temp_allocator)
	common.config.workspace_folders = make([dynamic]common.WorkspaceFolder, 0, 1, context.temp_allocator)
	append(&common.config.workspace_folders, common.WorkspaceFolder {
		name = "test",
		uri  = uri.uri,
	})

	common.config.profile.exclude_path = make([dynamic]string, context.temp_allocator)
	append(&common.config.profile.exclude_path, path.join({root, "build", "**"}, context.temp_allocator))

	excluded_file := path.join({root, "breakout", "build", "cache", "main.odin"}, context.temp_allocator)
	if !server.reference_path_is_excluded(excluded_file) {
		log.errorf("expected nested build path %q to be excluded", excluded_file)
	}

	included_file := path.join({root, "game", "pkg", "main.odin"}, context.temp_allocator)
	if server.reference_path_is_excluded(included_file) {
		log.errorf("unexpected exclude match for %q", included_file)
	}
}
