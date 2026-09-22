package server

import "base:runtime"

import "core:fmt"
import "core:log"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:slice"
import "core:strings"
import "core:time"

import "src:common"
import "src:spall"

reference_dir_blacklist :: []string{"node_modules", ".git"}

ReferenceCandidateCacheEntry :: struct {
	paths: [dynamic]string,
	created: time.Time,
}

ReferenceResolvedCacheEntry :: struct {
	locations: [dynamic]common.Location,
	created:  time.Time,
}

ReferenceImportPackage :: struct {
	paths:  [dynamic]string,
	imports: map[string]struct{},
}

ReferenceImportGraph :: struct {
	packages:  map[string]ReferenceImportPackage,
	all_paths: [dynamic]string,
	complete:  bool,
}

@(thread_local)
reference_candidate_cache: map[string]ReferenceCandidateCacheEntry

@(thread_local)
reference_resolved_cache: map[string]ReferenceResolvedCacheEntry

when ODIN_TEST {
	reference_resolution_test_parse_count: int

	reference_resolution_test_reset :: proc() {
		reference_resolution_test_parse_count = 0
	}

	reference_resolution_test_parse_count_get :: proc() -> int {
		return reference_resolution_test_parse_count
	}

	reference_resolved_cache_test_entry_count :: proc() -> int {
		return len(reference_resolved_cache)
	}
}

@(thread_local)
reference_import_graph: ReferenceImportGraph

reference_candidate_cache_reset :: proc() {
	allocator := runtime.default_allocator()
	for pkg, entry in reference_candidate_cache {
		for fullpath in entry.paths do delete(fullpath, allocator)
		delete(entry.paths)
		delete(pkg, allocator)
	}
	delete(reference_candidate_cache)
	reference_candidate_cache = nil

	reference_resolved_cache_reset()

	for pkg, entry in reference_import_graph.packages {
		for fullpath in entry.paths do delete(fullpath, allocator)
		delete(entry.paths)
		for imported_pkg in entry.imports {
			delete(imported_pkg, allocator)
		}
		delete(entry.imports)
		delete(pkg, allocator)
	}
	delete(reference_import_graph.packages)
	for fullpath in reference_import_graph.all_paths do delete(fullpath, allocator)
	delete(reference_import_graph.all_paths)
	reference_import_graph = {}
}

reference_resolved_cache_reset :: proc() {
	allocator := runtime.default_allocator()
	for key, entry in reference_resolved_cache {
		for location in entry.locations do delete(location.uri, allocator)
		delete(entry.locations)
		delete(key, allocator)
	}
	delete(reference_resolved_cache)
	reference_resolved_cache = nil
}

reference_resolved_cache_key :: proc(
	symbol: Symbol,
	resolve_flag: ResolveReferenceFlag,
	target_name: string,
	current_document_uri: string,
	current_file_only: bool,
	include_declaration: bool,
) -> string {
	return fmt.tprintf(
		"%s\x00%s\x00%s\x00%s\x00%d:%d:%d:%d:%d:%v:%v",
		symbol.uri,
		symbol.pkg,
		target_name,
		current_document_uri,
		symbol.range.start.line,
		symbol.range.start.character,
		symbol.range.end.line,
		symbol.range.end.character,
		int(resolve_flag),
		current_file_only,
		include_declaration,
	)
}

reference_resolved_cache_copy :: proc(
	locations: []common.Location,
	allocator: runtime.Allocator,
) -> [dynamic]common.Location {
	copied := make([dynamic]common.Location, 0, len(locations), allocator)
	for location in locations {
		append(&copied, common.Location {
			range = location.range,
			uri   = strings.clone(location.uri, allocator),
		})
	}
	return copied
}

reference_resolved_cache_store :: proc(key: string, locations: []common.Location) {
	allocator := runtime.default_allocator()
	if entry, ok := reference_resolved_cache[key]; ok {
		for location in entry.locations do delete(location.uri, allocator)
		delete(entry.locations)
		reference_resolved_cache[key] = ReferenceResolvedCacheEntry {
			locations = reference_resolved_cache_copy(locations, allocator),
			created = time.now(),
		}
		return
	}
	if len(reference_resolved_cache) >= 32 {
		reference_resolved_cache_reset()
	}
	if reference_resolved_cache == nil {
		reference_resolved_cache = make(map[string]ReferenceResolvedCacheEntry, 32, allocator)
	}
	reference_resolved_cache[strings.clone(key, allocator)] = ReferenceResolvedCacheEntry {
		locations = reference_resolved_cache_copy(locations, allocator),
		created = time.now(),
	}
}

