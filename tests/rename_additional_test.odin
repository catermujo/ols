package tests

import "core:log"
import "core:mem/virtual"
import "core:os"
import path "core:path/slashpath"
import "core:strings"
import "core:testing"

import "src:common"
import "src:server"

import test "src:testing"

rename_extract_cursor :: proc(src: string) -> (string, common.Position, bool) {
	marker := "{*}"
	marker_pos := strings.index(src, marker)
	if marker_pos < 0 {
		return src, {}, false
	}

	position: common.Position
	for i := 0; i < marker_pos; i += 1 {
		if src[i] == '\n' {
			position.line += 1
			position.character = 0
		} else {
			position.character += 1
		}
	}

	cleaned, _ := strings.remove(src, marker, 1, context.temp_allocator)
	return cleaned, position, true
}

rename_reset_global_config :: proc() {
	delete(common.config.workspace_folders)
	common.config.workspace_folders = nil
	delete(common.config.collections)
	common.config.collections = nil
	delete(common.config.profile.exclude_path)
	common.config.profile.exclude_path = nil
	common.config.enable_definition_skip_alias = false
	server.reference_import_cache_reset()
}

@(test)
ast_rename_local_variable_respects_shadowing :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
value := 1
{
value := 2
_ = value
}
_ = value
_ = val{*}ue
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 0}, end = {line = 3, character = 5}}},
		{range = {start = {line = 8, character = 4}, end = {line = 8, character = 9}}},
		{range = {start = {line = 9, character = 4}, end = {line = 9, character = 9}}},
	}
	excluded := []common.Location {
		{range = {start = {line = 5, character = 0}, end = {line = 5, character = 5}}},
		{range = {start = {line = 6, character = 4}, end = {line = 6, character = 9}}},
	}

	test.expect_rename_locations(t, &source, "renamed", locations[:], excluded[:])
}

@(test)
ast_rename_proc_parameter_and_named_arguments :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

add :: proc(left: int, right: int) -> int {
return left + right
}

main :: proc() {
_ = add(left = 1, right = 2)
_ = add(ri{*}ght = 3, left = 4)
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 23}, end = {line = 2, character = 28}}},
		{range = {start = {line = 3, character = 14}, end = {line = 3, character = 19}}},
		{range = {start = {line = 7, character = 18}, end = {line = 7, character = 23}}},
		{range = {start = {line = 8, character = 8}, end = {line = 8, character = 13}}},
	}

	test.expect_rename_locations(t, &source, "renamed", locations[:])
}

@(test)
ast_rename_global_constant_and_uses :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

answer :: 42

main :: proc() {
_ = answer
answer_copy := ans{*}wer
_ = answer_copy
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 0}, end = {line = 2, character = 6}}},
		{range = {start = {line = 5, character = 4}, end = {line = 5, character = 10}}},
		{range = {start = {line = 6, character = 15}, end = {line = 6, character = 21}}},
	}

	test.expect_rename_locations(t, &source, "renamed", locations[:])
}

@(test)
ast_rename_procedure_declaration_and_calls :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

helper :: proc(value: int) -> int {
return value
}

main :: proc() {
_ = hel{*}per(1)
_ = helper(2)
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 0}, end = {line = 2, character = 6}}},
		{range = {start = {line = 7, character = 4}, end = {line = 7, character = 10}}},
		{range = {start = {line = 8, character = 4}, end = {line = 8, character = 10}}},
	}

	test.expect_rename_locations(t, &source, "renamed", locations[:])
}

@(test)
ast_rename_type_in_nested_type_expressions :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Widget :: struct {}

Holder :: struct {
value: Widget
}

make_widget :: proc() -> Wid{*}get {
return Widget{}
}

