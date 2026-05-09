package server

import "core:fmt"
import "core:log"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "src:common"

get_all_package_file_locations :: proc(
	document: ^Document,
	import_decl: ^ast.Import_Decl,
	locations: ^[dynamic]common.Location,
) -> bool {
	path := ""

	for imp in document.imports {
		if imp.original == import_decl.fullpath {
			path = imp.name
		}
	}

	matches, err := filepath.glob(fmt.tprintf("%v/*.odin", path), context.temp_allocator)

	for match in matches {
		uri := common.create_uri(match, context.temp_allocator)
		location := common.Location {
			uri = uri.uri,
		}
		append(locations, location)
	}

	return true
}

append_unique_string :: proc(values: ^[dynamic]string, value: string) {
	if slice.contains(values[:], value) {
		return
	}
	append(values, strings.clone(value, context.temp_allocator))
}

append_package_files :: proc(paths: ^[dynamic]string, pkg_path: string) {
	if pkg_path == "" {
		return
	}

	matches, err := filepath.glob(fmt.tprintf("%v/*.odin", pkg_path), context.temp_allocator)
	if err != nil && err != .Not_Exist {
		return
	}

	for match in matches {
		append_unique_string(paths, match)
	}
}

collect_implicit_definition_candidate_files :: proc(document: ^Document) -> []string {
	paths := make([dynamic]string, 0, context.temp_allocator)

	append_unique_string(&paths, document.fullpath)
	append_package_files(&paths, document.package_name)

	for imp in document.imports {
		append_package_files(&paths, imp.name)
	}

	return paths[:]
}

find_enum_member_definition_fallback :: proc(
	document: ^Document,
	member_name: string,
) -> (
	common.Location,
	bool,
) {
	if member_name == "" {
		return {}, false
	}

	candidate_paths := collect_implicit_definition_candidate_files(document)
	results := make([dynamic]common.Location, 0, context.temp_allocator)

	for fullpath in candidate_paths {
		data, err := os.read_entire_file(fullpath, context.temp_allocator)
		if err != nil {
			continue
		}

		p := parser.Parser {
			flags = {.Optional_Semicolons},
		}

		pkg := new(ast.Package)
		pkg.kind = .Normal
		pkg.fullpath = fullpath

		file := ast.File {
			fullpath = fullpath,
			src      = string(data),
			pkg      = pkg,
		}

		if !parser.parse_file(&p, &file) {
			continue
		}

		uri := common.create_uri(fullpath, context.temp_allocator)

		for decl in file.decls {
			value_decl, ok := decl.derived.(^ast.Value_Decl)
			if !ok {
				continue
			}

			for value in value_decl.values {
				enum_type, ok := value.derived.(^ast.Enum_Type)
				if !ok {
					continue
				}

				for field in enum_type.fields {
					if ident, ok := field.derived.(^ast.Ident); ok {
						if ident.name != member_name {
							continue
						}
						append(&results, common.Location {
							uri   = strings.clone(uri.uri, context.temp_allocator),
							range = common.get_token_range(ident, file.src),
						})
					} else if field_value, ok := field.derived.(^ast.Field_Value); ok {
						ident, ok := field_value.field.derived.(^ast.Ident)
						if !ok || ident.name != member_name {
							continue
						}
						append(&results, common.Location {
							uri   = strings.clone(uri.uri, context.temp_allocator),
							range = common.get_token_range(ident, file.src),
						})
					}
				}
			}
		}
	}

	if len(results) == 0 {
		return {}, false
	}

	return results[0], true
}

get_definition_location :: proc(document: ^Document, position: common.Position, config: ^common.Config) -> ([]common.Location, bool) {
	locations := make([dynamic]common.Location, context.temp_allocator)

	location: common.Location


	uri: string

	position_context, ok := get_document_position_context(document, position, .Definition)

	if !ok {
		log.warn("Failed to get position context")
		return {}, false
	}

	ast_context := make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
	)

	ast_context.position_hint = position_context.hint

	get_globals(document.ast, &ast_context)

	if position_context.function != nil {
		get_locals(document.ast, position_context.function, &ast_context, &position_context)
	}

	if position_context.import_stmt != nil {
		if get_all_package_file_locations(document, position_context.import_stmt, &locations) {
			return locations[:], true
		}
	} else if position_context.implicit_selector_expr != nil {
		if resolved, ok := resolve_location_implicit_selector(
			&ast_context,
			&position_context,
			position_context.implicit_selector_expr,
		); ok {
			location.range = resolved.range
			uri = resolved.uri
		} else {
			if fallback_location, ok := find_enum_member_definition_fallback(
				document,
				position_context.implicit_selector_expr.field.name,
			); ok {
				append(&locations, fallback_location)
				return locations[:], true
			}
			return {}, false
		}
	} else if position_context.selector_expr != nil {
		//if the base selector is the client wants to go to.
		if position_in_node(position_context.selector, position_context.position) &&
		   position_context.identifier != nil {
			ident := position_context.identifier.derived.(^ast.Ident)
			if resolved, ok := resolve_location_identifier(&ast_context, ident^); ok {
				if config.enable_definition_skip_alias {
					if resolved_alias, ok := resolve_alias_symbol_target(&ast_context, resolved, document.fullpath); ok {
						resolved = resolved_alias
					}
				}
				location.range = resolved.range

				if resolved.uri == "" {
					location.uri = document.uri.uri
				} else {
					location.uri = resolved.uri
				}

				append(&locations, location)

				return locations[:], true
			} else {
				return {}, false
			}
		}

		if resolved, ok := resolve_location_selector(&ast_context, position_context.selector_expr); ok {
			if config.enable_overload_resolution {
				resolved = try_resolve_proc_group_overload(
					&ast_context,
					&position_context,
					resolved,
					position_context.selector_expr,
				)
			}
			location.range = resolved.range
			uri = resolved.uri
		} else {
			return {}, false
		}
	} else if position_context.field_value != nil &&
	   !is_expr_basic_lit(position_context.field_value.field) &&
	   position_in_node(position_context.field_value.field, position_context.position) {
		if position_context.comp_lit != nil {
			if resolved, ok := resolve_location_comp_lit_field(&ast_context, &position_context); ok {
				location.range = resolved.range
				uri = resolved.uri
			} else {
				return {}, false
			}
		} else if position_context.call != nil {
			if resolved, ok := resolve_location_proc_param_name(&ast_context, &position_context); ok {
				location.range = resolved.range
				uri = resolved.uri
			} else {
				return {}, false
			}
		}
	} else if position_context.identifier != nil {
		if resolved, ok := resolve_location_identifier(
			&ast_context,
			position_context.identifier.derived.(^ast.Ident)^,
		); ok {
			if config.enable_definition_skip_alias {
				if resolved_alias, ok := resolve_alias_symbol_target(&ast_context, resolved, document.fullpath); ok {
					resolved = resolved_alias
				}
			}
			if config.enable_overload_resolution {
				resolved = try_resolve_proc_group_overload(&ast_context, &position_context, resolved)
			}
			if v, ok := resolved.value.(SymbolAggregateValue); ok {
				for symbol in v.symbols {
					append(&locations, common.Location{range = symbol.range, uri = symbol.uri})
				}
			}
			location.range = resolved.range
			uri = resolved.uri
		} else {
			return {}, false
		}
	} else {
		return {}, false
	}

	//if the symbol is generated by the ast we don't set the uri.
	if uri == "" {
		location.uri = document.uri.uri
	} else {
		location.uri = uri
	}

	append(&locations, location)

	return locations[:], true
}


