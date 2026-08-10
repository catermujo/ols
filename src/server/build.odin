#+feature dynamic-literals
package server

import "base:runtime"
import "core:slice"

import "core:fmt"
import "core:log"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "src:common"

platform_os: map[string]struct{} = {
	"windows" = {},
	"linux"   = {},
	"js"      = {},
	"freebsd" = {},
	"darwin"  = {},
	"wasm32"  = {},
	"openbsd" = {},
	"wasi"    = {},
	"wasm"    = {},
	"netbsd"  = {},
	"freebsd" = {},
}


os_enum_to_string: [runtime.Odin_OS_Type]string = {
	.Windows      = "windows",
	.Darwin       = "darwin",
	.Linux        = "linux",
	.FreeBSD      = "freebsd",
	.WASI         = "wasi",
	.JS           = "js",
	.Freestanding = "freestanding",
	.OpenBSD      = "openbsd",
	.NetBSD       = "netbsd",
	.Orca         = "orca",
	.Unknown      = "unknown",
}

os_string_to_enum: map[string]runtime.Odin_OS_Type = {
	"Windows"      = .Windows,
	"windows"      = .Windows,
	"Darwin"       = .Darwin,
	"darwin"       = .Darwin,
	"Linux"        = .Linux,
	"linux"        = .Linux,
	"Freebsd"      = .FreeBSD,
	"freebsd"      = .FreeBSD,
	"FreeBSD"      = .FreeBSD,
	"Wasi"         = .WASI,
	"wasi"         = .WASI,
	"WASI"         = .WASI,
	"Js"           = .JS,
	"js"           = .JS,
	"JS"           = .JS,
	"Freestanding" = .Freestanding,
	"freestanding" = .Freestanding,
	"Wasm"         = .JS,
	"wasm"         = .JS,
	"Openbsd"      = .OpenBSD,
	"openbsd"      = .OpenBSD,
	"OpenBSD"      = .OpenBSD,
	"Netbsd"       = .NetBSD,
	"netbsd"       = .NetBSD,
	"NetBSD"       = .NetBSD,
	"Orca"         = .Orca,
	"orca"         = .Orca,
	"Unknown"      = .Unknown,
	"unknown"      = .Unknown,
}

@(private = "file")
is_bsd_variant :: proc(name: string) -> bool {
	return(
		common.config.profile.os == os_enum_to_string[.FreeBSD] ||
		common.config.profile.os == os_enum_to_string[.OpenBSD] ||
		common.config.profile.os == os_enum_to_string[.NetBSD] \
	)
}

@(private = "file")
is_unix_variant :: proc(name: string) -> bool {
	return(
		common.config.profile.os == os_enum_to_string[.Linux] ||
		common.config.profile.os == os_enum_to_string[.Darwin] \
	)
}

skip_file :: proc(filename: string) -> bool {
	last_underscore_index := strings.last_index(filename, "_")
	last_dot_index := strings.last_index(filename, ".")

	if last_underscore_index + 1 < last_dot_index {
		name_between := filename[last_underscore_index + 1:last_dot_index]

		if name_between == "unix" {
			return !is_unix_variant(name_between)
		}

		if name_between == "bsd" {
			return !is_bsd_variant(name_between)
		}

		if _, ok := platform_os[name_between]; ok {
			return name_between != common.config.profile.os
		}
	}

	return false
}

Append_Packages_State :: struct {
	pkgs:      ^[dynamic]string,
	root:      string,
	skip:      map[string]struct{},
	allocator: runtime.Allocator,
}

append_packages_should_skip_dir :: proc(path: string, state: rawptr) -> bool {
	data := cast(^Append_Packages_State)state
	return path in data.skip || path_is_excluded_by_profile(path, data.root)
}

append_packages_collect_file :: proc(fullpath: string, state: rawptr) {
	if filepath.ext(fullpath) != ".odin" {
		return
	}

	data := cast(^Append_Packages_State)state
	if path_is_excluded_by_profile(fullpath, data.root) {
		return
	}

	if file_has_ignore_file_tag(fullpath) {
		return
	}

	dir := filepath.dir(fullpath)
	if !slice.contains(data.pkgs[:], dir) {
		append(data.pkgs, strings.clone(dir, data.allocator))
	}
}

