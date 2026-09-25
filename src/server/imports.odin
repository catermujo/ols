package server

import "core:fmt"
import "core:mem"
import "core:strings"

import "base:runtime"

import "core:odin/ast"
import path "core:path/slashpath"

import "src:common"
import "src:spall"

find_used_not_imported :: proc(
	document: ^Document,
	config: ^common.Config,
	allocator := context.temp_allocator,
) -> []Package {
	arena: runtime.Arena

	_ = runtime.arena_init(&arena, mem.Megabyte * 40, context.allocator)
	defer runtime.arena_destroy(&arena)

	context.allocator = runtime.arena_allocator(&arena)

	symbols_and_nodes := resolve_entire_file(document)

	already_imported := make(map[string]struct{})

	for imp in document.imports {
		already_imported[imp.base] = {}
	}

	unresolved := make(map[string]string)

	for _, v in symbols_and_nodes {
		if v.is_unresolved && v.is_selector_expression_unresolved {
			if selector_expr, ok := v.node.derived.(^ast.Selector_Expr); ok {
				if ident, ok := selector_expr.expr.derived.(^ast.Ident); ok {
					if ident.name in already_imported {
						continue
					}

					if selector_expr.field != nil && ident.name not_in unresolved {
						unresolved[ident.name] = selector_expr.field.name
					}
				}
			}
		}
	}


	missing := make([dynamic]Package, allocator)

	for collection, pkgs in build_cache.pkg_aliases {
		for pkg in pkgs {
			pkg_base := path.base(pkg)
			field_name, is_candidate := unresolved[pkg_base]

			if !is_candidate {
				continue
			}

			fullpath := path.join({config.collections[collection], pkg})

			already := false

			for doc_pkg in document.imports {
				if fullpath == doc_pkg.name {
					already = true
					break
				}
			}

			if already {
				continue
			}

			try_build_package(fullpath)

			if _, ok := lookup(field_name, fullpath, document.fullpath); ok {
				append(
					&missing,
					Package {
						name = strings.clone(fullpath, allocator),
						base = strings.clone(pkg_base, allocator),
						original = fmt.aprintf("%v:%v", collection, pkg, allocator = allocator),
					},
				)
			}
		}
	}

	return missing[:]
}

find_unused_imports :: proc(document: ^Document, allocator := context.temp_allocator) -> []Package {
	spall.trace(#procedure, document.fullpath)

	if document.ast.syntax_error_count > 0 {
		return nil
	}

	symbols := resolve_entire_file(document)

	pkgs := make(map[string]struct{}, context.temp_allocator)
	for _, v in symbols {
		pkgs[v.symbol.pkg] = {}
	}

	unused := make([dynamic]Package, allocator)
	for imp in document.imports {
		if imp.base != "_" && imp.name not_in pkgs {
			append(&unused, imp)
		}
	}

	return unused[:]
}

find_unused_imports_syntactic :: proc(document: ^Document, allocator := context.temp_allocator) -> []Package {
	if document.ast.syntax_error_count > 0 do return nil

	// Diagnostics only need a conservative answer. Package names are used as
	// selector bases, so this avoids resolving every import on document open.
	used := make(map[string]bool, context.temp_allocator)
	for imp in document.imports do used[imp.base] = false

	visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
		if node == nil do return nil
		if selector, ok := node.derived.(^ast.Selector_Expr); ok {
			if base, ok := selector.expr.derived.(^ast.Ident); ok {
				used := cast(^map[string]bool)visitor.data
				if base.name in used^ do used^[base.name] = true
			}
		}
		return visitor
	}
	visitor := ast.Visitor {visit = visit, data = &used}
	for decl in document.ast.decls do ast.walk(&visitor, decl)

	unused := make([dynamic]Package, allocator)
	for imp in document.imports {
		if imp.base != "_" && !used[imp.base] {
			append(&unused, imp)
		}
	}

	return unused[:]
}