reference_resolved_cache_load :: proc(
	key: string,
	allocator: runtime.Allocator,
) -> ([]common.Location, bool) {
	entry, ok := reference_resolved_cache[key]
	if !ok || time.since(entry.created) >= 30 * time.Second {
		return {}, false
	}
	locations := reference_resolved_cache_copy(entry.locations[:], allocator)
	return locations[:], true
}

reference_path_is_excluded :: proc(fullpath: string) -> bool {
	forward_path, _ := filepath.replace_separators(fullpath, '/', context.temp_allocator)
	lower_path := strings.to_lower(forward_path, context.temp_allocator)

	for exclude_path in common.config.profile.exclude_path {
		exclude_forward, _ := filepath.replace_separators(exclude_path, '/', context.temp_allocator)
		lower_exclude := strings.to_lower(exclude_forward, context.temp_allocator)

		if strings.has_suffix(lower_exclude, "/**") {
			prefix := lower_exclude[:len(lower_exclude) - 3]
			if lower_path == prefix ||
			   (strings.has_prefix(lower_path, prefix) &&
			    len(lower_path) > len(prefix) &&
			    lower_path[len(prefix)] == '/') {
				return true
			}
		} else if lower_path == lower_exclude {
			return true
		}
	}

	return false
}

reference_normalize_path :: proc(fullpath: string) -> string {
	normalized_path, err := filepath.clean(fullpath, context.temp_allocator)
	if err != nil do normalized_path = fullpath
	forward_path, _ := filepath.replace_separators(normalized_path, '/', context.temp_allocator)
	return forward_path
}

reference_should_skip_dir :: proc(fullpath: string) -> bool {
	forward_path, _ := filepath.replace_separators(fullpath, '/', context.temp_allocator)
	dir_name := filepath.base(forward_path)

	for blacklist in reference_dir_blacklist {
		if blacklist == dir_name {
			return true
		}
	}

	return reference_path_is_excluded(forward_path)
}

add_reference_candidate_path :: proc(paths: ^map[string]struct{}, fullpath: string) {
	forward_path, _ := filepath.replace_separators(fullpath, '/', context.temp_allocator)
	if _, exists := paths[forward_path]; exists {
		return
	}

	paths[strings.clone(forward_path, context.temp_allocator)] = {}
}

collect_reference_package_files :: proc(pkg_name: string, paths: ^map[string]struct{}) {
	matches, err := filepath.glob(fmt.tprintf("%s/*.odin", pkg_name), context.temp_allocator)
	if err != nil && err != .Not_Exist {
		return
	}

	for fullpath in matches {
		add_reference_candidate_path(paths, fullpath)
	}
}

reference_import_path_matches_package :: proc(file_dir, pkg_name, import_path: string) -> bool {
	if i := strings.index(import_path, ":"); i != -1 && i > 0 && i < len(import_path) - 1 {
		collection := import_path[:i]
		p := import_path[i + 1:]

		dir, ok := common.config.collections[collection]
		if !ok {
			return false
		}

		full := path.join(elems = {dir, p}, allocator = context.temp_allocator)
		full = path.clean(full, context.temp_allocator)
		forward_full, _ := filepath.replace_separators(full, '/', context.temp_allocator)
		return strings.equal_fold(forward_full, pkg_name)
	}

	full := path.join(elems = {file_dir, import_path}, allocator = context.temp_allocator)
	full = path.clean(full, context.temp_allocator)
	forward_full, _ := filepath.replace_separators(full, '/', context.temp_allocator)
	return strings.equal_fold(forward_full, pkg_name)
}

source_may_reference_package :: proc(fullpath, pkg_name, src: string) -> bool {
	if is_builtin_pkg(pkg_name) {
		return true
	}

	file_dir := filepath.dir(fullpath)
	forward_dir := reference_normalize_path(file_dir)
	forward_pkg := reference_normalize_path(pkg_name)

	if strings.equal_fold(forward_dir, forward_pkg) {
		return true
	}

	for i := 0; i < len(src); i += 1 {
		if src[i] != '"' {
			continue
		}

		end := i + 1
		for ; end < len(src) && src[end] != '"'; end += 1 {
		}

		if end >= len(src) {
			break
		}

		if reference_import_path_matches_package(forward_dir, forward_pkg, src[i + 1:end]) {
			return true
		}

		i = end
	}

	return false
}