// Finds all packages under the provided path by walking the file system
// and appends them to the provided dynamic array
append_packages :: proc(path: string, pkgs: ^[dynamic]string, skip: map[string]struct{}, allocator := context.temp_allocator) {
	data := Append_Packages_State {
		pkgs      = pkgs,
		root      = path,
		skip      = skip,
		allocator = allocator,
	}
	walk_tree_follow_symlink_dirs(path, &data, append_packages_should_skip_dir, append_packages_collect_file)
}

should_collect_file :: proc(file_tags: parser.File_Tags) -> bool {
	if file_tags.ignore {
		return false
	}

	if len(file_tags.build) > 0 {
		when_expr_map := make(map[string]When_Expr, context.temp_allocator)
		empty_file := ast.File{}

		for key, value in common.config.profile.defines {
			when_expr_map[key] = resolve_when_ident(empty_file, when_expr_map, value) or_continue
		}

		if when_expr, ok := resolve_when_ident(empty_file, when_expr_map, "ODIN_OS"); ok {
			if s, ok := when_expr.(string); ok {
				if used_os, ok := os_string_to_enum[when_expr.(string)]; ok {
					found := false
					for tag in file_tags.build {
						if used_os in tag.os {
							found = true
							break
						}
					}
					if !found {
						return false
					}
				}
			}
		}
	}
	return true
}

try_build_package :: proc(pkg_name: string, required_name := "") {
	if pkg, ok := build_cache.loaded_pkgs[pkg_name]; ok {
		return
	}

	if required_name != "" {
		cache_key := fmt.tprintf("%s:%s", pkg_name, required_name)
		if _, ok := build_cache.indexed_package_names[cache_key]; ok {
			return
		}
		build_cache.indexed_package_names[strings.clone(cache_key, indexer.index.collection.allocator)] = true
	}

	defer clear_index_cache()

	progress_token := ""
	if required_name == "" {
		progress_token = progress_task_begin(
			"OLS_INDEX_PACKAGE",
			fmt.tprintf("Index package %s", filepath.base(pkg_name)),
			pkg_name,
		)
	}

	matches, err := filepath.glob(fmt.tprintf("%v/*.odin", pkg_name), context.temp_allocator)

	if err != nil && err != .Not_Exist {
		log.errorf("Failed to glob %v for indexing package: %v", pkg_name, err)
		return
	}

	arena: runtime.Arena
	result := runtime.arena_init(&arena, mem.Megabyte * 40, runtime.default_allocator())
	defer runtime.arena_destroy(&arena)
	old_allocator := context.allocator
	defer context.allocator = old_allocator

	{
		context.allocator = runtime.arena_allocator(&arena)

		processed_files := 0
		for fullpath in matches {
			if skip_file(filepath.base(fullpath)) {
				continue
			}
			if _, ok := build_cache.indexed_files[fullpath]; ok {
				continue
			}

			processed_files += 1
			percentage := 0
			if len(matches) > 0 {
				percentage = (processed_files * 100) / len(matches)
			}
			if progress_token != "" {
				progress_report(
					progress_token,
					fmt.tprintf("%s (%s)", pkg_name, filepath.base(fullpath)),
					percentage,
				)
			}

			data, err := os.read_entire_file(fullpath, context.allocator)

			if err != nil {
				log.errorf("failed to read entire file for indexing %v: %v", fullpath, err)
				continue
			}

			source := string(data)
			if source_has_ignore_file_tag(source) {
				continue
			}
			if required_name != "" && !strings.contains(source, required_name) {
				continue
			}

			p := parser.Parser {
				flags = {.Optional_Semicolons},
			}
			if !is_ols_builtin_file(fullpath) {
				p.err = log_error_handler
				p.warn = log_warning_handler
			}

			dir := filepath.base(filepath.dir(fullpath))

			pkg := new(ast.Package)
			pkg.kind = .Normal
			pkg.fullpath = fullpath
			pkg.name = dir

			if dir == "runtime" || strings.contains(fullpath, "base/runtime") {
				pkg.kind = .Runtime
			}

			file := ast.File {
				fullpath = fullpath,
				src      = source,
				pkg      = pkg,
			}

			ok := parse_file_with_allocator(&p, &file, context.allocator)

			if !ok {
				if !is_ols_builtin_file(fullpath) {
					log.errorf("error in parse file for indexing %v", fullpath)
				}
				continue
			}

			uri := common.create_uri(fullpath, context.allocator)

			collect_symbols(&indexer.index.collection, file, uri.uri)
			build_cache.indexed_files[strings.clone(fullpath, indexer.index.collection.allocator)] = true

			runtime.arena_free_all(&arena)
		}
	}

	if required_name == "" {
		build_cache.loaded_pkgs[strings.clone(pkg_name, indexer.index.collection.allocator)] = PackageCacheInfo {
			timestamp = time.now(),
		}
	}
	if progress_token != "" {
		progress_end(progress_token, fmt.tprintf("Indexed %s", pkg_name))
	}
}