try_resolve_proc_group_overload :: proc(
	ast_context: ^AstContext,
	position_context: ^DocumentPositionContext,
	symbol: Symbol,
	selector_expr: ^ast.Node = nil,
) -> Symbol {
	if position_context.call == nil {
		return symbol
	}

	call, is_call := position_context.call.derived.(^ast.Call_Expr)
	if !is_call {
		return symbol
	}

	if position_in_exprs(call.args, position_context.position) {
		return symbol
	}

	// For selector expressions, we need to look up the full symbol to check if it's a proc group
	full_symbol := symbol
	if result, ok := get_full_symbol_from_selector(ast_context, selector_expr, symbol); ok {
		full_symbol = result
	} else if result, ok := get_full_symbol_from_identifier(ast_context, position_context, symbol); ok {
		full_symbol = result
	}

	proc_group_value, is_proc_group := full_symbol.value.(SymbolProcedureGroupValue)
	if !is_proc_group {
		return symbol
	}

	old_call := ast_context.call
	ast_context.call = call
	defer {
		ast_context.call = old_call
	}

	if resolved, ok := resolve_function_overload(ast_context, proc_group_value.group.derived.(^ast.Proc_Group)); ok {
		if resolved.name != "" {
			if global, ok := ast_context.globals[resolved.name]; ok {
				resolved.range = common.get_token_range(global.name_expr, ast_context.file.src)
				resolved.uri = common.create_uri(global.name_expr.pos.file, ast_context.allocator).uri
			} else if indexed_symbol, ok := lookup(resolved.name, resolved.pkg, ast_context.fullpath); ok {
				resolved.range = indexed_symbol.range
				resolved.uri = indexed_symbol.uri
			}
		}
		return resolved
	}

	return symbol
}

get_full_symbol_from_selector :: proc(
	ast_context: ^AstContext,
	selector_expr: ^ast.Node,
	symbol: Symbol,
) -> (
	full_symbol: Symbol,
	ok: bool,
) {
	if selector_expr == nil do return

	selector := selector_expr.derived.(^ast.Selector_Expr) or_return

	_, is_pkg := symbol.value.(SymbolPackageValue)
	if !is_pkg && symbol.value != nil do return

	if selector.field == nil do return

	ident := selector.field.derived.(^ast.Ident) or_return

	return lookup(ident.name, symbol.pkg, ast_context.fullpath);
}

get_full_symbol_from_identifier :: proc(
	ast_context: ^AstContext,
	position_context: ^DocumentPositionContext,
	symbol: Symbol,
) -> (
	full_symbol: Symbol,
	ok: bool,
) {
	if position_context.identifier == nil || symbol.value != nil do return

	// For identifiers (non-selector), the symbol from resolve_location_identifier may not have
	// value set (e.g., for globals). We need to do a lookup to get the full symbol.
	ident := position_context.identifier.derived.(^ast.Ident) or_return

	pkg := symbol.pkg if symbol.pkg != "" else ast_context.document_package

	if pkg_symbol, ok := lookup(ident.name, pkg, ast_context.fullpath); ok {
		return pkg_symbol, true
	}

	// If lookup fails (e.g., in tests without full indexing), try checking if it's a proc group

	global := ast_context.globals[ident.name] or_return
	if proc_group, is_proc_group := global.expr.derived.(^ast.Proc_Group); is_proc_group {
		full_symbol = symbol
		full_symbol.value = SymbolProcedureGroupValue {
			group = global.expr,
		}
		return full_symbol, true
	}

	return Symbol{}, false
}
