package server

import "base:runtime"

import "core:fmt"
import "core:log"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"

import "src:common"
import "src:spall"

get_all_package_file_locations :: proc(
	document: ^Document,
	import_decl: ^ast.Import_Decl,
	locations: ^[dynamic]common.Location,
) -> bool {
	spall.trace(#procedure, document.fullpath)

	path := ""

	for imp in document.imports {
		if imp.original == import_decl.fullpath {
			path = imp.name
		}
	}

	matches, err := filepath.glob(fmt.tprintf("%v/*.odin", path), context.temp_allocator)

	for match in matches {
		if data, read_err := os.read_entire_file(match, runtime.default_allocator()); read_err == nil {
			ignored := common.has_ignore_file_tag(string(data)) ||
			           file_when_tags_exclude(string(data), match)
			delete(data, runtime.default_allocator())
			if ignored {
				continue
			}
		}
		uri := common.create_uri(match, context.temp_allocator)
		location := common.Location {
			uri = uri.uri,
		}
		append(locations, location)
	}

	return true
}

get_line_character_limit :: proc(text: []u8, target_line: int) -> (int, bool) {
	line := 0
	start := 0
	i := 0
	for i < len(text) {
		if text[i] == '\n' || text[i] == '\r' {
			if line == target_line {
				return common.get_character_offset_u8_to_u16(i - start, text[start:i]), true
			}
			if text[i] == '\r' && i + 1 < len(text) && text[i + 1] == '\n' {
				i += 1
			}
			line += 1
			start = i + 1
		}
		i += 1
	}
	if line == target_line {
		return common.get_character_offset_u8_to_u16(len(text) - start, text[start:]), true
	}
	return 0, false
}

count_source_lines :: proc(text: []u8) -> int {
	lines := 1
	for i := 0; i < len(text); i += 1 {
		if text[i] == '\n' || text[i] == '\r' {
			if text[i] == '\r' && i + 1 < len(text) && text[i + 1] == '\n' {
				i += 1
			}
			lines += 1
		}
	}
	return lines
}

get_definition_alias_symbol :: proc(
	ast_context: ^AstContext,
	name: string,
	pkg: string,
	fallback: Symbol,
) -> (Symbol, bool) {
	if name == "" {
		return fallback, false
	}

	if symbol, ok := lookup(name, pkg, ast_context.fullpath); ok {
		return symbol, true
	}

	if pkg == ast_context.document_package {
		if global, ok := ast_context.globals[name]; ok {
			result := fallback
			result.name = name
			result.pkg = pkg
			result.range = common.get_token_range(global.name_expr, ast_context.file.src)
			result.uri = common.create_uri(global.name_expr.pos.file, ast_context.allocator).uri
			result.type_expr = global.type_expr
			result.value_expr = global.value_expr
			if global.value_expr != nil {
				#partial switch expr in global.value_expr.derived {
				case ^ast.Ident, ^ast.Selector_Expr:
					result.value = SymbolGenericValue{expr = global.value_expr}
				case ^ast.Distinct_Type:
					result.value = SymbolGenericValue{expr = global.value_expr}
					result.flags |= {.Distinct}
				}
			}
			return result, true
		}
	}

	return fallback, false
}

get_definition_alias_target :: proc(ast_context: ^AstContext, symbol: Symbol) -> (Symbol, bool) {
	expr := symbol.value_expr
	if expr == nil {
		if value, ok := symbol.value.(SymbolGenericValue); ok {
			expr = value.expr
		}
	}
	if expr == nil {
		return {}, false
	}

	#partial switch expr in expr.derived {
	case ^ast.Ident:
		return get_definition_alias_symbol(ast_context, expr.name, symbol.pkg, symbol)
	case ^ast.Selector_Expr:
		if expr.field == nil {
			return {}, false
		}
		field, ok := expr.field.derived.(^ast.Ident)
		if !ok {
			return {}, false
		}
		if base, ok := expr.expr.derived.(^ast.Ident); ok {
			import_pkg := base.name
			if pkg, ok := indexer.index.collection.packages[symbol.pkg]; ok {
				if aliases, ok := pkg.import_aliases_by_file[expr.pos.file]; ok {
					if resolved_pkg, ok := aliases[base.name]; ok {
						import_pkg = resolved_pkg
					}
				}
			}
			if target, ok := lookup(field.name, import_pkg, expr.pos.file); ok {
				return target, true
			}
		}
		base, base_ok := resolve_type_expression(ast_context, expr.expr)
		if !base_ok {
			return {}, false
		}
		if _, ok := base.value.(SymbolPackageValue); !ok {
			return {}, false
		}
		return get_definition_alias_symbol(ast_context, field.name, base.pkg, symbol)
	}

	return {}, false
}