main :: proc() {
value: Widget
pointer: ^Widget
array: [2]Widget
_ = Holder{value = Widget{}}
_ = value
_ = pointer
_ = array
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 0}, end = {line = 2, character = 6}}},
		{range = {start = {line = 5, character = 7}, end = {line = 5, character = 13}}},
		{range = {start = {line = 8, character = 25}, end = {line = 8, character = 31}}},
		{range = {start = {line = 9, character = 7}, end = {line = 9, character = 13}}},
		{range = {start = {line = 13, character = 7}, end = {line = 13, character = 13}}},
		{range = {start = {line = 14, character = 10}, end = {line = 14, character = 16}}},
		{range = {start = {line = 15, character = 10}, end = {line = 15, character = 16}}},
		{range = {start = {line = 16, character = 19}, end = {line = 16, character = 25}}},
	}

	test.expect_rename_locations(t, &source, "Renamed_Widget", locations[:])
}

@(test)
ast_rename_struct_field_selectors_and_literals :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Thing :: struct {
na{*}me: string
}

main :: proc() {
thing := Thing{name = "one"}
_ = thing.name
pointer := &thing
_ = pointer.name
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 0}, end = {line = 3, character = 4}}},
		{range = {start = {line = 7, character = 15}, end = {line = 7, character = 19}}},
		{range = {start = {line = 8, character = 10}, end = {line = 8, character = 14}}},
		{range = {start = {line = 10, character = 12}, end = {line = 10, character = 16}}},
	}

	test.expect_rename_locations(t, &source, "label", locations[:])
}

@(test)
ast_rename_one_field_from_multi_name_declaration :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Point :: struct {
x{*}, y: int
}

main :: proc() {
point := Point{x = 1, y = 2}
_ = point.x
_ = point.y
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 0}, end = {line = 3, character = 1}}},
		{range = {start = {line = 7, character = 15}, end = {line = 7, character = 16}}},
		{range = {start = {line = 8, character = 10}, end = {line = 8, character = 11}}},
	}
	excluded := []common.Location {
		{range = {start = {line = 3, character = 3}, end = {line = 3, character = 4}}},
		{range = {start = {line = 7, character = 22}, end = {line = 7, character = 23}}},
		{range = {start = {line = 9, character = 10}, end = {line = 9, character = 11}}},
	}

	test.expect_rename_locations(t, &source, "x_value", locations[:], excluded[:])
}

@(test)
ast_rename_enum_variant_in_bit_set_literal :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Flags :: enum {
Read,
Write,
}

Flag_Set :: bit_set[Flags]

main :: proc() {
flags: Flag_Set
flags += {.Re{*}ad}
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 3, character = 0}, end = {line = 3, character = 4}}},
		{range = {start = {line = 11, character = 11}, end = {line = 11, character = 15}}},
	}

	test.expect_rename_locations(t, &source, "Read_Flag", locations[:])
}

@(test)
ast_rename_union_variant_type_and_switch_case :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Number :: struct {}
Text :: struct {}

Value :: union {
Num{*}ber,
Text,
}

main :: proc(value: Value) {
#partial switch item in value {
case Number:
_ = item
}
}
`,
	}

	locations := []common.Location {
		{range = {start = {line = 2, character = 0}, end = {line = 2, character = 6}}},
		{range = {start = {line = 6, character = 0}, end = {line = 6, character = 6}}},
		{range = {start = {line = 12, character = 5}, end = {line = 12, character = 11}}},
	}

	test.expect_rename_locations(t, &source, "Integer", locations[:])
}

@(test)
ast_rename_does_not_edit_basic_literals :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
_ = 123{*}
_ = "123"
}
`,
	}

	locations := []common.Location{}
	test.expect_rename_locations(t, &source, "renamed", locations)
}

@(test)
ast_prepare_rename_identifier_use :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
value := 1
_ = val{*}ue
}
`,
	}

	range := common.Range {
		start = {line = 4, character = 4},
		end = {line = 4, character = 9},
	}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
ast_prepare_rename_rejects_whitespace :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {}
{*}
`,
	}

	test.expect_prepare_rename_unavailable(t, &source)
}

