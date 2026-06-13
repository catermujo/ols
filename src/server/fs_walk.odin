package server

import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:strings"

import "src:common"

Walk_Dir_Callback :: proc(fullpath: string, state: rawptr) -> (skip: bool)
Walk_File_Callback :: proc(fullpath: string, state: rawptr)

normalize_match_path :: proc(raw: string) -> string {
	forward, _ := filepath.replace_separators(raw, '/', context.temp_allocator)
	return strings.to_lower(forward)
}

path_matches_tree_prefix :: proc(path, prefix: string) -> bool {
	if prefix == "" || !strings.has_prefix(path, prefix) {
		return false
	}

	if len(path) == len(prefix) {
		return true
	}

	if strings.has_suffix(prefix, "/") {
		return true
	}

	return path[len(prefix)] == '/'
}

path_relative_to_root :: proc(path, root: string) -> (string, bool) {
	if root == "" || !path_matches_tree_prefix(path, root) {
		return "", false
	}

	if len(path) == len(root) {
		return "", true
	}

	if strings.has_suffix(root, "/") {
		return path[len(root):], true
	}

	return path[len(root)+1:], true
}

path_contains_component_sequence :: proc(path, sequence: string) -> bool {
	if sequence == "" {
		return false
	}

	if path == sequence {
		return true
	}

	search_start := 0
	for search_start < len(path) {
		index := strings.index(path[search_start:], sequence)
		if index < 0 {
			return false
		}

		match_start := search_start + index
		match_end := match_start + len(sequence)
		before_ok := match_start == 0 || path[match_start-1] == '/'
		after_ok := match_end == len(path) || path[match_end] == '/'

		if before_ok && after_ok {
			return true
		}

		search_start = match_start + 1
	}

	return false
}

path_matches_profile_exclude_under_root :: proc(path, exclude, root: string) -> bool {
	relative_exclude, exclude_ok := path_relative_to_root(exclude, root)
	if !exclude_ok || relative_exclude == "" {
		return false
	}

	relative_path, path_ok := path_relative_to_root(path, root)
	if !path_ok {
		return false
	}

	return path_contains_component_sequence(relative_path, relative_exclude)
}

path_is_excluded_by_profile :: proc(fullpath: string, root := "") -> bool {
	lower_path := normalize_match_path(fullpath)
	if lower_path == "" {
		return false
	}

	lower_root := ""
	if root != "" {
		lower_root = normalize_match_path(root)
	}

	for exclude_path in common.config.profile.exclude_path {
		lower_exclude := normalize_match_path(exclude_path)
		if lower_exclude == "" {
			continue
		}

		if strings.has_suffix(lower_exclude, "/**") {
			prefix := lower_exclude[:len(lower_exclude)-3]

			if path_matches_tree_prefix(lower_path, prefix) {
				return true
			}

			if lower_root != "" {
				if path_matches_profile_exclude_under_root(lower_path, prefix, lower_root) {
					return true
				}
				continue
			}

			for workspace in common.config.workspace_folders {
				uri, ok := common.parse_uri(workspace.uri, context.temp_allocator)
				if !ok {
					continue
				}

				if path_matches_profile_exclude_under_root(lower_path, prefix, normalize_match_path(uri.path)) {
					return true
				}
			}

			for _, collection_root in common.config.collections {
				if path_matches_profile_exclude_under_root(lower_path, prefix, normalize_match_path(collection_root)) {
					return true
				}
			}

			continue
		}

		if lower_path == lower_exclude {
			return true
		}
	}

	return false
}

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