reference_import_graph_add_path :: proc(paths: ^[dynamic]string, fullpath: string) {
	for existing in paths^ {
		if strings.equal_fold(existing, fullpath) do return
	}
	append(paths, strings.clone(fullpath, runtime.default_allocator()))
}

reference_import_graph_package :: proc(pkg_name: string) -> ^ReferenceImportPackage {
	if reference_import_graph.packages == nil {
		reference_import_graph.packages = make(map[string]ReferenceImportPackage, 32, runtime.default_allocator())
	}
	if _, ok := reference_import_graph.packages[pkg_name]; !ok {
		key := strings.clone(pkg_name, runtime.default_allocator())
		reference_import_graph.packages[key] = {}
	}

	pkg := &reference_import_graph.packages[pkg_name]
	if pkg.imports == nil {
		pkg.imports = make(map[string]struct{}, 8, runtime.default_allocator())
	}
	return pkg
}

reference_import_graph_import_path :: proc(file_dir, import_path: string) -> (string, bool) {
	if len(import_path) < 2 || import_path[0] != '"' || import_path[len(import_path) - 1] != '"' {
		return "", false
	}

	if i := strings.index(import_path, ":"); i != -1 && i > 1 && i < len(import_path) - 1 {
		collection := import_path[1:i]
		p := import_path[i + 1:len(import_path) - 1]
		dir, ok := common.config.collections[collection]
		if !ok {
			return "", false
		}

		full := path.join(elems = {dir, p}, allocator = context.temp_allocator)
		full = path.clean(full, context.temp_allocator)
		forward_full, _ := filepath.replace_separators(full, '/', context.temp_allocator)
		return forward_full, true
	}

	full := path.join(
		elems = {file_dir, import_path[1:len(import_path) - 1]},
		allocator = context.temp_allocator,
	)
	full = path.clean(full, context.temp_allocator)
	forward_full, _ := filepath.replace_separators(full, '/', context.temp_allocator)
	return forward_full, true
}

reference_import_graph_path_exists :: proc(fullpath: string) -> bool {
	normalized_path := reference_normalize_path(fullpath)
	for existing in reference_import_graph.all_paths {
		if strings.equal_fold(reference_normalize_path(existing), normalized_path) do return true
	}
	return false
}

reference_open_document_source :: proc(fullpath: string) -> (string, string, bool) {
	normalized_path := reference_normalize_path(fullpath)
	for _, &document in document_storage.documents {
		if document.client_owned &&
		   strings.equal_fold(reference_normalize_path(document.fullpath), normalized_path) {
			return string(document.text[:document.used_text]), document.fullpath, true
		}
	}
	return "", "", false
}

reference_open_document_path_is_skipped :: proc(fullpath: string) -> bool {
	normalized_path := reference_normalize_path(fullpath)
	if reference_path_is_excluded(normalized_path) do return true

	dir := filepath.dir(normalized_path)
	for {
		if reference_should_skip_dir(dir) do return true
		parent := filepath.dir(dir)
		if parent == dir || dir == "" do break
		dir = parent
	}
	return false
}

reference_workspace_path_is_in_scope :: proc(fullpath: string) -> bool {
	if reference_open_document_path_is_skipped(fullpath) do return false

	normalized_path := reference_normalize_path(fullpath)
	for workspace in common.config.workspace_folders {
		uri, valid := common.parse_uri(workspace.uri, context.temp_allocator)
		if !valid do continue
		root := reference_normalize_path(uri.path)
		if strings.equal_fold(normalized_path, root) ||
		   (strings.has_prefix(normalized_path, root) &&
		    len(normalized_path) > len(root) && normalized_path[len(root)] == '/') {
			return true
		}
	}
	return false
}

