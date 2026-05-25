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
		if file_has_ignore_file_tag(match) {
			continue
		}

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
		if file_has_ignore_file_tag(match) {
			continue
		}

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

		if source_has_ignore_file_tag(file.src) {
			continue
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

count_lines :: proc(text: []u8) -> int {
	if len(text) == 0 {
		return 1
	}

	lines := 0
	for c in text {
		if c == '\n' {
			lines += 1
		}
	}

	last := text[len(text) - 1]
	if last != '\n' && last != '\r' {
		lines += 1
	}

	if lines <= 0 {
		lines = 1
	}

	return lines
}

get_line_character_limit :: proc(text: []u8, target_line: int) -> (int, bool) {
	if target_line < 0 {
		return 0, false
	}

	if len(text) == 0 {
		return 0, target_line == 0
	}

	line := 0
	start := 0
	i := 0

	for i < len(text) {
		c := text[i]
		if c == '\n' || c == '\r' {
			if line == target_line {
				return common.get_character_offset_u8_to_u16(i - start, text[start:i]), true
			}

			if c == '\r' && i + 1 < len(text) && text[i + 1] == '\n' {
				i += 1
			}

			line += 1
			i += 1
			start = i
			continue
		}

		i += 1
	}

	if line == target_line {
		return common.get_character_offset_u8_to_u16(len(text) - start, text[start:]), true
	}

	return 0, false
}

sanitize_location_ranges :: proc(document: ^Document, locations: ^[dynamic]common.Location) {
	for i in 0 ..< len(locations^) {
		loc := &locations[i]

		fullpath := document.fullpath
		if loc.uri != "" {
			fullpath = common.uri_to_path(loc.uri, context.temp_allocator)
		}

		lines := 1
		has_line_info := false
		line_text: []u8
		if fullpath == document.fullpath {
			line_text = document.text[:document.used_text]
			lines = count_lines(line_text)
			has_line_info = true
		} else if fullpath != "" {
			if data, err := os.read_entire_file(fullpath, context.temp_allocator); err == nil {
				line_text = data
				lines = count_lines(line_text)
				has_line_info = true
			}
		}

		max_line := 0
		if has_line_info {
			max_line = max(lines - 1, 0)
		} else if strings.starts_with(loc.uri, "file://test/") {
			continue
		}

		if loc.range.start.line < 0 {
			loc.range.start.line = 0
		} else if loc.range.start.line > max_line {
			loc.range.start.line = max_line
		}

		if loc.range.end.line < 0 {
			loc.range.end.line = 0
		} else if loc.range.end.line > max_line {
			loc.range.end.line = max_line
		}

		if loc.range.end.line < loc.range.start.line {
			loc.range.end.line = loc.range.start.line
		}
		if loc.range.start.character < 0 {
			loc.range.start.character = 0
		}
		if loc.range.end.character < 0 {
			loc.range.end.character = 0
		}

		if has_line_info {
			if max_start_char, ok := get_line_character_limit(line_text, loc.range.start.line); ok {
				loc.range.start.character = clamp(loc.range.start.character, 0, max_start_char)
			}
			if max_end_char, ok := get_line_character_limit(line_text, loc.range.end.line); ok {
				loc.range.end.character = clamp(loc.range.end.character, 0, max_end_char)
			}
		}

		if loc.range.end.line == loc.range.start.line && loc.range.end.character < loc.range.start.character {
			loc.range.end.character = loc.range.start.character
		}
	}
}

is_skip_alias_candidate :: proc(ast_context: ^AstContext, symbol: Symbol) -> bool {
	if symbol.name == "" || symbol.pkg == "" {
		return false
	}
	if symbol.pkg != ast_context.document_package {
		return false
	}
	global, ok := ast_context.globals[symbol.name]
	if !ok || global.expr == nil {
		return false
	}
	#partial switch v in global.expr.derived {
	case ^ast.Ident, ^ast.Selector_Expr:
		return true
	}
	return false
}

symbol_has_useful_location :: proc(symbol: Symbol) -> bool {
	if symbol.uri != "" {
		return true
	}

	return symbol.range.start.line > 0 ||
		symbol.range.start.character > 0 ||
		symbol.range.end.line > 0 ||
		symbol.range.end.character > 0
}

is_config_backed_symbol :: proc(symbol: Symbol, file: string) -> bool {
	if symbol.name == "" || symbol.pkg == "" {
		return false
	}

	candidate, lookup_ok := lookup(symbol.name, symbol.pkg, file)
	if !lookup_ok {
		return false
	}

	generic, generic_ok := candidate.value.(SymbolGenericValue)
	if !generic_ok || generic.expr == nil {
		return false
	}

	if call_expr, call_ok := generic.expr.derived.(^ast.Call_Expr); call_ok {
		if directive, directive_ok := call_expr.expr.derived.(^ast.Basic_Directive); directive_ok {
			return directive.name == "config"
		}
	}

	if directive, directive_ok := generic.expr.derived.(^ast.Basic_Directive); directive_ok {
		return directive.name == "config"
	}

	return false
}