@(test)
rename_imported_package_symbol_returns_workspace_edit_uris :: proc(t: ^testing.T) {
	rename_reset_global_config()
	defer rename_reset_global_config()

	server.setup_index(server.get_builtin_path())
	defer server.free_index()

	root, err := os.make_directory_temp("", "ols-rename-*", context.temp_allocator)
	if err != nil {
		log.errorf("failed to create temp directory: %v", err)
		return
	}
	defer os.remove_all(root)

	app_dir := path.join({root, "app"}, context.temp_allocator)
	dep_dir := path.join({root, "dep"}, context.temp_allocator)
	if err = os.mkdir_all(app_dir); err != nil {
		log.errorf("failed to create app directory: %v", err)
		return
	}
	if err = os.mkdir_all(dep_dir); err != nil {
		log.errorf("failed to create dep directory: %v", err)
		return
	}

	main_source, position, cursor_ok := rename_extract_cursor(
		`package app
import dep "../dep"

main :: proc() {
_ = dep.sha{*}red()
}
`,
	)
	if !cursor_ok {
		log.error("failed to extract rename cursor")
		return
	}

	dep_source := `package dep

shared :: proc() {}
`
	dep_use_source := `package dep

use_shared :: proc() {
_ = shared()
}
`

	main_file := path.join({app_dir, "main.odin"}, context.temp_allocator)
	dep_file := path.join({dep_dir, "shared.odin"}, context.temp_allocator)
	dep_use_file := path.join({dep_dir, "use.odin"}, context.temp_allocator)
	if err = os.write_entire_file(main_file, main_source); err != nil {
		log.errorf("failed to write app file: %v", err)
		return
	}
	if err = os.write_entire_file(dep_file, dep_source); err != nil {
		log.errorf("failed to write dependency file: %v", err)
		return
	}
	if err = os.write_entire_file(dep_use_file, dep_use_source); err != nil {
		log.errorf("failed to write dependency use file: %v", err)
		return
	}
	if index_err := server.index_file(common.create_uri(dep_file, context.temp_allocator), dep_source);
	   index_err != .None {
		log.errorf("failed to index dependency file: %v", index_err)
		return
	}
	if index_err := server.index_file(common.create_uri(dep_use_file, context.temp_allocator), dep_use_source);
	   index_err != .None {
		log.errorf("failed to index dependency use file: %v", index_err)
		return
	}

	allocator := new(virtual.Arena, context.temp_allocator)
	_ = virtual.arena_init_growing(allocator)
	defer virtual.arena_destroy(allocator)

	document := server.Document {
		fullpath  = main_file,
		uri       = common.create_uri(main_file, context.temp_allocator),
		text      = transmute([]u8)main_source,
		used_text = len(main_source),
		allocator = allocator,
	}
	server.document_setup(&document)
	if refresh_err := server.document_refresh(&document, &common.config, nil); refresh_err != .None {
		log.errorf("document_refresh failed: %v", refresh_err)
		return
	}
	_, references_ok := server.get_references(&document, position, config = &common.config)
	if !references_ok {
		log.error("get_references failed while preparing workspace rename")
		return
	}

	edit, ok := server.get_rename(&document, "renamed", position, &common.config)
	if !ok {
		log.error("get_rename failed")
		return
	}

	main_uri := common.create_uri(main_file, context.temp_allocator).uri
	dep_uri := common.create_uri(dep_file, context.temp_allocator).uri
	dep_use_uri := common.create_uri(dep_use_file, context.temp_allocator).uri
	expected := []common.Location {
		{uri = main_uri, range = {start = {line = 4, character = 8}, end = {line = 4, character = 14}}},
		{uri = dep_uri, range = {start = {line = 2, character = 0}, end = {line = 2, character = 6}}},
		{uri = dep_use_uri, range = {start = {line = 3, character = 4}, end = {line = 3, character = 10}}},
	}

	actual := make([dynamic]common.Location, context.temp_allocator)
	for uri, edits in edit.changes {
		for text_edit in edits {
			if text_edit.newText != "renamed" {
				log.errorf("expected rename text %q, got %q", "renamed", text_edit.newText)
			}
			append(&actual, common.Location{uri = uri, range = text_edit.range})
		}
	}

	if len(actual) != len(expected) {
		log.errorf("expected %d workspace edits, got %d: %v", len(expected), len(actual), actual[:])
	}
	for want in expected {
		found := false
		for got in actual {
			if got.uri == want.uri && got.range == want.range {
				found = true
				break
			}
		}
		if !found {
			log.errorf("missing workspace edit: %v", want)
		}
	}
}
