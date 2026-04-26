package server

import "src:common"

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

//Used in semantic tokens and inlay hints to handle the entire file being resolved.

FileResolve :: struct {
	symbols: map[uintptr]SymbolAndNode,
}


FileResolveCache :: struct {
	files: map[string]FileResolve,
}

@(thread_local)
file_resolve_cache: FileResolveCache

resolve_entire_file_cached :: proc(document: ^Document) -> FileResolve {

	file, cached := file_resolve_cache.files[document.uri.uri]

	if !cached {
		file = {
			symbols = resolve_entire_file(document, .None, virtual.arena_allocator(document.allocator)),
		}
		file_resolve_cache.files[document.uri.uri] = file
	}

	return file
}

resolve_ranged_file_cached :: proc(document: ^Document, range: common.Range, allocator := context.allocator) -> FileResolve {

	file, cached := file_resolve_cache.files[document.uri.uri]

	if !cached {
		file = {
			symbols = resolve_ranged_file(document, range, allocator),
		}
	}

	return file
}

BuildCache :: struct {
	loaded_pkgs: map[string]PackageCacheInfo,
	pkg_aliases: map[string][dynamic]string,
}

PackageCacheInfo :: struct {
	timestamp: time.Time,
}

@(thread_local)
build_cache: BuildCache


clear_all_package_aliases :: proc() {
	for collection_name, alias_array in build_cache.pkg_aliases {
		for alias in alias_array {
			delete(alias)
		}
		delete(alias_array)
	}

	clear(&build_cache.pkg_aliases)
}

package_alias_for_dir :: proc(collection_root, pkg_dir: string, allocator := context.temp_allocator) -> (string, bool) {
	rel, err := filepath.rel(collection_root, pkg_dir, allocator)
	if err != .None {
		return "", false
	}

	forward_rel, _ := filepath.replace_separators(rel, '/', allocator)
	if forward_rel == ".." || strings.has_prefix(forward_rel, "../") {
		return "", false
	}

	return forward_rel, true
}

add_package_alias_for_dir :: proc(pkg_dir: string) -> bool {
	changed := false

	for collection_name, collection_root in common.config.collections {
		alias, ok := package_alias_for_dir(collection_root, pkg_dir, context.temp_allocator)
		if !ok {
			continue
		}

		if collection_name not_in build_cache.pkg_aliases {
			build_cache.pkg_aliases[collection_name] = make([dynamic]string)
		}

		aliases := &build_cache.pkg_aliases[collection_name]
		if !slice.contains(aliases[:], alias) {
			append(aliases, strings.clone(alias))
			changed = true
		}
	}

	return changed
}

remove_package_alias_for_dir :: proc(pkg_dir: string) -> bool {
	changed := false

	for collection_name, collection_root in common.config.collections {
		alias, ok := package_alias_for_dir(collection_root, pkg_dir, context.temp_allocator)
		if !ok {
			continue
		}

		aliases, exists := build_cache.pkg_aliases[collection_name]
		if !exists {
			continue
		}

		for i := len(aliases) - 1; i >= 0; i -= 1 {
			if aliases[i] != alias {
				continue
			}

			delete(aliases[i])
			ordered_remove(&aliases, i)
			changed = true
			break
		}

		if len(aliases) == 0 {
			delete(aliases)
			delete_key(&build_cache.pkg_aliases, collection_name)
		} else {
			build_cache.pkg_aliases[collection_name] = aliases
		}
	}

	return changed
}

package_dir_has_odin_files :: proc(pkg_dir: string) -> bool {
	matches, err := filepath.glob(fmt.tprintf("%s/*.odin", pkg_dir), context.temp_allocator)
	return err == nil && len(matches) > 0
}

//Go through all the collections to find all the possible packages that exists
find_all_package_aliases :: proc() {
	progress_token := progress_task_begin(
		"OLS_DISCOVER_PACKAGES",
		"Discover workspace packages",
		"Scanning collections",
	)
	discovered_total := 0

	for k, v in common.config.collections {
		pkgs := make([dynamic]string, context.temp_allocator)
		progress_report(progress_token, fmt.tprintf("Scanning collection %s", k))
		append_packages(v, &pkgs, {}, context.temp_allocator)

		for pkg in pkgs {
			if forward_pkg, ok := package_alias_for_dir(v, pkg, context.temp_allocator); ok {
				if k not_in build_cache.pkg_aliases {
					build_cache.pkg_aliases[k] = make([dynamic]string)
				}

				aliases := &build_cache.pkg_aliases[k]

				append(aliases, strings.clone(forward_pkg))
				discovered_total += 1
				progress_report(progress_token, fmt.tprintf("%s:%s", k, forward_pkg))
			}
		}
	}

	progress_end(progress_token, fmt.tprintf("Discovered %d packages", discovered_total))
}