reference_import_graph_process_file :: proc(
	logical_path, src: string,
	scan_arena: ^runtime.Arena,
	allocator: runtime.Allocator,
) {
	reference_import_graph_add_path(&reference_import_graph.all_paths, logical_path)
	if common.has_ignore_file_tag(src) || file_when_tags_exclude(src, logical_path) do return

	context.allocator = runtime.arena_allocator(scan_arena)
	p := parser.Parser {flags = {.Optional_Semicolons}}
	if !is_ols_builtin_file(logical_path) {
		p.err = log_error_handler
		p.warn = log_warning_handler
	}

	pkg := new(ast.Package)
	pkg.kind = .Normal
	pkg.fullpath = logical_path
	pkg.name = filepath.base(filepath.dir(logical_path))
	file := ast.File {fullpath = logical_path, src = src, pkg = pkg}

	ok := parse_file(&p, &file, runtime.arena_allocator(scan_arena))
	context.allocator = allocator
	if !ok || file.syntax_error_count > 0 || file.pkg_decl == nil {
		reference_import_graph.complete = false
		return
	}

	file_dir, _ := filepath.replace_separators(filepath.dir(logical_path), '/', context.temp_allocator)
	pkg_name, _ := filepath.replace_separators(file_dir, '/', context.temp_allocator)
	package_info := reference_import_graph_package(pkg_name)
	reference_import_graph_add_path(&package_info.paths, logical_path)

	for imp in file.imports {
		imported_pkg, import_ok := reference_import_graph_import_path(file_dir, imp.fullpath)
		if !import_ok {
			reference_import_graph.complete = false
			continue
		}
		if imported_pkg not_in package_info.imports {
			package_info.imports[strings.clone(imported_pkg, allocator)] = {}
		}
	}
}

reference_import_graph_build :: proc() {
	allocator := runtime.default_allocator()
	previous_allocator := context.allocator
	defer context.allocator = previous_allocator
	context.allocator = allocator
	reference_import_graph.packages = make(map[string]ReferenceImportPackage, 32, allocator)
	reference_import_graph.complete = true

	scan_arena: runtime.Arena
	_ = runtime.arena_init(&scan_arena, mem.Megabyte * 2, allocator)
	defer runtime.arena_destroy(&scan_arena)

	for workspace in common.config.workspace_folders {
		uri, valid := common.parse_uri(workspace.uri, context.temp_allocator)
		if !valid {
			reference_import_graph.complete = false
			continue
		}

		physical_root, _ := os.get_absolute_path(uri.path, context.temp_allocator)
		w := os.walker_create(uri.path)
		defer os.walker_destroy(&w)
		for info in os.walker_walk(&w) {
			logical_path := info.fullpath
			if physical_root != "" && strings.has_prefix(info.fullpath, physical_root) &&
			   len(info.fullpath) > len(physical_root) && info.fullpath[len(physical_root)] == '/' {
				logical_path = fmt.tprintf("%s%s", uri.path, info.fullpath[len(physical_root):])
			}
			if info.type == .Directory {
				if reference_should_skip_dir(logical_path) do os.walker_skip_dir(&w)
				continue
			}
			if info.fullpath == "" || !strings.has_suffix(info.name, ".odin") do continue

			context.allocator = allocator
			runtime.arena_free_all(&scan_arena)
			src, _, open := reference_open_document_source(logical_path)
			if !open {
				data, err := os.read_entire_file(info.fullpath, runtime.arena_allocator(&scan_arena))
				if err != nil {
					log.warnf("failed to read file for reference graph %v", info.fullpath)
					reference_import_graph.complete = false
					continue
				}
				src = string(data)
			}
			reference_import_graph_process_file(logical_path, src, &scan_arena, allocator)
			context.allocator = allocator
			runtime.arena_free_all(&scan_arena)
		}
	}

	for _, &document in document_storage.documents {
		if !document.client_owned || !strings.has_suffix(document.fullpath, ".odin") do continue
		if !reference_workspace_path_is_in_scope(document.fullpath) do continue
		if reference_import_graph_path_exists(document.fullpath) do continue

		context.allocator = allocator
		runtime.arena_free_all(&scan_arena)
		reference_import_graph_process_file(
			document.fullpath,
			string(document.text[:document.used_text]),
			&scan_arena,
			allocator,
		)
		context.allocator = allocator
		runtime.arena_free_all(&scan_arena)
	}
}

reference_import_graph_contains :: proc(packages: map[string]struct{}, pkg_name: string) -> bool {
	if _, ok := packages[pkg_name]; ok {
		return true
	}
	for existing in packages {
		if strings.equal_fold(existing, pkg_name) do return true
	}
	return false
}

collect_reference_import_graph_packages :: proc(pkg_name: string, packages: ^map[string]struct{}) {
	packages^[strings.clone(pkg_name, context.temp_allocator)] = {}

	for {
		new_packages := make([dynamic]string, 0, context.temp_allocator)
		for candidate_name, candidate in reference_import_graph.packages {
			if reference_import_graph_contains(packages^, candidate_name) do continue
			for imported_pkg in candidate.imports {
				if reference_import_graph_contains(packages^, imported_pkg) {
					append(&new_packages, candidate_name)
					break
				}
			}
		}

		if len(new_packages) == 0 do break
		for candidate_name in new_packages {
			packages^[strings.clone(candidate_name, context.temp_allocator)] = {}
		}
	}
}