remove_package_file_doc_comment :: proc(pkg: ^SymbolPackage, uri: string, allocator: mem.Allocator) {
	doc_key := ""
	doc_value := ""
	comment_key := ""
	comment_value := ""

	for key, value in pkg.doc {
		if strings.equal_fold(key, uri) {
			doc_key = key
			doc_value = value
			break
		}
	}

	for key, value in pkg.comment {
		if strings.equal_fold(key, uri) {
			comment_key = key
			comment_value = value
			break
		}
	}

	if doc_value != "" {
		delete(doc_value, allocator)
	}
	if comment_value != "" {
		delete(comment_value, allocator)
	}

	if doc_key != "" {
		delete_key(&pkg.doc, doc_key)
	}
	if comment_key != "" {
		delete_key(&pkg.comment, comment_key)
	}

	if doc_key != "" {
		delete(doc_key, allocator)
	}
	if comment_key != "" && (doc_key == "" || raw_data(comment_key) != raw_data(doc_key)) {
		delete(comment_key, allocator)
	}
}

remove_indexed_file_data :: proc(corrected_uri: string) {
	for _, &pkg in indexer.index.collection.packages {
		// Method entries are shallow copies of package symbols. Remove them
		// while their shared URI/storage is still valid, before freeing the
		// package symbols below.
		for method, &symbols in pkg.methods {
			for i := len(symbols) - 1; i >= 0; i -= 1 {
				#no_bounds_check symbol := symbols[i]
				if strings.equal_fold(corrected_uri, symbol.uri) {
					unordered_remove(&symbols, i)
				}
			}

			if len(symbols) == 0 {
				delete(symbols)
				delete_key(&pkg.methods, method)
			} else {
				pkg.methods[method] = symbols
			}
		}

		for symbol_name, symbol in pkg.symbols {
			if !strings.equal_fold(corrected_uri, symbol.uri) {
				continue
			}

			free_symbol(symbol, indexer.index.collection.allocator)
			delete_key(&pkg.symbols, symbol_name)
		}

		remove_package_file_doc_comment(&pkg, corrected_uri, indexer.index.collection.allocator)
	}
}


remove_index_file :: proc(uri: common.Uri) -> common.Error {
	ok: bool
	defer clear_index_cache()

	fullpath := uri.path

	when ODIN_OS == .Windows {
		fullpath, _ = filepath.replace_separators(fullpath, '/', context.temp_allocator)
	}
	clear_indexed_package_names()

	corrected_uri := common.create_uri(fullpath, context.temp_allocator)

	remove_indexed_file_data(corrected_uri.uri)
	delete_key(&build_cache.indexed_files, fullpath)

	clear_all_file_resolve_cache()
	reference_import_cache_remove_file(fullpath)

	return .None
}