is_config_selector_alias_global :: proc(
	ast_context: ^AstContext,
	symbol: Symbol,
	file: string,
) -> bool {
	if symbol.name == "" || symbol.pkg != ast_context.document_package {
		return false
	}

	global, global_ok := ast_context.globals[symbol.name]
	if !global_ok || global.expr == nil {
		return false
	}

	selector, selector_ok := global.expr.derived.(^ast.Selector_Expr)
	if !selector_ok || selector.expr == nil || selector.field == nil {
		return false
	}

	base_ident, base_ok := selector.expr.derived.(^ast.Ident)
	field_ident, field_ok := selector.field.derived.(^ast.Ident)
	if !base_ok || !field_ok {
		return false
	}

	target_pkg := ""
	for imp in ast_context.imports {
		if imp.base == base_ident.name {
			target_pkg = imp.name
			break
		}
	}
	if target_pkg == "" {
		return false
	}

	target_symbol, target_ok := lookup(field_ident.name, target_pkg, file)
	if !target_ok {
		return false
	}

	return is_config_backed_symbol(target_symbol, file)
}

resolve_definition_skip_alias_target :: proc(
	ast_context: ^AstContext,
	symbol: Symbol,
	file: string,
) -> (
	Symbol,
	bool,
) {
	result := symbol
	pending_alias := is_skip_alias_candidate(ast_context, result)

	for _ in 0 ..< 8 {
		changed := false

		if generic, ok := result.value.(SymbolGenericValue); ok && generic.expr != nil {
			if resolved_location, ok := resolve_location_type_expression(ast_context, generic.expr); ok {
				if symbol_has_useful_location(resolved_location) {
					if resolved_location.range != result.range ||
					   resolved_location.uri != result.uri ||
					   resolved_location.pkg != result.pkg ||
					   resolved_location.type != result.type {
						result = resolved_location
						changed = true
						pending_alias = is_skip_alias_candidate(ast_context, result)
					}
				}
			}
		}

		if resolved_alias, ok := resolve_alias_symbol_target(ast_context, result, file); ok {
			if pending_alias && is_config_selector_alias_global(ast_context, result, file) {
				// Keep local alias definition for #config-backed values.
				pending_alias = false
			} else if pending_alias && is_config_backed_symbol(resolved_alias, file) {
				// Keep local alias definition for #config-backed values.
				pending_alias = false
			} else if symbol_has_useful_location(result) && !symbol_has_useful_location(resolved_alias) {
				// Keep existing target when alias resolution degrades into a keyword-like symbol with no location.
				pending_alias = false
			} else {
				result = resolved_alias
				changed = true
				pending_alias = is_skip_alias_candidate(ast_context, result)
			}
		} else if pending_alias {
			return {}, false
		}

		if resolved_basic, ok := resolve_basic_symbol_target(ast_context, result, file); ok {
			if symbol_has_useful_location(result) && !symbol_has_useful_location(resolved_basic) {
				// Keep existing target when basic resolution drops location information.
				pending_alias = false
			} else {
				result = resolved_basic
				changed = true
				pending_alias = is_skip_alias_candidate(ast_context, result)
			}
		}

		if !changed {
			break
		}
	}

	if pending_alias {
		return {}, false
	}

	return result, true
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
			sanitize_location_ranges(document, &locations)
			return locations[:], true
		}
	} else if position_context.implicit_selector_expr != nil {
		if resolved, ok := resolve_location_implicit_selector(
			&ast_context,
			&position_context,
			position_context.implicit_selector_expr,
		); ok {
			if config.enable_definition_skip_alias {
				if skip_resolved, ok := resolve_definition_skip_alias_target(&ast_context, resolved, document.fullpath); ok {
					resolved = skip_resolved
				} else {
					return {}, false
				}
			}
			location.range = resolved.range
			uri = resolved.uri
		} else {
			if fallback_location, ok := find_enum_member_definition_fallback(
				document,
				position_context.implicit_selector_expr.field.name,
			); ok {
				append(&locations, fallback_location)
				sanitize_location_ranges(document, &locations)
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
					if skip_resolved, ok := resolve_definition_skip_alias_target(&ast_context, resolved, document.fullpath); ok {
						resolved = skip_resolved
					} else {
						return {}, false
					}
				}
				location.range = resolved.range

				if resolved.uri == "" {
					location.uri = document.uri.uri
				} else {
					location.uri = resolved.uri
				}

				append(&locations, location)
				sanitize_location_ranges(document, &locations)

				return locations[:], true
			} else {
				return {}, false
			}
		}

		if resolved, ok := resolve_location_selector(&ast_context, position_context.selector_expr); ok {
			if config.enable_definition_skip_alias {
				if skip_resolved, ok := resolve_definition_skip_alias_target(&ast_context, resolved, document.fullpath); ok {
					resolved = skip_resolved
				} else {
					return {}, false
				}
			}
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
				if config.enable_definition_skip_alias {
					if skip_resolved, ok := resolve_definition_skip_alias_target(&ast_context, resolved, document.fullpath); ok {
						resolved = skip_resolved
					} else {
						return {}, false
					}
				}
				location.range = resolved.range
				uri = resolved.uri
			} else {
				return {}, false
			}
		} else if position_context.call != nil {
			if resolved, ok := resolve_location_proc_param_name(&ast_context, &position_context); ok {
				if config.enable_definition_skip_alias {
					if skip_resolved, ok := resolve_definition_skip_alias_target(&ast_context, resolved, document.fullpath); ok {
						resolved = skip_resolved
					} else {
						return {}, false
					}
				}
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
				if skip_resolved, ok := resolve_definition_skip_alias_target(&ast_context, resolved, document.fullpath); ok {
					resolved = skip_resolved
				} else {
					return {}, false
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
	sanitize_location_ranges(document, &locations)

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
