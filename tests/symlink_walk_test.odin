package tests

import "core:log"
import "core:os"
import "core:slice"
import "core:testing"
import path "core:path/slashpath"

import "src:server"

make_symlink_tree :: proc(t: ^testing.T) -> (root, target: string) {
	err: os.Error

	root, err = os.make_directory_temp("", "ols-symlink-root-*", context.allocator)
	if err != nil {
		log.error(t, "failed to create temp root", err)
		return
	}

	target, err = os.make_directory_temp("", "ols-symlink-target-*", context.allocator)
	if err != nil {
		log.error(t, "failed to create temp target", err)
		return
	}

	return
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
