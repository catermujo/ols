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

import "src:common"

ReferenceImportCache :: struct {
	file_imports:         map[string][dynamic]string,
	package_files:        map[string][dynamic]string,
	importers_by_package: map[string][dynamic]string,
	initialized:          bool,
}

@(thread_local)
reference_import_cache: ReferenceImportCache

reference_dir_blacklist :: []string{"node_modules", ".git"}

reference_cache_allocator :: proc() -> mem.Allocator {
	return runtime.default_allocator()
}

reference_import_cache_reset :: proc() {
	for _, imports in reference_import_cache.file_imports {
		for import_path in imports {
			delete(import_path)
		}
		delete(imports)
	}
	clear(&reference_import_cache.file_imports)

	for _, files in reference_import_cache.package_files {
		for fullpath in files {
			delete(fullpath)
		}
		delete(files)
	}
	clear(&reference_import_cache.package_files)

	for _, files in reference_import_cache.importers_by_package {
		for fullpath in files {
			delete(fullpath)
		}
		delete(files)
	}
	clear(&reference_import_cache.importers_by_package)

	reference_import_cache.initialized = false
}

reference_import_cache_ensure_maps :: proc() {
	allocator := reference_cache_allocator()

	if reference_import_cache.file_imports == nil {
		reference_import_cache.file_imports = make(map[string][dynamic]string, 512, allocator)
	}

	if reference_import_cache.package_files == nil {
		reference_import_cache.package_files = make(map[string][dynamic]string, 256, allocator)
	}

	if reference_import_cache.importers_by_package == nil {
		reference_import_cache.importers_by_package = make(map[string][dynamic]string, 256, allocator)
	}
}