skip_definition_aliases :: proc(ast_context: ^AstContext, symbol: Symbol, name: string) -> Symbol {
	if .Local in symbol.flags || symbol.type == .Field || symbol.type == .EnumMember {
		return symbol
	}

	current, ok := get_definition_alias_symbol(ast_context, name, symbol.pkg, symbol)
	if !ok {
		return symbol
	}

	visited := make(map[string]struct{}, context.temp_allocator)
	defer delete(visited)

	for {
		key := fmt.tprintf("%s:%s", current.pkg, current.name)
		if key in visited {
			return symbol
		}
		visited[key] = {}

		if .Distinct in current.flags {
			return symbol
		}
		alias_expr := current.value_expr
		if alias_expr == nil {
			if value, ok := current.value.(SymbolGenericValue); ok {
				alias_expr = value.expr
			}
		}
		if alias_expr == nil {
			return current
		}
		#partial switch _ in alias_expr.derived {
		case ^ast.Ident, ^ast.Selector_Expr:
		case:
			return current
		}

		target, ok := get_definition_alias_target(ast_context, current)
		if !ok {
			return symbol
		}

		target_key := fmt.tprintf("%s:%s", target.pkg, target.name)
		if target_key in visited {
			return symbol
		}

		target_expr := target.value_expr
		if target_expr == nil {
			if value, ok := target.value.(SymbolGenericValue); ok {
				target_expr = value.expr
			}
		}
		is_alias := false
		if target_expr != nil {
			#partial switch _ in target_expr.derived {
			case ^ast.Ident, ^ast.Selector_Expr:
				is_alias = true
			}
		}
		if !is_alias || .Distinct in target.flags {
			return target
		}

		current = target
	}
}

sanitize_location_ranges :: proc(document: ^Document, locations: ^[dynamic]common.Location) {
	for i in 0 ..< len(locations^) {
		loc := &locations[i]
		fullpath := document.fullpath
		if loc.uri != "" {
			fullpath = common.uri_to_path(loc.uri, context.temp_allocator)
		}
		text: []u8
		if fullpath == document.fullpath {
			text = document.text[:document.used_text]
		} else if data, err := os.read_entire_file(fullpath, context.temp_allocator); err == nil {
			text = data
		} else {
			continue
		}

		max_line := count_source_lines(text) - 1
		loc.range.start.line = clamp(loc.range.start.line, 0, max_line)
		loc.range.end.line = clamp(loc.range.end.line, loc.range.start.line, max_line)
		if limit, ok := get_line_character_limit(text, loc.range.start.line); ok {
			loc.range.start.character = clamp(loc.range.start.character, 0, limit)
		}
		if limit, ok := get_line_character_limit(text, loc.range.end.line); ok {
			loc.range.end.character = clamp(loc.range.end.character, 0, limit)
		}
		if loc.range.end.line == loc.range.start.line && loc.range.end.character < loc.range.start.character {
			loc.range.end.character = loc.range.start.character
		}
	}
}

get_definition_location :: proc(document: ^Document, position: common.Position, config: ^common.Config) -> ([]common.Location, bool) {
	spall.trace(#procedure, document.fullpath)

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
	get_locals(&ast_context, &position_context)

	if position_context.import_stmt != nil {
		if get_all_package_file_locations(document, position_context.import_stmt, &locations) {
			sanitize_location_ranges(document, &locations)
			return locations[:], true
		}
	} else if position_context.selector_expr != nil {
		//if the base selector is the client wants to go to.
		if position_in_node(position_context.selector, position_context.position) &&
		   position_context.identifier != nil {
			ident := position_context.identifier.derived.(^ast.Ident)
			if resolved, ok := resolve_location_identifier(&ast_context, ident^); ok {
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
			if config.enable_definition_skip_aliases {
				selector := position_context.selector_expr.derived.(^ast.Selector_Expr)
				field := selector.field.derived.(^ast.Ident)
				resolved = skip_definition_aliases(&ast_context, resolved, field.name)
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
	} else if position_context.implicit_selector_expr != nil {
		if resolved, ok := resolve_location_implicit_selector(
			&ast_context,
			&position_context,
			position_context.implicit_selector_expr,
		); ok {
			location.range = resolved.range
			uri = resolved.uri
		} else {
			return {}, false
		}
	} else if position_context.identifier != nil {
		if resolved, ok := resolve_location_identifier(
			&ast_context,
			position_context.identifier.derived.(^ast.Ident)^,
		); ok {
			if config.enable_definition_skip_aliases {
				ident := position_context.identifier.derived.(^ast.Ident)
				resolved = skip_definition_aliases(&ast_context, resolved, ident.name)
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
	spall.trace(#procedure, ast_context.fullpath)

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
