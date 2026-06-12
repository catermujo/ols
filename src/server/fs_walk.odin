package server

import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"

Walk_Dir_Callback :: proc(fullpath: string, state: rawptr) -> (skip: bool)
Walk_File_Callback :: proc(fullpath: string, state: rawptr)

// Walk directories by their logical workspace path, but break cycles using the
// resolved physical path so symlinked directories are traversed once per branch.
walk_tree_follow_symlink_dirs :: proc(root: string, state: rawptr, on_dir: Walk_Dir_Callback, on_file: Walk_File_Callback) {
	active_physical_dirs := make(map[string]struct{}, 16, context.temp_allocator)
	walk_tree_follow_symlink_dirs_impl(root, state, on_dir, on_file, &active_physical_dirs)
}

walk_tree_follow_symlink_dirs_impl :: proc(
	root: string,
	state: rawptr,
	on_dir: Walk_Dir_Callback,
	on_file: Walk_File_Callback,
	active_physical_dirs: ^map[string]struct{},
) {
	root_info, err := os.stat(root, context.temp_allocator)
	if err != nil || root_info.type != .Directory {
		return
	}

	physical_root, _ := filepath.replace_separators(root_info.fullpath, '/', context.temp_allocator)
	if _, exists := active_physical_dirs[physical_root]; exists {
		return
	}

	active_physical_dirs[physical_root] = {}
	defer delete_key(active_physical_dirs, physical_root)

	dir, open_err := os.open(root)
	if open_err != nil {
		return
	}
	defer os.close(dir)

	it := os.read_directory_iterator_create(dir)
	defer os.read_directory_iterator_destroy(&it)

	for info in os.read_directory_iterator(&it) {
		if _, iter_err := os.read_directory_iterator_error(&it); iter_err != nil {
			continue
		}

		child := path.join({root, info.name}, context.temp_allocator)

		if info.type == .Directory {
			if on_dir != nil && on_dir(child, state) {
				continue
			}

			walk_tree_follow_symlink_dirs_impl(child, state, on_dir, on_file, active_physical_dirs)
			continue
		}

		if info.type == .Symlink {
			target_info, target_err := os.stat(child, context.temp_allocator)
			if target_err == nil && target_info.type == .Directory {
				if on_dir != nil && on_dir(child, state) {
					continue
				}

				walk_tree_follow_symlink_dirs_impl(child, state, on_dir, on_file, active_physical_dirs)
				continue
			}
		}

		if on_file != nil {
			on_file(child, state)
		}
	}
}
