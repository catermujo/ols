#+feature dynamic-literals
package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:strconv"

import "src:common"

When_Expr_Unknown :: struct {}

When_Expr :: union {
	int, //Integers types
	bool, //Boolean types
	string, //Enum types - those are the hardcoded options from i.e. ODIN_OS
	^ast.Expr,
	When_Expr_Unknown,
}

//Because we use configuration with os names that match the files instead of the enum, i.e. my_file_windows.odin, we have to convert back and fourth.
@(private = "file")
convert_os_string: map[string]string = {
	"windows"      = "Windows",
	"darwin"       = "Darwin",
	"linux"        = "Linux",
	"freebsd"      = "FreeBSD",
	"wasi"         = "WASI",
	"js"           = "JS",
	"freestanding" = "Freestanding",
	"openbsd"      = "OpenBSD",
	"netbsd"       = "NetBSD",
	"orca"         = "Orca",
}

// Profile defines seed for when-condition evaluation.
make_when_expr_map :: proc(file: ast.File) -> map[string]When_Expr {
	when_expr_map := make(map[string]When_Expr, context.temp_allocator)
	resolve_when_expr_map_add_config_defaults(file, &when_expr_map)

	for key, value in common.config.profile.defines {
		when_expr_map[key] = resolve_when_ident(file, when_expr_map, value) or_continue
	}

	return when_expr_map
}

/*
Limited static fold of a package-level constant into the when map.
Only immutable consts whose RHS resolves to bool/int/string under the
existing when evaluator are registered (defines, literals, !, &&, ||,
parens, string compares). Unknown idents default to false.
Profile defines win over package names.
*/
register_when_const :: proc(when_expr_map: ^map[string]When_Expr, file: ast.File, name: string, value: ^ast.Expr) {
	if name == "" || value == nil {
		return
	}
	if name in when_expr_map^ {
		return
	}

	resolved, ok := resolve_when_expr(file, when_expr_map^, value)
	if !ok {
		return
	}

	// Only scalars are useful as when-condition bindings.
	#partial switch v in resolved {
	case bool:
		when_expr_map^[name] = v
	case int:
		when_expr_map^[name] = v
	case string:
		when_expr_map^[name] = v
	}
}

// Register foldable consts from a value declaration (immutable only).
register_when_consts_from_value_decl :: proc(
	when_expr_map: ^map[string]When_Expr,
	file: ast.File,
	value_decl: ^ast.Value_Decl,
) {
	if value_decl == nil || value_decl.is_mutable {
		return
	}

	for name, i in value_decl.names {
		if len(value_decl.values) <= i {
			continue
		}
		name_str := get_ast_node_string(name, file.src)
		register_when_const(when_expr_map, file, name_str, value_decl.values[i])
	}
}

// Multi-pass fold of package globals (map order is unstable).
register_when_consts_from_globals :: proc(
	when_expr_map: ^map[string]When_Expr,
	file: ast.File,
	globals: map[string]GlobalExpr,
) {
	// Enough passes for short const chains (A :: B, B :: !C).
	for _ in 0 ..< 8 {
		added := false
		for name, global in globals {
			if .Mutable in global.flags {
				continue
			}
			if global.value_expr == nil {
				continue
			}
			if name in when_expr_map^ {
				continue
			}
			before := len(when_expr_map)
			register_when_const(when_expr_map, file, name, global.value_expr)
			if len(when_expr_map) > before {
				added = true
			}
		}
		if !added {
			break
		}
	}
}

resolve_when_ident_from_file_config_default :: proc(
	file: ast.File,
	when_expr_map: map[string]When_Expr,
	ident: string,
) -> (
	When_Expr,
	bool,
) {
	for decl in file.decls {
		value_decl, ok := decl.derived.(^ast.Value_Decl)
		if !ok {
			continue
		}

		for name_expr, i in value_decl.names {
			name_ident, name_ok := name_expr.derived.(^ast.Ident)
			if !name_ok || name_ident.name != ident {
				continue
			}

			if len(value_decl.values) <= i {
				continue
			}

			call, call_ok := value_decl.values[i].derived.(^ast.Call_Expr)
			if !call_ok || call.expr == nil || len(call.args) < 2 {
				continue
			}

			directive, directive_ok := call.expr.derived.(^ast.Basic_Directive)
			if !directive_ok || directive.name != "config" {
				continue
			}

			if arg_ident, arg_ok := call.args[0].derived.(^ast.Ident); arg_ok && arg_ident.name != ident {
				continue
			}

			return resolve_when_expr(file, when_expr_map, call.args[1])
		}
	}

	return {}, false
}

resolve_when_ident_from_package_config_default :: proc(
	file: ast.File,
	when_expr_map: map[string]When_Expr,
	ident: string,
) -> (
	When_Expr,
	bool,
) {
	if file.fullpath == "" {
		return {}, false
	}

	pkg := get_package_from_filepath(file.fullpath)
	symbol, ok := lookup(ident, pkg, file.fullpath)
	if !ok || symbol.uri == "" {
		return {}, false
	}

	config_path := common.uri_to_path(symbol.uri, context.temp_allocator)
	data, err := os.read_entire_file(config_path, context.temp_allocator)
	if err != nil {
		return {}, false
	}

	p := parser.Parser {
		flags = {.Optional_Semicolons},
	}

	pkg_file := new(ast.Package, context.temp_allocator)
	pkg_file.kind = .Normal
	pkg_file.fullpath = config_path

	config_file := ast.File {
		fullpath = config_path,
		src      = string(data),
		pkg      = pkg_file,
	}

	if !parser.parse_file(&p, &config_file) {
		return {}, false
	}

	return resolve_when_ident_from_file_config_default(config_file, when_expr_map, ident)
}

