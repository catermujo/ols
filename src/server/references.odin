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

reference_dir_blacklist :: []string{"node_modules", ".git"}

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
	forward_dir, _ := filepath.replace_separators(file_dir, '/', context.temp_allocator)
	forward_pkg, _ := filepath.replace_separators(pkg_name, '/', context.temp_allocator)

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
	if !is_builtin_pkg(symbol.pkg) {
		collect_reference_package_files(symbol.pkg, &candidate_paths)
	}

	when !ODIN_TEST {
		scan_arena: runtime.Arena
		_ = runtime.arena_init(&scan_arena, mem.Megabyte * 2, runtime.default_allocator())
		defer runtime.arena_destroy(&scan_arena)

		for workspace in common.config.workspace_folders {
			uri, _ := common.parse_uri(workspace.uri, context.temp_allocator)
			w := os.walker_create(uri.path)
			defer os.walker_destroy(&w)
			for info in os.walker_walk(&w) {
				if info.type == .Directory {
					if reference_should_skip_dir(info.fullpath) {
						os.walker_skip_dir(&w)
					}
					continue
				}

				if info.fullpath == "" {
					continue
				}

				if strings.has_suffix(info.name, ".odin") {
					slash_path, _ := filepath.replace_separators(info.fullpath, '/', context.temp_allocator)
					if strings.equal_fold(slash_path, document.fullpath) {
						continue
					}

					if _, exists := candidate_paths[slash_path]; exists {
						continue
					}

					runtime.arena_free_all(&scan_arena)
					scan_allocator := runtime.arena_allocator(&scan_arena)
					data, err := os.read_entire_file(info.fullpath, scan_allocator)
					if err != nil {
						log.errorf("failed to read entire file for references %v: %v", info.fullpath, err)
						continue
					}

					if target_name != "" && !strings.contains(string(data), target_name) {
						continue
					}

					if source_may_reference_package(info.fullpath, symbol.pkg, string(data)) {
						add_reference_candidate_path(&candidate_paths, info.fullpath)
					}
				}
			}
		}
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