reference_path_is_excluded :: proc(fullpath: string) -> bool {
	forward_path, _ := filepath.replace_separators(fullpath, '/', context.temp_allocator)
	lower_path := strings.to_lower(forward_path)

	for exclude_path in common.config.profile.exclude_path {
		exclude_forward, _ := filepath.replace_separators(exclude_path, '/', context.temp_allocator)
		lower_exclude := strings.to_lower(exclude_forward)

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

reference_append_unique_string :: proc(items: ^[dynamic]string, value: string) {
	if slice.contains(items[:], value) {
		return
	}

	append(items, strings.clone(value, reference_cache_allocator()))
}

reference_remove_string :: proc(items: ^[dynamic]string, value: string) -> bool {
	for i := len(items^) - 1; i >= 0; i -= 1 {
		if items[i] != value {
			continue
		}

		delete(items[i])
		ordered_remove(items, i)
		return true
	}

	return false
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

reference_resolve_import_path :: proc(file_dir, import_path: string) -> (string, bool) {
	if import_path == "" {
		return "", false
	}

	if i := strings.index(import_path, ":"); i != -1 && i > 0 && i < len(import_path) - 1 {
		collection := import_path[:i]
		p := import_path[i + 1:]

		dir, ok := common.config.collections[collection]
		if !ok {
			return "", false
		}

		full := path.join(elems = {dir, p}, allocator = context.temp_allocator)
		full = path.clean(full, context.temp_allocator)
		forward_full, _ := filepath.replace_separators(full, '/', context.temp_allocator)
		return forward_full, true
	}

	full := path.join(elems = {file_dir, import_path}, allocator = context.temp_allocator)
	full = path.clean(full, context.temp_allocator)
	forward_full, _ := filepath.replace_separators(full, '/', context.temp_allocator)
	return forward_full, true
}

reference_import_path_matches_package :: proc(file_dir, pkg_name, import_path: string) -> bool {
	fullpath, ok := reference_resolve_import_path(file_dir, import_path)
	if !ok {
		return false
	}

	return strings.equal_fold(fullpath, pkg_name)
}

reference_collect_source_import_paths :: proc(fullpath, src: string, paths: ^map[string]struct{}) {
	file_dir := filepath.dir(fullpath)
	forward_dir, _ := filepath.replace_separators(file_dir, '/', context.temp_allocator)

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

		import_path, ok := reference_resolve_import_path(forward_dir, src[i + 1:end])
		if ok {
			if _, exists := paths[import_path]; !exists {
				paths[strings.clone(import_path, context.temp_allocator)] = {}
			}
		}

		i = end
	}
}

source_may_reference_package :: proc(fullpath, pkg_name, src: string) -> bool {
	if is_builtin_pkg(pkg_name) {
		return true
	}

	file_dir := filepath.dir(fullpath)
	forward_dir, _ := filepath.replace_separators(file_dir, '/', context.temp_allocator)
	forward_pkg, _ := filepath.replace_separators(pkg_name, '/', context.temp_allocator)

	if strings.equal_fold(forward_dir, forward_pkg) {
		return true
	}

	import_paths := make(map[string]struct{}, 0, context.temp_allocator)
	reference_collect_source_import_paths(fullpath, src, &import_paths)
	for import_path in import_paths {
		if strings.equal_fold(import_path, forward_pkg) {
			return true
		}
	}

	return false
}

reference_import_cache_store_file :: proc(fullpath: string, import_paths: []string) {
	reference_import_cache_ensure_maps()

	forward_path, _ := filepath.replace_separators(fullpath, '/', context.temp_allocator)
	reference_import_cache_remove_file(forward_path)

	if reference_path_is_excluded(forward_path) {
		return
	}

	pkg_dir := filepath.dir(forward_path)
	if reference_should_skip_dir(pkg_dir) {
		return
	}

	allocator := reference_cache_allocator()

	package_files := &reference_import_cache.package_files[pkg_dir]
	if package_files == nil {
		reference_import_cache.package_files[strings.clone(pkg_dir, allocator)] = make([dynamic]string, 0, 8, allocator)
		package_files = &reference_import_cache.package_files[pkg_dir]
	}
	reference_append_unique_string(package_files, forward_path)

	imports := make([dynamic]string, 0, len(import_paths), allocator)
	for import_path in import_paths {
		reference_append_unique_string(&imports, import_path)
		importers := &reference_import_cache.importers_by_package[import_path]
		if importers == nil {
			reference_import_cache.importers_by_package[strings.clone(import_path, allocator)] = make([dynamic]string, 0, 8, allocator)
			importers = &reference_import_cache.importers_by_package[import_path]
		}
		reference_append_unique_string(importers, forward_path)
	}

	reference_import_cache.file_imports[strings.clone(forward_path, allocator)] = imports
}

reference_import_cache_update_file :: proc(fullpath, src: string) {
	if !reference_import_cache.initialized {
		return
	}

	import_paths := make(map[string]struct{}, 0, context.temp_allocator)
	reference_collect_source_import_paths(fullpath, src, &import_paths)

	import_list := make([dynamic]string, 0, len(import_paths), context.temp_allocator)
	for import_path in import_paths {
		append(&import_list, import_path)
	}

	reference_import_cache_store_file(fullpath, import_list[:])
}

reference_import_cache_remove_file :: proc(fullpath: string) {
	forward_path, _ := filepath.replace_separators(fullpath, '/', context.temp_allocator)
	pkg_dir := filepath.dir(forward_path)

	if imports, ok := reference_import_cache.file_imports[forward_path]; ok {
		for import_path in imports {
			importers := &reference_import_cache.importers_by_package[import_path]
			if importers == nil {
				continue
			}

			if reference_remove_string(importers, forward_path) && len(importers^) == 0 {
				delete(importers^)
				delete_key(&reference_import_cache.importers_by_package, import_path)
			}
		}

		delete(imports)
		delete_key(&reference_import_cache.file_imports, forward_path)
	}

	package_files := &reference_import_cache.package_files[pkg_dir]
	if package_files != nil {
		if reference_remove_string(package_files, forward_path) && len(package_files^) == 0 {
			delete(package_files^)
			delete_key(&reference_import_cache.package_files, pkg_dir)
		}
	}
}

reference_collect_known_package_dirs :: proc(paths: ^map[string]struct{}) {
	for collection, aliases in build_cache.pkg_aliases {
		root, ok := common.config.collections[collection]
		if !ok {
			continue
		}

		for alias in aliases {
			full := path.join(elems = {root, alias}, allocator = context.temp_allocator)
			full = path.clean(full, context.temp_allocator)
			if reference_should_skip_dir(full) {
				continue
			}
			add_reference_candidate_path(paths, full)
		}
	}

	for pkg_name, _ in indexer.index.collection.packages {
		if is_builtin_pkg(pkg_name) || reference_should_skip_dir(pkg_name) {
			continue
		}
		add_reference_candidate_path(paths, pkg_name)
	}
}

reference_import_cache_ensure_initialized :: proc() {
	if reference_import_cache.initialized {
		return
	}

	reference_import_cache_reset()
	reference_import_cache_ensure_maps()

	package_dirs := make(map[string]struct{}, 0, context.temp_allocator)
	reference_collect_known_package_dirs(&package_dirs)

	scan_arena: runtime.Arena
	_ = runtime.arena_init(&scan_arena, mem.Megabyte * 2, runtime.default_allocator())
	defer runtime.arena_destroy(&scan_arena)

	for pkg_dir in package_dirs {
		matches, err := filepath.glob(fmt.tprintf("%s/*.odin", pkg_dir), context.temp_allocator)
		if err != nil && err != .Not_Exist {
			continue
		}

		for fullpath in matches {
			runtime.arena_free_all(&scan_arena)
			scan_allocator := runtime.arena_allocator(&scan_arena)
			data, err := os.read_entire_file(fullpath, scan_allocator)
			if err != nil {
				log.errorf("failed to read entire file for reference import cache %v: %v", fullpath, err)
				continue
			}

			import_paths := make(map[string]struct{}, 0, context.temp_allocator)
			reference_collect_source_import_paths(fullpath, string(data), &import_paths)

			import_list := make([dynamic]string, 0, len(import_paths), context.temp_allocator)
			for import_path in import_paths {
				append(&import_list, import_path)
			}

			reference_import_cache_store_file(fullpath, import_list[:])
		}
	}

	reference_import_cache.initialized = true
}

collect_reference_cached_package_files :: proc(pkg_name: string, paths: ^map[string]struct{}) -> bool {
	files, ok := reference_import_cache.package_files[pkg_name]
	if !ok {
		return false
	}

	for fullpath in files {
		add_reference_candidate_path(paths, fullpath)
	}

	return len(files) > 0
}

collect_reference_cached_importers :: proc(pkg_name: string, paths: ^map[string]struct{}) {
	files, ok := reference_import_cache.importers_by_package[pkg_name]
	if !ok {
		return
	}

	for fullpath in files {
		add_reference_candidate_path(paths, fullpath)
	}
}

collect_reference_all_cached_files :: proc(paths: ^map[string]struct{}) {
	for _, files in reference_import_cache.package_files {
		for fullpath in files {
			add_reference_candidate_path(paths, fullpath)
		}
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
	ok = false
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
	locations := make([dynamic]common.Location, 0, ast_context.allocator)
	fullpaths := make([dynamic]string, 0, ast_context.allocator)

	symbol, resolve_flag, ok := prepare_references(document, ast_context, position_context)
	if !ok {
		return {}, true
	}

	target_name := get_target_name(position_context, resolve_flag)
	symbols_and_nodes := resolve_entire_file(document, resolve_flag, ast_context.allocator, target_name)

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
		return locations[:], true
	}

	candidate_paths := make(map[string]struct{}, 0, context.temp_allocator)
	reference_import_cache_ensure_initialized()

	if is_builtin_pkg(symbol.pkg) {
		collect_reference_all_cached_files(&candidate_paths)
	} else {
		if !collect_reference_cached_package_files(symbol.pkg, &candidate_paths) {
			collect_reference_package_files(symbol.pkg, &candidate_paths)
		}
		collect_reference_cached_importers(symbol.pkg, &candidate_paths)
	}

	for fullpath in candidate_paths {
		if !strings.equal_fold(fullpath, document.fullpath) {
			append(&fullpaths, strings.clone(fullpath, ast_context.allocator))
		}
	}

	reset_ast_context(ast_context)


	arena: runtime.Arena

	_ = runtime.arena_init(&arena, mem.Megabyte * 40, runtime.default_allocator())

	defer runtime.arena_destroy(&arena)

	context.allocator = runtime.arena_allocator(&arena)

	paths := slice.unique(fullpaths[:])

	for fullpath in paths {
		defer free_all(context.allocator)

		fullpath := fullpath
		when ODIN_OS == .Windows {
			path := common.get_case_sensitive_path(fullpath, context.temp_allocator)
			fullpath, _ = filepath.replace_separators(path, '/', context.allocator)
		}
		dir := filepath.dir(fullpath)
		base := filepath.base(dir)

		data, err := os.read_entire_file(fullpath, context.allocator)

		if err != nil {
			log.errorf("failed to read entire file for indexing %v: %v", fullpath, err)
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

		ok := parser.parse_file(&p, &file)

		if !ok {
			if !is_ols_builtin_file(fullpath) {
				log.errorf("error in parse file for indexing %v", fullpath)
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
			if pkg.name == symbol.pkg {
				in_pkg = true
				continue
			}
		}

		if in_pkg || symbol.pkg == document.package_name {
			symbols_and_nodes := resolve_entire_file(&document, resolve_flag, context.allocator, target_name)
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

	get_globals(document.ast, &ast_context)

	ast_context.current_package = ast_context.document_package

	if position_context.function != nil {
		get_locals(document.ast, position_context.function, &ast_context, &position_context)
	}

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