resolve_when_ident :: proc(file: ast.File, when_expr_map: map[string]When_Expr, ident: string) -> (When_Expr, bool) {
	switch ident {
	case "ODIN_OS":
		if common.config.profile.os != "" {
			os, ok := convert_os_string[common.config.profile.os]
			if ok {
				return os, true
			} else {
				return fmt.tprint(ODIN_OS), true
			}
		} else {
			return fmt.tprint(ODIN_OS), true
		}
	case "ODIN_ARCH":
		if common.config.profile.arch != "" {
			return common.config.profile.arch, true
		} else {
			return fmt.tprint(ODIN_ARCH), true
		}
	}

	if ident in when_expr_map {
		value := when_expr_map[ident]
		// Fully resolve stored AST fragments (if any) so conditions see scalars.
		#partial switch v in value {
		case ^ast.Expr:
			return resolve_when_expr(file, when_expr_map, v)
		}
		return value, true
	}

	if v, ok := strconv.parse_int(ident); ok {
		return v, true
	} else if v, ok := strconv.parse_bool(ident); ok {
		return v, true
	}

	if value, ok := resolve_when_ident_from_package_config_default(file, when_expr_map, ident); ok {
		return value, true
	}

	return When_Expr_Unknown{}, true
}

resolve_when_expr :: proc(
	file: ast.File,
	when_expr_map: map[string]When_Expr,
	when_expr: When_Expr,
) -> (
	_when_expr: When_Expr,
	ok: bool,
) {
	switch expr in when_expr {
	case int:
		return expr, true
	case bool:
		return expr, true
	case string:
		return expr, true
	case When_Expr_Unknown:
		return expr, true
	case ^ast.Expr:
		#partial switch odin_expr in expr.derived {
		case ^ast.Paren_Expr:
			return resolve_when_expr(file, when_expr_map, odin_expr.expr)
		case ^ast.Ident:
			return resolve_when_ident(file, when_expr_map, odin_expr.name)
		case ^ast.Basic_Lit:
			return resolve_when_ident(file, when_expr_map, odin_expr.tok.text)
		case ^ast.Implicit_Selector_Expr:
			return odin_expr.field.name, true
		case ^ast.Unary_Expr:
			if odin_expr.op.kind == .Not {
				expr := resolve_when_expr(file, when_expr_map, odin_expr.expr) or_return
				if _, ok := expr.(When_Expr_Unknown); ok {
					return expr, true
				}
				b := expr.(bool) or_return
				return !b, true
			}
		case ^ast.Binary_Expr:
			lhs := resolve_when_expr(file, when_expr_map, odin_expr.left) or_return
			rhs := resolve_when_expr(file, when_expr_map, odin_expr.right) or_return
			if _, ok := lhs.(When_Expr_Unknown); ok {
				return lhs, true
			}
			if _, ok := rhs.(When_Expr_Unknown); ok {
				return rhs, true
			}

			lhs_bool, lhs_is_bool := lhs.(bool)
			rhs_bool, rhs_is_bool := rhs.(bool)

			lhs_int, lhs_is_int := lhs.(int)
			rhs_int, rhs_is_int := rhs.(int)

			lhs_string, lhs_is_string := lhs.(string)
			rhs_string, rhs_is_string := rhs.(string)

			if lhs_is_string && rhs_is_string {
				#partial switch odin_expr.op.kind {
				case .Cmp_Eq:
					return lhs_string == rhs_string, true
				case .Not_Eq:
					return lhs_string != rhs_string, true
				}
			} else if lhs_is_bool && rhs_is_bool {
				#partial switch odin_expr.op.kind {
				case .Cmp_And:
					return lhs_bool && rhs_bool, true
				case .Cmp_Or:
					return lhs_bool || rhs_bool, true
				}
			}

			return {}, false
		}
	}

	return {}, false
}

resolve_when_expr_map_add_config_defaults :: proc(file: ast.File, when_expr_map: ^map[string]When_Expr) {
	for decl in file.decls {
		value_decl, ok := decl.derived.(^ast.Value_Decl)
		if !ok {
			continue
		}

		for name_expr, i in value_decl.names {
			if len(value_decl.values) <= i {
				continue
			}

			name_ident, name_ok := name_expr.derived.(^ast.Ident)
			if !name_ok {
				continue
			}

			call, call_ok := value_decl.values[i].derived.(^ast.Call_Expr)
			if !call_ok || call.expr == nil {
				continue
			}

			directive, directive_ok := call.expr.derived.(^ast.Basic_Directive)
			if !directive_ok || directive.name != "config" {
				continue
			}

			if len(call.args) < 2 {
				continue
			}

			value, value_ok := resolve_when_expr(file, when_expr_map^, call.args[1])
			if !value_ok {
				continue
			}

			when_expr_map^[name_ident.name] = value

			arg_ident, arg_ident_ok := call.args[0].derived.(^ast.Ident)
			if arg_ident_ok {
				when_expr_map^[arg_ident.name] = value
			}
		}
	}
}

resolve_when_condition :: proc(file: ast.File, condition: ^ast.Expr, when_expr_map: map[string]When_Expr) -> bool {
	if condition == nil {
		return false
	}

	if when_expr, ok := resolve_when_expr(file, when_expr_map, condition); ok {
		if _, ok := when_expr.(When_Expr_Unknown); ok {
			return true
		}
		b, is_bool := when_expr.(bool)
		return is_bool && b
	}

	return false
}
