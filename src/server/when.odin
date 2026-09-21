#+feature dynamic-literals
package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

import "src:common"

When_Expr :: union {
	int, //Integers types
	bool, //Boolean types
	string, //Enum types - those are the hardcoded options from i.e. ODIN_OS
	^ast.Expr,
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
make_when_expr_map :: proc() -> map[string]When_Expr {
	when_expr_map := make(map[string]When_Expr, context.temp_allocator)

	for key, value in common.config.profile.defines {
		when_expr_map[key] = resolve_when_ident(when_expr_map, value) or_continue
	}

	return when_expr_map
}

/*
Limited static fold of a package-level constant into the when map.
Only immutable consts whose RHS resolves to bool/int/string under the
existing when evaluator are registered (defines, literals, !, &&, ||,
parens, string compares). Unknown idents still default to false bool.
Profile defines win over package names.
*/
register_when_const :: proc(
	when_expr_map: ^map[string]When_Expr,
	name: string,
	value: ^ast.Expr,
	defer_unknown := false,
) {
	if name == "" || value == nil {
		return
	}
	if name in when_expr_map^ {
		return
	}

	resolved, ok := resolve_when_expr(when_expr_map^, value, defer_unknown)
	if !ok {
		return
	}

	// Only scalars are useful as when-condition bindings.
	#partial switch v in resolved {
	case bool:
		when_expr_map^[strings.clone(name, context.temp_allocator)] = v
	case int:
		when_expr_map^[strings.clone(name, context.temp_allocator)] = v
	case string:
		when_expr_map^[strings.clone(name, context.temp_allocator)] = strings.clone(v, context.temp_allocator)
	}
}

// Register foldable consts from a value declaration (immutable only).
register_when_consts_from_value_decl :: proc(
	when_expr_map: ^map[string]When_Expr,
	file: ast.File,
	value_decl: ^ast.Value_Decl,
	defer_unknown := false,
) {
	if value_decl == nil || value_decl.is_mutable {
		return
	}

	for name, i in value_decl.names {
		if len(value_decl.values) <= i {
			continue
		}
		name_str := get_ast_node_string(name, file.src)
		register_when_const(when_expr_map, name_str, value_decl.values[i], defer_unknown)
	}
}

// Multi-pass fold of package globals (map order is unstable).
register_when_consts_from_globals :: proc(
	when_expr_map: ^map[string]When_Expr,
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
			register_when_const(when_expr_map, name, global.value_expr)
			if len(when_expr_map) > before {
				added = true
			}
		}
		if !added {
			break
		}
	}
}

register_when_consts_from_file :: proc(when_expr_map: ^map[string]When_Expr, file: ast.File) {
	for _ in 0 ..< 8 {
		before := len(when_expr_map)
		for decl in file.decls {
			if value_decl, ok := decl.derived.(^ast.Value_Decl); ok {
				register_when_consts_from_value_decl(when_expr_map, file, value_decl, defer_unknown = true)
			}
		}
		if len(when_expr_map) == before do break
	}
}

register_when_consts_from_package :: proc(when_expr_map: ^map[string]When_Expr, file: ast.File) {
	allocator := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = allocator
	paths, err := filepath.glob(fmt.tprintf("%s/*.odin", filepath.dir(file.fullpath)), context.temp_allocator)
	if err != nil do return
	for _ in 0 ..< 8 {
		before := len(when_expr_map)
		for path in paths {
			if path == file.fullpath do continue
			data, read_err := os.read_entire_file(path, context.temp_allocator)
			if read_err != nil do continue
			if common.has_ignore_file_tag(string(data)) {
				delete(data, context.temp_allocator)
				continue
			}
			sibling := ast.File {fullpath = path, src = string(data)}
			p := parser.Parser {flags = {.Optional_Semicolons}}
			if parser.parse_file(&p, &sibling) && sibling.syntax_error_count == 0 {
				register_when_consts_from_file(when_expr_map, sibling)
			}
			delete(data, context.temp_allocator)
		}
		if len(when_expr_map) == before do break
	}
}