index_file :: proc(uri: common.Uri, text: string) -> common.Error {
	ok: bool
	defer clear_index_cache()

	fullpath := uri.path

	p := parser.Parser {
		flags = {.Optional_Semicolons},
	}
	if !is_ols_builtin_file(fullpath) {
		p.err = log_error_handler
		p.warn = log_warning_handler
	}

	when ODIN_OS == .Windows {
		correct := common.get_case_sensitive_path(fullpath, context.temp_allocator)
		fullpath, _ = filepath.replace_separators(correct, '/', context.temp_allocator)
	}
	clear_indexed_package_names()

	corrected_uri := common.create_uri(fullpath, context.temp_allocator)
	is_ignored := source_has_ignore_file_tag(text)
	file: ast.File
	parse_arena: runtime.Arena
	parse_arena_initialized := false
	defer {
		if parse_arena_initialized {
			runtime.arena_destroy(&parse_arena)
		}
	}

	if !is_ignored {
		// Keep the parser AST completely local to this indexing pass. The old
		// path allocated the package root with the request allocator and put
		// the rest of the AST in the global temp arena, so every didChange left
		// parser-owned allocations behind in long-lived sessions.
		arena_err := runtime.arena_init(&parse_arena, mem.Megabyte * 4, runtime.default_allocator())
		if arena_err != nil {
			log.errorf("failed to initialize parser arena for %v: %v", fullpath, arena_err)
			return .InternalError
		}
		parse_arena_initialized = true
		parse_allocator := runtime.arena_allocator(&parse_arena)

		old_allocator := context.allocator
		context.allocator = parse_allocator

		dir := filepath.base(filepath.dir(fullpath))
		pkg := new(ast.Package)
		pkg.kind = .Normal
		pkg.fullpath = fullpath
		pkg.name = dir

		if dir == "runtime" || strings.contains(fullpath, "base/runtime") {
			pkg.kind = .Runtime
		}

		file = ast.File {
			fullpath = fullpath,
			src      = text,
			pkg      = pkg,
		}

		ok = parse_file_with_allocator(&p, &file, parse_allocator)
		context.allocator = old_allocator
	}

	if is_ignored {
		remove_indexed_file_data(corrected_uri.uri)
		clear_all_file_resolve_cache()
		reference_import_cache_remove_file(fullpath)
		return .None
	}

	if !ok || file.syntax_error_count > 0 || file.pkg_decl == nil {
		log.warnf(
			"skipping symbol indexing for %v after parse failure (ok=%v, syntax_errors=%v, package_decl=%v)",
			fullpath,
			ok,
			file.syntax_error_count,
			file.pkg_decl != nil,
		)
		return .None
	}

	remove_indexed_file_data(corrected_uri.uri)

	if ret := collect_symbols(&indexer.index.collection, file, corrected_uri.uri); ret != .None {
		log.errorf("failed to collect symbols on save %v", ret)
	}
	build_cache.indexed_files[strings.clone(fullpath, indexer.index.collection.allocator)] = true

	clear_all_file_resolve_cache()
	reference_import_cache_update_file(fullpath, text)

	return .None
}


setup_index :: proc(builtin_path: string) {
	build_cache.loaded_pkgs = make(map[string]PackageCacheInfo, 50, context.allocator)
	build_cache.indexed_files = make(map[string]bool, 512, context.allocator)
	build_cache.indexed_package_names = make(map[string]bool, 512, context.allocator)
	build_cache.pkg_aliases = make(map[string][dynamic]string, 16, context.allocator)
	build_cache.package_aliases_discovered = false
	symbol_collection := make_symbol_collection(context.allocator, &common.config)
	indexer.index = make_memory_index(symbol_collection)

	try_build_package(builtin_path)
}

free_index :: proc() {
	delete_symbol_collection(indexer.index.collection)
}

log_error_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {
	log.warnf("%v %v %v", pos, msg, args)
}

log_warning_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {
	log.warnf("%v %v %v", pos, msg, args)
}
