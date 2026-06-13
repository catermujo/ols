package server

import "core:slice"
import "core:fmt"
import "core:log"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "src:common"

dir_blacklist :: []string{"node_modules", ".git"}

WorkspaceCache :: struct {
	time: time.Time,
	pkgs: [dynamic]string,
}

@(thread_local, private = "file")
cache: WorkspaceCache

Workspace_Symbol_Scan_State :: struct {
	pkgs:           [dynamic]string,
	root:           string,
	scanned_dirs:   int,
	candidate_dirs: int,
	odin_dirs:      int,
	excluded_dirs:  int,
}

workspace_path_is_excluded :: proc(pkg, root: string) -> bool {
	return path_is_excluded_by_profile(pkg, root)
}

workspace_symbols_should_skip_dir :: proc(fullpath: string, state: rawptr) -> bool {
	data := cast(^Workspace_Symbol_Scan_State)state
	data.scanned_dirs += 1

	dir, _ := filepath.replace_separators(fullpath, '/', context.temp_allocator)
	dir_name := filepath.base(dir)
	for blacklist in dir_blacklist {
		if blacklist == dir_name {
			return true
		}
	}

	if workspace_path_is_excluded(dir, data.root) {
		data.excluded_dirs += 1
		return true
	}

	data.candidate_dirs += 1
	return false
}

workspace_symbols_collect_file :: proc(fullpath: string, state: rawptr) {
	if filepath.ext(fullpath) != ".odin" {
		return
	}

	data := cast(^Workspace_Symbol_Scan_State)state
	if workspace_path_is_excluded(fullpath, data.root) {
		return
	}

	dir := filepath.dir(fullpath)
	if !slice.contains(data.pkgs[:], dir) {
		append(&data.pkgs, strings.clone(dir, context.temp_allocator))
		data.odin_dirs += 1
	}
}

get_workspace_symbols :: proc(query: string) -> (workspace_symbols: []WorkspaceSymbol, ok: bool) {
	cache_rebuilt := false

	if time.since(cache.time) > 20 * time.Second {
		cache_rebuilt = true
		rebuild_start := time.now()
		scanned_dirs := 0
		candidate_dirs := 0
		odin_dirs := 0
		excluded_dirs := 0
		built_packages := 0

		for pkg in cache.pkgs {
			delete(pkg)
		}
		clear(&cache.pkgs)
		for workspace in common.config.workspace_folders {
			uri := common.parse_uri(workspace.uri, context.temp_allocator) or_return
			data := Workspace_Symbol_Scan_State {
				pkgs = make([dynamic]string, 0, context.temp_allocator),
				root = uri.path,
			}
			walk_tree_follow_symlink_dirs(
				uri.path,
				&data,
				workspace_symbols_should_skip_dir,
				workspace_symbols_collect_file,
			)

			for pkg in data.pkgs {
				try_build_package(pkg)
				built_packages += 1
				append(&cache.pkgs, strings.clone(pkg, context.allocator))
			}

			scanned_dirs += data.scanned_dirs
			candidate_dirs += data.candidate_dirs
			odin_dirs += data.odin_dirs
			excluded_dirs += data.excluded_dirs
		}
		cache.time = time.now()

		if common.config.verbose {
			log.infof(
				"workspace/symbol cache rebuild: workspaces=%v scanned_dirs=%v candidate_dirs=%v odin_dirs=%v excluded_dirs=%v built_packages=%v cache_pkgs=%v elapsed_ms=%v",
				len(common.config.workspace_folders),
				scanned_dirs,
				candidate_dirs,
				odin_dirs,
				excluded_dirs,
				built_packages,
				len(cache.pkgs),
				time.duration_milliseconds(time.since(rebuild_start)),
			)
		}
	}

	limit :: 100
	symbols := make([dynamic]WorkspaceSymbol, 0, limit, context.temp_allocator)
	if results, ok := fuzzy_search(query, cache.pkgs[:], "", resolve_fields = false, limit = limit); ok {
		for result in results {
			symbol := WorkspaceSymbol {
				name = result.symbol.name,
				location = {range = result.symbol.range, uri = result.symbol.uri},
				kind = symbol_kind_to_type(result.symbol.type),
			}

			append(&symbols, symbol)
		}
	}

	if common.config.verbose {
		log.infof(
			"workspace/symbol query: query=%q rebuilt=%v cache_pkgs=%v results=%v",
			query,
			cache_rebuilt,
			len(cache.pkgs),
			len(symbols),
		)
	}


	return symbols[:], true
}