// The tooling parser does not expose #+when as a File_Tags field. Parse its
// expression as an Odin constant expression, then use the same scalar map as
// ordinary when statements.
resolve_file_when_tag :: proc(tag: string, when_expr_map: map[string]When_Expr) -> (bool, bool) {
	allocator := context.allocator
	context.allocator = context.temp_allocator
	defer context.allocator = allocator
	text := strings.trim_space(tag)
	if !strings.has_prefix(text, "#+when") do return false, false
	if len(text) > len("#+when") && !strings.is_space(rune(text[len("#+when")])) do return false, false
	expr_text := strings.trim_space(text[len("#+when"):])
	if expr_text == "" do return false, false

	source := fmt.tprintf("package when_tag\nTAG :: %s\n", expr_text)
	file := ast.File {src = source, fullpath = "<when tag>"}
	p := parser.Parser {flags = {.Optional_Semicolons}}
	if !parser.parse_file(&p, &file) || file.syntax_error_count > 0 || len(file.decls) != 1 {
		return false, false
	}
	decl, ok := file.decls[0].derived.(^ast.Value_Decl)
	if !ok || len(decl.values) != 1 do return false, false
	value, resolved := resolve_when_expr(when_expr_map, decl.values[0])
	if !resolved do return false, false
	if condition, ok := value.(bool); ok do return condition, true
	return false, false
}

has_file_when_tag :: proc(file: ast.File) -> bool {
	for tag in file.tags {
		text := strings.trim_space(tag.text)
		if strings.has_prefix(text, "#+when") &&
		   (len(text) == len("#+when") || strings.is_space(rune(text[len("#+when")]))) {
			return true
		}
	}
	return false
}

// Resolve header tags before parsing the body. An unresolved name may be a
// constant declared in this file, so leave that file for the normal pass.
file_when_tags_exclude :: proc(source, fullpath: string) -> bool {
	tok: tokenizer.Tokenizer
	tokenizer.init(&tok, source, fullpath, nil)
	tags := make([dynamic]string, context.temp_allocator)
	header: for {
		token := tokenizer.scan(&tok)
		#partial switch token.kind {
		case .Package, .EOF:
			break header
		case .File_Tag:
			text := strings.trim_space(token.text)
			if strings.has_prefix(text, "#+when") &&
			   (len(text) == len("#+when") || strings.is_space(rune(text[len("#+when")]))) {
				append(&tags, text)
			}
		}
	}
	if len(tags) == 0 do return false

	when_expr_map := make_when_expr_map()
	register_when_consts_from_package(&when_expr_map, ast.File {fullpath = fullpath})
	for tag in tags {
		expr_text := strings.trim_space(tag[len("#+when"):])
		ident_tok: tokenizer.Tokenizer
		tokenizer.init(&ident_tok, expr_text, fullpath, nil)
		known := true
		for {
			ident := tokenizer.scan(&ident_tok)
			if ident.kind == .EOF do break
			if ident.kind == .Ident && ident.text != "true" && ident.text != "false" {
				if _, ok := when_expr_map[ident.text]; !ok && ident.text != "ODIN_OS" && ident.text != "ODIN_ARCH" {
					known = false
					break
				}
			}
		}
		if known {
			condition, resolved := resolve_file_when_tag(tag, when_expr_map)
			if resolved && !condition do return true
		}
	}
	return false
}