collect_workspace_reference_candidates_unbounded :: proc(pkg_name: string, paths: ^map[string]struct{}) {
	scan_arena: runtime.Arena
	_ = runtime.arena_init(&scan_arena, mem.Megabyte * 2, runtime.default_allocator())
	defer runtime.arena_destroy(&scan_arena)

	for workspace in common.config.workspace_folders {
		uri, valid := common.parse_uri(workspace.uri, context.temp_allocator)
		if !valid do continue
		physical_root, _ := os.get_absolute_path(uri.path, context.temp_allocator)
		w := os.walker_create(uri.path)
		defer os.walker_destroy(&w)
		for info in os.walker_walk(&w) {
			logical_path := info.fullpath
			if physical_root != "" && strings.has_prefix(info.fullpath, physical_root) &&
			   len(info.fullpath) > len(physical_root) && info.fullpath[len(physical_root)] == '/' {
				logical_path = fmt.tprintf("%s%s", uri.path, info.fullpath[len(physical_root):])
			}
			if info.type == .Directory {
				if reference_should_skip_dir(logical_path) do os.walker_skip_dir(&w)
				continue
			}
			if info.fullpath == "" || !strings.has_suffix(info.name, ".odin") do continue
			runtime.arena_free_all(&scan_arena)
			data, err := os.read_entire_file(info.fullpath, runtime.arena_allocator(&scan_arena))
			if err != nil {
				log.warnf("failed to read file for references %v: %v", info.fullpath, err)
				continue
			}
			if source_may_reference_package(logical_path, pkg_name, string(data)) {
				add_reference_candidate_path(paths, logical_path)
			}
		}
	}
}

collect_workspace_reference_candidates :: proc(pkg_name: string, paths: ^map[string]struct{}) {
	if entry, ok := reference_candidate_cache[pkg_name]; ok && time.since(entry.created) < 30 * time.Second {
		for fullpath in entry.paths do add_reference_candidate_path(paths, fullpath)
		return
	}

	// Rebuild on expiry, and cap memory when many packages are queried.
	if len(reference_candidate_cache) >= 16 || (pkg_name in reference_candidate_cache) {
		reference_candidate_cache_reset()
	}

	if is_builtin_pkg(pkg_name) {
		collect_workspace_reference_candidates_unbounded(pkg_name, paths)
	} else {
		if reference_import_graph.packages == nil {
			reference_import_graph_build()
		}

		if !reference_import_graph.complete {
			for fullpath in reference_import_graph.all_paths {
				add_reference_candidate_path(paths, fullpath)
			}
		} else {
			reachable := make(map[string]struct{}, 16, context.temp_allocator)
			collect_reference_import_graph_packages(pkg_name, &reachable)
			for candidate_name in reachable {
				if package_info, ok := reference_import_graph.packages[candidate_name]; ok {
					for fullpath in package_info.paths {
						add_reference_candidate_path(paths, fullpath)
					}
				}
			}
		}
	}

	allocator := runtime.default_allocator()
	if reference_candidate_cache == nil {
		reference_candidate_cache = make(map[string]ReferenceCandidateCacheEntry, 16, allocator)
	}
	cached_paths := make([dynamic]string, 0, len(paths^), allocator)
	for fullpath in paths^ do append(&cached_paths, strings.clone(fullpath, allocator))
	reference_candidate_cache[strings.clone(pkg_name, allocator)] = {
		paths = cached_paths,
		created = time.now(),
	}
}