resolve_when_ident :: proc(when_expr_map: map[string]When_Expr, ident: string, defer_unknown := false) -> (When_Expr, bool) {
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
			return resolve_when_expr(when_expr_map, v, defer_unknown)
		}
		return value, true
	}

	if v, ok := strconv.parse_int(ident); ok {
		return v, true
	} else if v, ok := strconv.parse_bool(ident); ok {
		return v, true
	}
	if len(ident) >= 2 && (ident[0] == '"' || ident[0] == '`') {
		if value, _, ok := strconv.unquote_string(ident, context.temp_allocator); ok {
			return value, true
		}
	}

	if defer_unknown && !strings.has_prefix(ident, "ODIN_") do return {}, false
	//If nothing is found we return it as false boolean
	return false, true
}

resolve_when_expr :: proc(
	when_expr_map: map[string]When_Expr,
	when_expr: When_Expr,
	defer_unknown := false,
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
	case ^ast.Expr:
		#partial switch odin_expr in expr.derived {
		case ^ast.Paren_Expr:
			return resolve_when_expr(when_expr_map, odin_expr.expr, defer_unknown)
		case ^ast.Ident:
			return resolve_when_ident(when_expr_map, odin_expr.name, defer_unknown)
		case ^ast.Basic_Lit:
			return resolve_when_ident(when_expr_map, odin_expr.tok.text, defer_unknown)
		case ^ast.Call_Expr:
			if directive, ok := odin_expr.expr.derived.(^ast.Basic_Directive); ok &&
			   directive.name == "config" && len(odin_expr.args) == 2 {
				if name, ok := odin_expr.args[0].derived.(^ast.Ident); ok {
					if value, exists := when_expr_map[name.name]; exists do return value, true
					return resolve_when_expr(when_expr_map, odin_expr.args[1], defer_unknown)
				}
			}
		case ^ast.Implicit_Selector_Expr:
			return odin_expr.field.name, true
		case ^ast.Unary_Expr:
			if odin_expr.op.kind == .Not {
				expr := resolve_when_expr(when_expr_map, odin_expr.expr, defer_unknown) or_return
				b := expr.(bool) or_return
				return !b, true
			}
		case ^ast.Binary_Expr:
			lhs := resolve_when_expr(when_expr_map, odin_expr.left, defer_unknown) or_return
			if lhs_bool, ok := lhs.(bool); ok {
				if odin_expr.op.kind == .Cmp_And && !lhs_bool do return false, true
				if odin_expr.op.kind == .Cmp_Or && lhs_bool do return true, true
			}
			rhs := resolve_when_expr(when_expr_map, odin_expr.right, defer_unknown) or_return

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
				case .Lt:
					return lhs_string < rhs_string, true
				case .Gt:
					return lhs_string > rhs_string, true
				case .Lt_Eq:
					return lhs_string <= rhs_string, true
				case .Gt_Eq:
					return lhs_string >= rhs_string, true
				}
			} else if lhs_is_bool && rhs_is_bool {
				#partial switch odin_expr.op.kind {
				case .Cmp_Eq:
					return lhs_bool == rhs_bool, true
				case .Not_Eq:
					return lhs_bool != rhs_bool, true
				case .Cmp_And:
					return lhs_bool && rhs_bool, true
				case .Cmp_Or:
					return lhs_bool || rhs_bool, true
				}
			} else if lhs_is_int && rhs_is_int {
				#partial switch odin_expr.op.kind {
				case .Cmp_Eq:
					return lhs_int == rhs_int, true
				case .Not_Eq:
					return lhs_int != rhs_int, true
				case .Lt:
					return lhs_int < rhs_int, true
				case .Gt:
					return lhs_int > rhs_int, true
				case .Lt_Eq:
					return lhs_int <= rhs_int, true
				case .Gt_Eq:
					return lhs_int >= rhs_int, true
				}
			}

			return {}, false
		}
	}


	return {}, false
}


resolve_when_condition :: proc(condition: ^ast.Expr, when_expr_map: map[string]When_Expr) -> bool {
	if condition == nil {
		return false
	}

	if when_expr, ok := resolve_when_expr(when_expr_map, condition); ok {
		b, is_bool := when_expr.(bool)
		return is_bool && b
	}

	return false
}