prepare_references :: proc(
	document: ^Document,
	ast_context: ^AstContext,
	position_context: ^DocumentPositionContext,
) -> (
	symbol: Symbol,
	resolve_flag: ResolveReferenceFlag,
	ok: bool,
) {
	spall.trace(#procedure, document.fullpath)

	pkg := ""

	if position_context.enum_type != nil {
		found := false
		done_enum: for field in position_context.enum_type.fields {
			if ident, ok := field.derived.(^ast.Ident); ok {
				if position_in_node(ident, position_context.position) {
					symbol = Symbol {
						pkg   = ast_context.current_package,
						range = common.get_token_range(ident, ast_context.file.src),
					}
					found = true
					resolve_flag = .Field
					break done_enum
				}
			} else if value, ok := field.derived.(^ast.Field_Value); ok {
				if position_in_node(value.field, position_context.position) {
					symbol = Symbol {
						range = common.get_token_range(value.field, ast_context.file.src),
						pkg   = ast_context.current_package,
					}
					found = true
					resolve_flag = .Field
					break done_enum
				} else if position_in_node(value.value, position_context.position) {
					if ident, ok := value.value.derived.(^ast.Ident); ok {
						symbol, ok = resolve_location_identifier(ast_context, ident^)
						if !ok {
							return
						}

						found = true
						resolve_flag = .Identifier
						break done_enum
					}
				}
			}
		}
		if !found {
			return
		}
	} else if position_context.bitset_type != nil {
		if position_in_node(position_context.bitset_type.elem, position_context.position) {
			symbol, ok = resolve_location_type_expression(ast_context, position_context.bitset_type.elem)
			if !ok {
				return
			}
			resolve_flag = .Identifier
		}
		return
	} else if position_context.union_type != nil {
		found := false
		for variant in position_context.union_type.variants {
			if position_in_node(variant, position_context.position) {
				if ident, _, ok := unwrap_pointer_ident(variant); ok {
					symbol, ok = resolve_location_identifier(ast_context, ident)
					resolve_flag = .Identifier

					if !ok {
						return
					}

					found = true

					break
				} else {
					return
				}
			}
		}
		if !found {
			return
		}

	} else if position_context.field_value != nil &&
	   !is_expr_basic_lit(position_context.field_value.field) &&
	   position_in_node(position_context.field_value.field, position_context.position) {
		if position_context.comp_lit != nil {
			symbol, ok = resolve_location_comp_lit_field(ast_context, position_context)
			if !ok {
				return
			}
		} else if position_context.call != nil {
			symbol, ok = resolve_location_proc_param_name(ast_context, position_context)
			if !ok {
				return
			}
		}

		resolve_flag = .Field
	} else if position_context.selector_expr != nil {
		if position_in_node(position_context.selector, position_context.position) &&
		   position_context.identifier != nil {
			ident := position_context.identifier.derived.(^ast.Ident)

			symbol, ok = resolve_location_identifier(ast_context, ident^)

			if !ok {
				return
			}

			resolve_flag = .Identifier
		} else {
			symbol, ok = resolve_location_selector(ast_context, position_context.selector_expr)
			symbol.flags -= {.Local}

			resolve_flag = .Field
		}
	} else if position_context.implicit {
		resolve_flag = .Field

		symbol, ok = resolve_location_implicit_selector(
			ast_context,
			position_context,
			position_context.implicit_selector_expr,
		)
		symbol.flags -= {.Local}

		if !ok {
			return
		}
	} else {
		// The order of these is important as a lot of the above can be defined within a struct so we
		// need to make sure we resolve that last
		if position_context.bit_field_type != nil {
			for field in position_context.bit_field_type.fields {
				if position_in_node(field.name, position_context.position) {
					symbol = Symbol {
						range = common.get_token_range(field.name, ast_context.file.src),
						pkg   = ast_context.current_package,
						uri   = document.uri.uri,
					}
					return symbol, .Field, true
				}
				if position_in_node(field.type, position_context.position) {
					node := get_desired_expr(field.type, position_context.position)
					if symbol, ok = resolve_location_type_expression(ast_context, node); ok {
						return symbol, .Identifier, true
					}
				}
			}
		}

		if position_context.struct_type != nil {
			for field in position_context.struct_type.fields.list {
				for name in field.names {
					if position_in_node(name, position_context.position) {
						symbol = Symbol {
							range = common.get_token_range(name, ast_context.file.src),
							pkg   = ast_context.current_package,
							uri   = document.uri.uri,
						}
						return symbol, .Field, true
					}
				}
				if position_in_node(field.type, position_context.position) {
					node := get_desired_expr(field.type, position_context.position)
					if symbol, ok = resolve_location_type_expression(ast_context, node); ok {
						return symbol, .Identifier, true
					}
				}
			}
		}

		if position_context.identifier != nil {
			ident := position_context.identifier.derived.(^ast.Ident)
			symbol, ok = resolve_location_identifier(ast_context, ident^)

			resolve_flag = .Identifier

			if !ok {
				return
			}
		} else {
			return
		}
	}
	if symbol.uri == "" {
		symbol.uri = document.uri.uri
	}

	return symbol, resolve_flag, true
}

get_target_name :: proc(position_context: ^DocumentPositionContext, resolve_flag: ResolveReferenceFlag) -> string {
	if resolve_flag == .Field {
		if position_context.field != nil {
			if ident, ok := position_context.field.derived.(^ast.Ident); ok {
				return ident.name
			}
		}

		if position_context.implicit_selector_expr != nil {
			return position_context.implicit_selector_expr.field.name
		}
	}

	if position_context.identifier != nil {
		if ident, ok := position_context.identifier.derived.(^ast.Ident); ok {
			return ident.name
		}
	}

	return ""
}

resolve_references :: proc(
	document: ^Document,
	ast_context: ^AstContext,
	position_context: ^DocumentPositionContext,
	current_file_only := false,
	include_declaration := true,
) -> (
	[]common.Location,
	bool,
) {
	spall.trace(#procedure, document.fullpath)

	locations := make([dynamic]common.Location, 0, ast_context.allocator)
	fullpaths := make([dynamic]string, 0, context.temp_allocator)

	symbol, resolve_flag, ok := prepare_references(document, ast_context, position_context)
	if !ok {
		return {}, true
	}

	target_name := get_target_name(position_context, resolve_flag)
	current_document_uri := current_file_only ? document.uri.uri : ""
	cache_key := reference_resolved_cache_key(
		symbol,
		resolve_flag,
		target_name,
		current_document_uri,
		current_file_only,
		include_declaration,
	)
	if cached, ok := reference_resolved_cache_load(cache_key, ast_context.allocator); ok {
		return cached, true
	}

	symbols_and_nodes := resolve_entire_file_for_references(document, ast_context.allocator, resolve_flag, target_name)

	for k, v in symbols_and_nodes {
		if strings.equal_fold(v.symbol.uri, symbol.uri) && v.symbol.range == symbol.range {
			node_uri := common.create_uri(v.node.pos.file, ast_context.allocator)
			range := common.get_token_range(v.node^, ast_context.file.src)

			if !include_declaration && v.symbol.range == range && strings.equal_fold(node_uri.uri, symbol.uri) {
				// This is the declaration and so we skip it
				continue
			}

			//We don't have to have the `.` with, otherwise it renames the dot.
			if _, ok := v.node.derived.(^ast.Implicit_Selector_Expr); ok {
				range.start.character += 1
			}

			location := common.Location {
				range = range,
				uri   = strings.clone(node_uri.uri, ast_context.allocator),
			}

			append(&locations, location)
		}
	}

	if .Local in symbol.flags || current_file_only {
		reference_resolved_cache_store(cache_key, locations[:])
		return locations[:], true
	}

	candidate_paths := make(map[string]struct{}, 0, context.temp_allocator)
	if !is_builtin_pkg(symbol.pkg) {
		collect_reference_package_files(symbol.pkg, &candidate_paths)
	}

	when !ODIN_TEST {
		collect_workspace_reference_candidates(symbol.pkg, &candidate_paths)
	}

	live_candidate_paths := make(map[string]string, 0, context.temp_allocator)
	for fullpath in candidate_paths {
		_, document_path, open := reference_open_document_source(fullpath)
		if !open do continue
		normalized_path := reference_normalize_path(fullpath)
		live_candidate_paths[strings.clone(normalized_path, context.temp_allocator)] = strings.clone(document_path, context.temp_allocator)
	}

	seen_candidate_paths := make(map[string]struct{}, 0, context.temp_allocator)
	document_path := reference_normalize_path(document.fullpath)
	for fullpath in candidate_paths {
		normalized_path := reference_normalize_path(fullpath)
		if strings.equal_fold(normalized_path, document_path) || normalized_path in seen_candidate_paths do continue
		seen_candidate_paths[strings.clone(normalized_path, context.temp_allocator)] = {}

		candidate_path := fullpath
		if live_path, open := live_candidate_paths[normalized_path]; open {
			candidate_path = live_path
		}
		append(&fullpaths, strings.clone(candidate_path, context.temp_allocator))
	}

	reset_ast_context(ast_context)


	arena: runtime.Arena
	_ = runtime.arena_init(&arena, mem.Megabyte * 40, context.temp_allocator)
	defer runtime.arena_destroy(&arena)
	previous_allocator := context.allocator
	defer context.allocator = previous_allocator

	for fullpath in slice.unique(fullpaths[:]) {
		runtime.arena_free_all(&arena)
		context.allocator = runtime.arena_allocator(&arena)

		fullpath := fullpath
		when ODIN_OS == .Windows {
			path := common.get_case_sensitive_path(fullpath, context.temp_allocator)
			fullpath, _ = filepath.replace_separators(path, '/', context.allocator)
		}
		dir := filepath.dir(fullpath)
		base := filepath.base(dir)

		data: []u8
		if source, _, open := reference_open_document_source(fullpath); open {
			data = transmute([]u8)source
		} else {
			disk_data, err := os.read_entire_file(fullpath, context.allocator)
			if err != nil {
				log.errorf("failed to read entire file for indexing %v: %v", fullpath, err)
				continue
			}
			data = disk_data
		}
		if common.has_ignore_file_tag(string(data)) || file_when_tags_exclude(string(data), fullpath) {
			continue
		}

		if target_name != "" && !strings.contains(string(data), target_name) {
			continue
		}

		p := parser.Parser {
			flags = {.Optional_Semicolons},
		}
		if !is_ols_builtin_file(fullpath) {
			p.err = log_error_handler
			p.warn = log_warning_handler
		}

		pkg := new(ast.Package)
		pkg.kind = .Normal
		pkg.fullpath = fullpath
		pkg.name = base

		if base == "runtime" {
			pkg.kind = .Runtime
		}

		file := ast.File {
			fullpath = fullpath,
			src      = string(data),
			pkg      = pkg,
		}

		when ODIN_TEST {
			reference_resolution_test_parse_count += 1
		}
		ok := parse_file(&p, &file)

		if !ok || (!is_ols_builtin_file(fullpath) &&
		   (file.syntax_error_count > 0 || file.pkg_decl == nil)) {
			if !is_ols_builtin_file(fullpath) {
				log.warnf("skipping reference search in %v after parse failure", fullpath)
			}
			continue
		}

		uri := common.create_uri(fullpath, context.allocator)

		document := Document {
			ast = file,
		}

		document.uri = uri
		document.text = transmute([]u8)file.src
		document.used_text = len(file.src)

		document_setup(&document)

		parse_imports(&document, &common.config)

		in_pkg := false
		for pkg in document.imports {
			if strings.equal_fold(pkg.name, symbol.pkg) {
				in_pkg = true
				continue
			}
		}

		if in_pkg || strings.equal_fold(symbol.pkg, document.package_name) {
			symbols_and_nodes := resolve_entire_file_for_references(&document, context.allocator, resolve_flag, target_name)
			for k, v in symbols_and_nodes {
				if strings.equal_fold(v.symbol.uri, symbol.uri) && v.symbol.range == symbol.range {
					node_uri := common.create_uri(v.node.pos.file, ast_context.allocator)
					range := common.get_token_range(v.node^, string(document.text))

					if !include_declaration &&
					   v.symbol.range == range &&
					   strings.equal_fold(node_uri.uri, symbol.uri) {
						// This is the declaration and so we skip it
						continue
					}
					//We don't have to have the `.` with, otherwise it renames the dot.
					if _, ok := v.node.derived.(^ast.Implicit_Selector_Expr); ok {
						range.start.character += 1
					}
					location := common.Location {
						range = range,
						uri   = strings.clone(node_uri.uri, ast_context.allocator),
					}
					append(&locations, location)
				}
			}
		}
	}

	reference_resolved_cache_store(cache_key, locations[:])
	return locations[:], true
}

get_references :: proc(
	document: ^Document,
	position: common.Position,
	current_file_only := false,
	include_declaration := true,
) -> (
	[]common.Location,
	bool,
) {
	ast_context := make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
		context.temp_allocator,
	)

	position_context, ok := get_document_position_context(document, position, .Hover)
	if !ok {
		log.warn("Failed to get position context")
		return {}, false
	}

	ast_context.position_hint = position_context.hint
	ast_context.current_package = ast_context.document_package

	get_globals(document.ast, &ast_context)
	get_locals(&ast_context, &position_context)

	locations, ok2 := resolve_references(
		document,
		&ast_context,
		&position_context,
		current_file_only,
		include_declaration = include_declaration,
	)

	temp_locations := make([dynamic]common.Location, 0, context.temp_allocator)

	for location in locations {
		temp_location := common.Location {
			range = location.range,
			uri   = strings.clone(location.uri, context.temp_allocator),
		}
		append(&temp_locations, temp_location)
	}

	return temp_locations[:], ok2
}
