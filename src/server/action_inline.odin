#+private file

package server

import "core:fmt"
import "core:mem"
import "core:odin/ast"
import "core:os"
import "core:slice"
import "core:strings"

import "src:common"

INLINE_VARIABLE_ACTION :: "Inline variable"
INLINE_CONSTANT_ACTION :: "Inline constant"
INLINE_FUNCTION_ACTION :: "Inline function"

InlineReturnRewrite :: struct {
	start:       int,
	end:         int,
	replacement: string,
}

InlineOffsetRange :: struct {
	start: int,
	end:   int,
}

InlineReturnSlot :: struct {
	name:      string,
	type_text: string,
}

InlineParamSpec :: struct {
	name:      string,
	type_text: string,
}

InlineActionDocument :: struct {
	document:      ^Document,
	temp_document: ^Document,
}

@(private = "package")
add_inline_action :: proc(
	document: ^Document,
	ast_context: ^AstContext,
	position_context: ^DocumentPositionContext,
	config: ^common.Config,
	uri: string,
	actions: ^[dynamic]CodeAction,
) {
	if position_context.identifier == nil {
		return
	}

	ident, ident_ok := position_context.identifier.derived.(^ast.Ident)
	if !ident_ok {
		return
	}

	resolved_symbol, resolved_ok := resolve_type_identifier(ast_context, ident^)
	if !resolved_ok {
		return
	}

	declaration_symbol, declaration_ok := resolve_location_identifier(ast_context, ident^)
	if !declaration_ok || !strings.equal_fold(declaration_symbol.uri, uri) {
		return
	}

	if action, ok := build_inline_function_action(
		document,
		ast_context,
		position_context,
		resolved_symbol,
		declaration_symbol,
		config,
		uri,
	); ok {
		append(actions, action)
		return
	}

	if action, ok := build_inline_value_action(
		document,
		ast_context,
		position_context,
		resolved_symbol,
		declaration_symbol,
		config,
		uri,
	); ok {
		append(actions, action)
	}
}

position_in_range :: proc(position: common.Position, range: common.Range) -> bool {
	if position.line < range.start.line || position.line > range.end.line {
		return false
	}

	if position.line == range.start.line && position.character < range.start.character {
		return false
	}

	if position.line == range.end.line && position.character > range.end.character {
		return false
	}

	return true
}

range_inside_range :: proc(inner, outer: common.Range) -> bool {
	return position_in_range(inner.start, outer) && position_in_range(inner.end, outer)
}

append_workspace_edit :: proc(changes: ^map[string][dynamic]TextEdit, uri: string, edit: TextEdit) {
	edits := &changes[uri]
	if edits == nil {
		changes[strings.clone(uri, context.temp_allocator)] = make([dynamic]TextEdit, 0, context.temp_allocator)
		edits = &changes[uri]
	}

	append(edits, edit)
}

sort_workspace_edits_desc :: proc(edits: []TextEdit) {
	if len(edits) < 2 {
		return
	}

	slice.sort_by(edits, proc(a, b: TextEdit) -> bool {
		if a.range.start.line != b.range.start.line {
			return a.range.start.line > b.range.start.line
		}
		if a.range.start.character != b.range.start.character {
			return a.range.start.character > b.range.start.character
		}
		if a.range.end.line != b.range.end.line {
			return a.range.end.line > b.range.end.line
		}
		return a.range.end.character > b.range.end.character
	})
}

make_workspace_edit_from_dynamic_map :: proc(changes: map[string][dynamic]TextEdit) -> WorkspaceEdit {
	workspace_edit := WorkspaceEdit{}
	workspace_edit.changes = make(map[string][]TextEdit, len(changes), context.temp_allocator)

	for uri, edits in changes {
		sort_workspace_edits_desc(edits[:])
		workspace_edit.changes[uri] = edits[:]
	}

	return workspace_edit
}

load_inline_action_document :: proc(uri_string: string, config: ^common.Config) -> (InlineActionDocument, bool) {
	if document := document_get(uri_string); document != nil {
		return InlineActionDocument{document = document}, true
	}

	uri, parsed_ok := common.parse_uri(uri_string, context.temp_allocator)
	if !parsed_ok {
		return {}, false
	}

	data, err := os.read_entire_file(uri.path, context.temp_allocator)
	if err != nil {
		return {}, false
	}

	temp_document := new(Document, context.temp_allocator)
	temp_document.uri = uri
	temp_document.text = data
	temp_document.used_text = len(data)
	temp_document.allocator = document_get_allocator()

	document_setup(temp_document)

	old_allocator := context.allocator
	defer context.allocator = old_allocator

	_, ok := parse_document(temp_document, config)
	if !ok {
		document_free_allocator(temp_document.allocator)
		temp_document.allocator = nil
		return {}, false
	}

	return InlineActionDocument{
		document = temp_document,
		temp_document = temp_document,
	}, true
}

release_inline_action_document :: proc(loaded: ^InlineActionDocument) {
	if loaded.document == nil {
		return
	}

	if loaded.temp_document != nil {
		document_free_allocator(loaded.temp_document.allocator)
		loaded.temp_document.allocator = nil
	} else {
		document_release(loaded.document)
	}
}

get_inline_reference_locations :: proc(
	document: ^Document,
	ast_context: ^AstContext,
	position_context: ^DocumentPositionContext,
	declaration_symbol: Symbol,
	config: ^common.Config,
) -> ([]common.Location, bool) {
	locations, ok := resolve_references(
		document,
		ast_context,
		position_context,
		config,
		false,
		false,
	)
	if !ok {
		return {}, false
	}

	if position_context.value_decl == nil {
		return locations, true
	}

	declaration_range := common.get_token_range(position_context.value_decl^, ast_context.file.src)
	filtered := make([dynamic]common.Location, 0, context.temp_allocator)

	for location in locations {
		if strings.equal_fold(location.uri, declaration_symbol.uri) &&
		   range_inside_range(location.range, declaration_range) {
			continue
		}

		append(&filtered, location)
	}

	return filtered[:], true
}

get_inline_value_text :: proc(ast_context: ^AstContext, resolved_symbol: Symbol) -> (string, bool) {
	value_text := ast_context.file.src[resolved_symbol.value_expr.pos.offset:resolved_symbol.value_expr.end.offset]
	if comp_lit, is_comp_lit := resolved_symbol.value_expr.derived.(^ast.Comp_Lit); is_comp_lit &&
		comp_lit.type == nil && resolved_symbol.type_expr != nil {
		type_text := strings.trim_space(
			ast_context.file.src[resolved_symbol.type_expr.pos.offset:resolved_symbol.type_expr.end.offset],
		)
		if type_text != "" {
			value_text = strings.concatenate({type_text, value_text}, context.temp_allocator)
		}
	}

	if strings.trim_space(value_text) == "" {
		return "", false
	}

	return value_text, true
}

build_inline_value_action :: proc(
	document: ^Document,
	ast_context: ^AstContext,
	position_context: ^DocumentPositionContext,
	resolved_symbol: Symbol,
	declaration_symbol: Symbol,
	config: ^common.Config,
	uri: string,
) -> (CodeAction, bool) {
	if resolved_symbol.value_expr == nil {
		return {}, false
	}

	if _, is_proc := resolved_symbol.value_expr.derived.(^ast.Proc_Lit); is_proc {
		return {}, false
	}

	value_decl_range := declaration_symbol.range
	ident_range := common.get_token_range(position_context.identifier^, ast_context.file.src)

	if resolved_symbol.type != .Variable && resolved_symbol.type != .Constant {
		return {}, false
	}

	value_text, value_ok := get_inline_value_text(ast_context, resolved_symbol)
	if !value_ok {
		return {}, false
	}

	title := INLINE_VARIABLE_ACTION
	if resolved_symbol.type == .Constant {
		title = INLINE_CONSTANT_ACTION
	}

	if strings.equal_fold(declaration_symbol.uri, uri) && value_decl_range == ident_range {
		locations, ok := get_inline_reference_locations(
			document,
			ast_context,
			position_context,
			declaration_symbol,
			config,
		)
		if !ok || len(locations) == 0 {
			return {}, false
		}

		changes := make(map[string][dynamic]TextEdit, 0, context.temp_allocator)
		for location in locations {
			append_workspace_edit(
				&changes,
				location.uri,
				TextEdit{
					range = location.range,
					newText = value_text,
				},
			)
		}

		return CodeAction{
				title = title,
				kind = "refactor.inline",
				edit = make_workspace_edit_from_dynamic_map(changes),
				isPreferred = false,
			},
			true
	}

	edit := TextEdit{
		range = ident_range,
		newText = value_text,
	}

	text_edits := make([dynamic]TextEdit, 0, context.temp_allocator)
	append(&text_edits, edit)

	workspace_edit := WorkspaceEdit{}
	workspace_edit.changes = make(map[string][]TextEdit, 0, context.temp_allocator)
	workspace_edit.changes[uri] = text_edits[:]

	return CodeAction{
			title = title,
			kind = "refactor.inline",
			edit = workspace_edit,
			isPreferred = false,
		},
		true
}

build_inline_function_action :: proc(
	document: ^Document,
	ast_context: ^AstContext,
	position_context: ^DocumentPositionContext,
	resolved_symbol: Symbol,
	declaration_symbol: Symbol,
	config: ^common.Config,
	uri: string,
) -> (CodeAction, bool) {
	if resolved_symbol.value_expr == nil {
		return {}, false
	}

	proc_lit, proc_ok := resolved_symbol.value_expr.derived.(^ast.Proc_Lit)
	if !proc_ok {
		return {}, false
	}

	if position_context.call != nil {
		edit, edit_ok := build_inline_function_edit(
			ast_context.file.src,
			ast_context.file.src,
			declaration_symbol.name,
			proc_lit,
			position_context,
		)
		if !edit_ok {
			return {}, false
		}

		text_edits := make([dynamic]TextEdit, 0, context.temp_allocator)
		append(&text_edits, edit)

		workspace_edit := WorkspaceEdit{}
		workspace_edit.changes = make(map[string][]TextEdit, 0, context.temp_allocator)
		workspace_edit.changes[uri] = text_edits[:]

		return CodeAction{
				title = INLINE_FUNCTION_ACTION,
				kind = "refactor.inline",
				edit = workspace_edit,
				isPreferred = false,
			},
			true
	}

	ident_range := common.get_token_range(position_context.identifier^, ast_context.file.src)
	if !strings.equal_fold(declaration_symbol.uri, uri) || declaration_symbol.range != ident_range {
		return {}, false
	}

	locations, ok := get_inline_reference_locations(
		document,
		ast_context,
		position_context,
		declaration_symbol,
		config,
	)
	if !ok || len(locations) == 0 {
		return {}, false
	}

	changes := make(map[string][dynamic]TextEdit, 0, context.temp_allocator)

	for location in locations {
		reference_document := document
		loaded_document: InlineActionDocument

		if !strings.equal_fold(location.uri, document.uri.uri) {
			load_ok: bool
			loaded_document, load_ok = load_inline_action_document(location.uri, config)
			if !load_ok {
				return {}, false
			}
			reference_document = loaded_document.document
		}

		position_context, context_ok := get_document_position_context(
			reference_document,
			location.range.start,
			.Hover,
		)
		if !context_ok || position_context.call == nil {
			if loaded_document.document != nil {
				release_inline_action_document(&loaded_document)
			}
			return {}, false
		}

		edit, edit_ok := build_inline_function_edit(
			ast_context.file.src,
			reference_document.ast.src,
			declaration_symbol.name,
			proc_lit,
			&position_context,
		)
		if !edit_ok {
			if loaded_document.document != nil {
				release_inline_action_document(&loaded_document)
			}
			return {}, false
		}

		append_workspace_edit(
			&changes,
			location.uri,
			edit,
		)

		if loaded_document.document != nil {
			release_inline_action_document(&loaded_document)
		}
	}

	if delete_edit, delete_ok := build_inline_function_definition_delete_edit(
		ast_context.file.src,
		position_context.value_decl,
	); delete_ok {
		append_workspace_edit(&changes, uri, delete_edit)
	}

	return CodeAction{
			title = INLINE_FUNCTION_ACTION,
			kind = "refactor.inline",
			edit = make_workspace_edit_from_dynamic_map(changes),
			isPreferred = false,
		},
			true
}

build_inline_function_edit :: proc(
	proc_source: string,
	call_source: string,
	function_name: string,
	proc_lit: ^ast.Proc_Lit,
	position_context: ^DocumentPositionContext,
) -> (TextEdit, bool) {
	if position_context == nil || position_context.call == nil {
		return {}, false
	}

	call_expr, call_ok := position_context.call.derived.(^ast.Call_Expr)
	if !call_ok {
		return {}, false
	}

	if if_stmt_text, if_stmt_ok := build_inline_if_stmt_text(
		proc_source,
		call_source,
		function_name,
		proc_lit,
		call_expr,
		position_context.if_stmt,
		position_context.unary,
	); if_stmt_ok {
		return TextEdit{
				range = common.get_token_range(position_context.if_stmt^, call_source),
				newText = if_stmt_text,
			},
			true
	}

	if value_decl_text, value_decl_ok := build_inline_value_decl_text(
		proc_source,
		call_source,
		function_name,
		proc_lit,
		call_expr,
		position_context.value_decl,
	); value_decl_ok {
		return TextEdit{
				range = common.get_token_range(position_context.value_decl^, call_source),
				newText = value_decl_text,
			},
			true
	}

	if expr_stmt_text, expr_stmt_ok := build_inline_expr_stmt_text(
		proc_source,
		call_source,
		function_name,
		proc_lit,
		call_expr,
		position_context.expr_stmt,
	); expr_stmt_ok {
		return TextEdit{
				range = common.get_token_range(position_context.expr_stmt^, call_source),
				newText = expr_stmt_text,
			},
			true
	}

	call_range := common.get_token_range(position_context.call^, call_source)
	inline_text, inline_ok := build_inline_call_text(
		proc_source,
		call_source,
		function_name,
		proc_lit,
		call_expr,
	)
	if !inline_ok || inline_text == "" {
		return {}, false
	}

	return TextEdit{
			range = call_range,
			newText = inline_text,
		},
		true
}

get_inline_stmt_body_text :: proc(source: string, stmt: ^ast.Stmt) -> (string, bool) {
	if stmt == nil {
		return "", false
	}

	if block, block_ok := stmt.derived.(^ast.Block_Stmt); block_ok {
		if block.open.offset + 1 > block.close.offset {
			return "", false
		}
		text := strings.trim_space(source[block.open.offset + 1:block.close.offset])
		return text, text != ""
	}

	text := strings.trim_space(source[stmt.pos.offset:stmt.end.offset])
	return text, text != ""
}

get_inline_block_inner_text :: proc(source: string, block: ^ast.Block_Stmt) -> (string, bool) {
	if block == nil || block.open.offset + 1 > block.close.offset {
		return "", false
	}

	return source[block.open.offset + 1:block.close.offset], true
}

reindent_inline_text :: proc(text, indent: string, include_first_line := true) -> string {
	trimmed := strings.trim_space(text)
	if trimmed == "" {
		return ""
	}

	min_indent := -1
	line_start := 0
	for i := 0; i <= len(trimmed); i += 1 {
		if i < len(trimmed) && trimmed[i] != '\n' {
			continue
		}

		line := strings.trim_right(trimmed[line_start:i], "\r")
		if strings.trim_space(line) != "" {
			line_indent := 0
			for line_indent < len(line) && (line[line_indent] == ' ' || line[line_indent] == '\t') {
				line_indent += 1
			}
			if min_indent < 0 || line_indent < min_indent {
				min_indent = line_indent
			}
		}

		line_start = i + 1
	}

	if min_indent < 0 {
		min_indent = 0
	}

	builder := strings.builder_make(context.temp_allocator)
	line_start = 0
	wrote_line := false
	for i := 0; i <= len(trimmed); i += 1 {
		if i < len(trimmed) && trimmed[i] != '\n' {
			continue
		}

		line := strings.trim_right(trimmed[line_start:i], "\r")
		if wrote_line {
			strings.write_string(&builder, "\n")
		}
		if include_first_line || wrote_line {
			strings.write_string(&builder, indent)
		}
		if len(line) > min_indent {
			strings.write_string(&builder, line[min_indent:])
		}
		wrote_line = true
		line_start = i + 1
	}

	return strings.to_string(builder)
}

reindent_inline_block_text :: proc(text, indent: string, include_first_line := true) -> string {
	if strings.trim_space(text) == "" {
		return ""
	}

	start := 0
	for start < len(text) {
		line_end := start
		for line_end < len(text) && text[line_end] != '\n' {
			line_end += 1
		}

		line := strings.trim_right(text[start:line_end], "\r")
		if strings.trim_space(line) != "" {
			break
		}

		start = line_end
		if start < len(text) && text[start] == '\n' {
			start += 1
		}
	}

	end := len(text)
	for end > start {
		line_start := end
		for line_start > start && text[line_start - 1] != '\n' {
			line_start -= 1
		}

		line := strings.trim_right(text[line_start:end], "\r")
		if strings.trim_space(line) != "" {
			break
		}

		end = line_start - 1
		if end < start {
			end = start
		}
	}

	trimmed := text[start:end]

	min_indent := -1
	line_start := 0
	for i := 0; i <= len(trimmed); i += 1 {
		if i < len(trimmed) && trimmed[i] != '\n' {
			continue
		}

		line := strings.trim_right(trimmed[line_start:i], "\r")
		if strings.trim_space(line) != "" {
			line_indent := 0
			for line_indent < len(line) && (line[line_indent] == ' ' || line[line_indent] == '\t') {
				line_indent += 1
			}
			if min_indent < 0 || line_indent < min_indent {
				min_indent = line_indent
			}
		}

		line_start = i + 1
	}

	if min_indent < 0 {
		min_indent = 0
	}

	builder := strings.builder_make(context.temp_allocator)
	line_start = 0
	wrote_line := false
	for i := 0; i <= len(trimmed); i += 1 {
		if i < len(trimmed) && trimmed[i] != '\n' {
			continue
		}

		line := strings.trim_right(trimmed[line_start:i], "\r")
		if wrote_line {
			strings.write_string(&builder, "\n")
		}
		if include_first_line || wrote_line {
			strings.write_string(&builder, indent)
		}
		if len(line) > min_indent {
			strings.write_string(&builder, line[min_indent:])
		}

		wrote_line = true
		line_start = i + 1
	}

	return strings.to_string(builder)
}

block_has_inline_returns :: proc(body: ^ast.Block_Stmt) -> bool {
	if body == nil {
		return false
	}

	ReturnData :: struct {
		found: ^bool,
	}

	found_return := false
	return_data := ReturnData{
		found = &found_return,
	}
	collector := ast.Visitor{
		data = &return_data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}

			data := cast(^ReturnData)visitor.data
			if data.found^ {
				return nil
			}

			if _, is_nested_proc := node.derived.(^ast.Proc_Lit); is_nested_proc {
				return nil
			}

			if _, is_return := node.derived.(^ast.Return_Stmt); is_return {
				data.found^ = true
				return nil
			}

			return visitor
		},
	}

	for stmt in body.stmts {
		ast.walk(&collector, stmt)
		if found_return {
			break
		}
	}

	return found_return
}

get_inline_decl_line_start_offset :: proc(source: string, offset: int) -> int {
	line_start := offset
	for line_start > 0 && source[line_start - 1] != '\n' {
		line_start -= 1
	}
	return line_start
}

consume_line_ending :: proc(source: string, offset: int) -> int {
	line_end := offset
	if line_end >= len(source) {
		return line_end
	}

	if source[line_end] == '\r' {
		line_end += 1
		if line_end < len(source) && source[line_end] == '\n' {
			line_end += 1
		}
		return line_end
	}

	if source[line_end] == '\n' {
		line_end += 1
	}

	return line_end
}

line_is_blank :: proc(source: string, offset: int) -> bool {
	if offset >= len(source) {
		return false
	}

	for i := offset; i < len(source); i += 1 {
		if source[i] == '\n' || source[i] == '\r' {
			return true
		}
		if source[i] != ' ' && source[i] != '\t' {
			return false
		}
	}

	return true
}

collect_inline_body_declared_names :: proc(body: ^ast.Block_Stmt) -> map[string]struct{} {
	declared := make(map[string]struct{}, 0, context.temp_allocator)
	if body == nil {
		return declared
	}

	collector := ast.Visitor{
		data = &declared,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}

			if _, is_nested_proc := node.derived.(^ast.Proc_Lit); is_nested_proc {
				return nil
			}

			declared := cast(^map[string]struct{})visitor.data

			if value_decl, ok := node.derived.(^ast.Value_Decl); ok {
				for name_expr in value_decl.names {
					if ident, ident_ok := name_expr.derived.(^ast.Ident); ident_ok && ident.name != "" && ident.name != "_" {
						declared[ident.name] = {}
					}
				}
				return visitor
			}

			if assign_stmt, ok := node.derived.(^ast.Assign_Stmt); ok && assign_stmt.op.text == ":=" {
				for lhs_expr in assign_stmt.lhs {
					if ident, ident_ok := lhs_expr.derived.(^ast.Ident); ident_ok && ident.name != "" && ident.name != "_" {
						declared[ident.name] = {}
					}
				}
			}

			return visitor
		},
	}

	for stmt in body.stmts {
		ast.walk(&collector, stmt)
	}

	return declared
}

inline_return_slots_conflict_with_body :: proc(body: ^ast.Block_Stmt, return_slots: []InlineReturnSlot) -> bool {
	declared := collect_inline_body_declared_names(body)
	for slot in return_slots {
		if slot.name in declared {
			return true
		}
	}
	return false
}

build_inline_temp_return_slots :: proc(
	proc_source: string,
	call_source: string,
	proc_return_slots: []InlineReturnSlot,
) -> ([]InlineReturnSlot, map[string]string) {
	temp_slots := make([dynamic]InlineReturnSlot, 0, context.temp_allocator)
	renames := make(map[string]string, 0, context.temp_allocator)
	used_names := make(map[string]struct{}, 0, context.temp_allocator)

	for slot in proc_return_slots {
		for i := 0; ; i += 1 {
			candidate := fmt.tprintf("__ols_inline_ret_%d", i)
			if candidate in used_names || strings.contains(proc_source, candidate) || strings.contains(call_source, candidate) {
				continue
			}

			append(&temp_slots, InlineReturnSlot{
				name = candidate,
				type_text = slot.type_text,
			})
			used_names[candidate] = {}

			if slot.name != candidate {
				renames[slot.name] = candidate
			}

			break
		}
	}

	return temp_slots[:], renames
}

build_inline_function_definition_delete_edit :: proc(
	source: string,
	value_decl: ^ast.Value_Decl,
) -> (TextEdit, bool) {
	if value_decl == nil || len(value_decl.names) != 1 || len(value_decl.values) != 1 {
		return {}, false
	}

	start_offset := value_decl.pos.offset
	if value_decl.docs != nil {
		start_offset = min(start_offset, value_decl.docs.pos.offset)
	}
	for attr in value_decl.attributes {
		if attr != nil {
			start_offset = min(start_offset, attr.pos.offset)
		}
	}

	end_offset := value_decl.end.offset
	if value_decl.comment != nil {
		end_offset = max(end_offset, value_decl.comment.end.offset)
	}

	start_offset = get_inline_decl_line_start_offset(source, start_offset)
	for end_offset < len(source) && source[end_offset] != '\n' && source[end_offset] != '\r' {
		end_offset += 1
	}
	end_offset = consume_line_ending(source, end_offset)

	if line_is_blank(source, end_offset) {
		blank_line_end := end_offset
		for blank_line_end < len(source) &&
			source[blank_line_end] != '\n' &&
			source[blank_line_end] != '\r' {
			blank_line_end += 1
		}
		end_offset = consume_line_ending(source, blank_line_end)
	}

	source_bytes := transmute([]u8)source

	return TextEdit{
			range = {
				start = common.get_relative_token_position(start_offset, source_bytes, 0),
				end = common.get_relative_token_position(end_offset, source_bytes, 0),
			},
			newText = "",
		},
		true
}

build_inline_if_return_rewrite :: proc(
	source: string,
	ret_stmt: ^ast.Return_Stmt,
	function_name: string,
	fail_body_text: string,
	fail_flag_name := "",
) -> (string, bool) {
	indent := get_line_indentation(source, ret_stmt.pos.offset)
	fail_text := reindent_inline_text(fail_body_text, indent, false)

	if len(ret_stmt.results) == 0 {
		return "", false
	}

	if len(ret_stmt.results) != 1 {
		return "", false
	}

	result_text := strings.trim_space(source[ret_stmt.results[0].pos.offset:ret_stmt.results[0].end.offset])
	if result_text == "" {
		return "", false
	}

	if result_text == "true" {
		return fmt.tprintf("break %s", function_name), true
	}

	if fail_flag_name != "" {
		if result_text == "false" {
			return strings.concatenate({
				fail_flag_name,
				" = true",
				"\n",
				indent,
				fmt.tprintf("break %s", function_name),
			}, context.temp_allocator), true
		}

		builder := strings.builder_make(context.temp_allocator)
		fmt.sbprint(
			&builder,
			"if !(",
			result_text,
			") {\n",
			indent,
			"\t",
			fail_flag_name,
			" = true\n",
			indent,
			"\tbreak ",
			function_name,
			"\n",
			indent,
			"}\n",
			indent,
			"break ",
			function_name,
			sep = "",
		)
		return strings.to_string(builder), true
	}

	if result_text == "false" {
		return strings.concatenate({
			fail_text,
			"\n",
			indent,
			fmt.tprintf("break %s", function_name),
		}, context.temp_allocator), true
	}

	builder := strings.builder_make(context.temp_allocator)
	fmt.sbprint(&builder, "if ", result_text, " {\n", indent, "\tbreak ", function_name, "\n", indent, "}", sep = "")
	if fail_text != "" {
		fail_text = reindent_inline_text(fail_body_text, indent, true)
		fmt.sbprint(&builder, "\n", fail_text, "\n", indent, "break ", function_name, sep = "")
	}

	return strings.to_string(builder), true
}

count_inline_bool_if_fail_sites :: proc(source: string, body: ^ast.Block_Stmt) -> (int, bool) {
	AnalysisData :: struct {
		source:     string,
		fail_sites: ^int,
		ok:         ^bool,
	}

	fail_sites := 0
	valid := true
	analysis_data := AnalysisData{
		source = source,
		fail_sites = &fail_sites,
		ok = &valid,
	}

	collector := ast.Visitor{
		data = &analysis_data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}

			data := cast(^AnalysisData)visitor.data
			if !data.ok^ {
				return nil
			}

			if _, is_nested_proc := node.derived.(^ast.Proc_Lit); is_nested_proc {
				return nil
			}

			ret_stmt, is_return := node.derived.(^ast.Return_Stmt)
			if !is_return {
				return visitor
			}

			if len(ret_stmt.results) != 1 {
				data.ok^ = false
				return nil
			}

			result_text := strings.trim_space(data.source[ret_stmt.results[0].pos.offset:ret_stmt.results[0].end.offset])
			if result_text == "" {
				data.ok^ = false
				return nil
			}

			if result_text != "true" {
				data.fail_sites^ += 1
			}

			return visitor
		},
	}

	for stmt in body.stmts {
		ast.walk(&collector, stmt)
	}

	return fail_sites, valid
}

rewrite_inline_bool_if_body :: proc(
	source: string,
	body: ^ast.Block_Stmt,
	function_name: string,
	fail_body_text: string,
	fail_flag_name := "",
) -> (string, bool) {
	rewrites := make([dynamic]InlineReturnRewrite, 0, context.temp_allocator)

	RewriteData :: struct {
		source:         string,
		function_name:  string,
		fail_body_text: string,
		fail_flag_name: string,
		rewrites:       ^[dynamic]InlineReturnRewrite,
		ok:             ^bool,
	}

	valid := true
	rewrite_data := RewriteData{
		source = source,
		function_name = function_name,
		fail_body_text = fail_body_text,
		fail_flag_name = fail_flag_name,
		rewrites = &rewrites,
		ok = &valid,
	}

	collector := ast.Visitor{
		data = &rewrite_data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}

			data := cast(^RewriteData)visitor.data
			if !data.ok^ {
				return nil
			}

			if _, is_nested_proc := node.derived.(^ast.Proc_Lit); is_nested_proc {
				return nil
			}

			ret_stmt, is_return := node.derived.(^ast.Return_Stmt)
			if !is_return {
				return visitor
			}

			replacement_text, ok := build_inline_if_return_rewrite(
				data.source,
				ret_stmt,
				data.function_name,
				data.fail_body_text,
				data.fail_flag_name,
			)
			if !ok {
				data.ok^ = false
				return nil
			}

			append(data.rewrites, InlineReturnRewrite{
				start = ret_stmt.pos.offset,
				end = ret_stmt.end.offset,
				replacement = replacement_text,
			})

			return visitor
		},
	}

	for stmt in body.stmts {
		ast.walk(&collector, stmt)
	}

	if !valid {
		return "", false
	}

	slice.sort_by(rewrites[:], proc(a, b: InlineReturnRewrite) -> bool {
		return b.start < a.start
	})

	start := body.pos.offset
	end := body.end.offset
	out := source[start:end]

	for rewrite in rewrites {
		rel_start := rewrite.start - start
		rel_end := rewrite.end - start
		if rel_start < 0 || rel_end > len(out) || rel_start > rel_end {
			return "", false
		}

		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, out[:rel_start])
		strings.write_string(&b, rewrite.replacement)
		strings.write_string(&b, out[rel_end:])
		out = strings.to_string(b)
	}

	return strings.trim_space(out), true
}

build_inline_if_stmt_text :: proc(
	proc_source: string,
	call_source: string,
	function_name: string,
	proc_lit: ^ast.Proc_Lit,
	call_expr: ^ast.Call_Expr,
	if_stmt: ^ast.If_Stmt,
	unary_expr: ^ast.Unary_Expr,
) -> (string, bool) {
	if if_stmt == nil || unary_expr == nil || if_stmt.init != nil || if_stmt.else_stmt != nil || if_stmt.cond == nil {
		return "", false
	}

	if if_stmt.cond.pos.offset != unary_expr.pos.offset ||
		if_stmt.cond.end.offset != unary_expr.end.offset ||
		unary_expr.expr == nil ||
		unary_expr.expr.pos.offset != call_expr.pos.offset ||
		unary_expr.expr.end.offset != call_expr.end.offset {
		return "", false
	}

	if unary_expr.pos.offset >= len(call_source) || call_source[unary_expr.pos.offset] != '!' {
		return "", false
	}

	proc_type, type_ok := proc_lit.type.derived.(^ast.Proc_Type)
	if !type_ok {
		return "", false
	}

	param_specs, params_ok := collect_inline_param_specs(proc_source, proc_type)
	if !params_ok || len(param_specs) != len(call_expr.args) {
		return "", false
	}

	arg_texts := make([dynamic]string, 0, context.temp_allocator)
	for arg_expr in call_expr.args {
		if _, is_named_arg := arg_expr.derived.(^ast.Field_Value); is_named_arg {
			return "", false
		}
		arg_text := strings.trim_space(call_source[arg_expr.pos.offset:arg_expr.end.offset])
		if arg_text == "" {
			return "", false
		}
		append(&arg_texts, arg_text)
	}

	return_slots, slots_ok := collect_inline_return_slots(proc_source, proc_type)
	if !slots_ok || len(return_slots) != 1 || strings.trim_space(return_slots[0].type_text) != "bool" {
		return "", false
	}

	body, body_ok := proc_lit.body.derived.(^ast.Block_Stmt)
	if !body_ok {
		return "", false
	}

	fail_body_text, fail_ok := get_inline_stmt_body_text(call_source, if_stmt.body)
	if !fail_ok {
		return "", false
	}

	fail_site_count, fail_sites_ok := count_inline_bool_if_fail_sites(proc_source, body)
	if !fail_sites_ok {
		return "", false
	}

	fail_flag_name := ""
	if fail_site_count > 1 {
		for i := 0; ; i += 1 {
			candidate := fmt.tprintf("__ols_inline_failed_%d", i)
			if !strings.contains(proc_source, candidate) && !strings.contains(call_source, candidate) {
				fail_flag_name = candidate
				break
			}
		}
	}

	rewritten_body, rewrite_ok := rewrite_inline_bool_if_body(
		proc_source,
		body,
		function_name,
		fail_body_text,
		fail_flag_name,
	)
	if !rewrite_ok {
		return "", false
	}

	indent := get_line_indentation(call_source, if_stmt.pos.offset)
	builder := strings.builder_make(context.temp_allocator)
	wrote_prefix := false

	for param_spec, i in param_specs {
		if arg_texts[i] == param_spec.name {
			continue
		}
		if wrote_prefix {
			strings.write_string(&builder, "\n")
			strings.write_string(&builder, indent)
		}
		fmt.sbprint(&builder, param_spec.name, ": ", param_spec.type_text, " = ", arg_texts[i], sep = "")
		wrote_prefix = true
	}

	if fail_flag_name != "" {
		if wrote_prefix {
			strings.write_string(&builder, "\n")
			strings.write_string(&builder, indent)
		}
		fmt.sbprint(&builder, fail_flag_name, " := false", sep = "")
		wrote_prefix = true
	}

	if wrote_prefix {
		fmt.sbprint(&builder, "\n", indent, sep = "")
	}
	fmt.sbprint(&builder, function_name, ": ", rewritten_body, sep = "")
	if fail_flag_name != "" {
		fail_block_indent := strings.concatenate({indent, "\t"}, context.temp_allocator)
		fail_block_text := reindent_inline_text(fail_body_text, fail_block_indent, true)
		fmt.sbprint(&builder, "\n", indent, "if ", fail_flag_name, " {\n", fail_block_text, "\n", indent, "}", sep = "")
	}

	return strings.to_string(builder), true
}

collect_inline_param_names :: proc(source: string, proc_type: ^ast.Proc_Type) -> ([]string, bool) {
	names := make([dynamic]string, 0, context.temp_allocator)

	if proc_type.params == nil {
		return names[:], true
	}

	for field in proc_type.params.list {
		if field == nil || len(field.names) == 0 {
			return {}, false
		}

		for name_expr in field.names {
			name_text := strings.trim_space(source[name_expr.pos.offset:name_expr.end.offset])
			if name_text == "" || name_text == "_" {
				return {}, false
			}
			append(&names, name_text)
		}
	}

	return names[:], true
}

build_inline_expr_stmt_text :: proc(
	proc_source: string,
	call_source: string,
	function_name: string,
	proc_lit: ^ast.Proc_Lit,
	call_expr: ^ast.Call_Expr,
	expr_stmt: ^ast.Expr_Stmt,
) -> (string, bool) {
	if expr_stmt == nil || expr_stmt.expr == nil {
		return "", false
	}

	if expr_stmt.expr.pos.offset != call_expr.pos.offset ||
		expr_stmt.expr.end.offset != call_expr.end.offset {
		return "", false
	}

	proc_type, type_ok := proc_lit.type.derived.(^ast.Proc_Type)
	if !type_ok {
		return "", false
	}

	param_specs, params_ok := collect_inline_param_specs(proc_source, proc_type)
	if !params_ok || len(param_specs) != len(call_expr.args) {
		return "", false
	}

	arg_texts := make([dynamic]string, 0, context.temp_allocator)
	for arg_expr in call_expr.args {
		if _, is_named_arg := arg_expr.derived.(^ast.Field_Value); is_named_arg {
			return "", false
		}

		arg_text := strings.trim_space(call_source[arg_expr.pos.offset:arg_expr.end.offset])
		if arg_text == "" {
			return "", false
		}

		append(&arg_texts, arg_text)
	}

	return_slots, slots_ok := collect_inline_return_slots(proc_source, proc_type)
	if !slots_ok || len(return_slots) != 0 {
		return "", false
	}

	body, body_ok := proc_lit.body.derived.(^ast.Block_Stmt)
	if !body_ok {
		return "", false
	}

	has_returns := block_has_inline_returns(body)
	if !has_returns {
		body_text, body_text_ok := get_inline_block_inner_text(proc_source, body)
		if !body_text_ok {
			return "", false
		}

		indent := get_line_indentation(call_source, expr_stmt.pos.offset)
		builder := strings.builder_make(context.temp_allocator)
		wrote_prefix := false

		for param_spec, i in param_specs {
			if arg_texts[i] == param_spec.name {
				continue
			}

			if wrote_prefix {
				strings.write_string(&builder, "\n")
				strings.write_string(&builder, indent)
			}
			fmt.sbprint(&builder, param_spec.name, ": ", param_spec.type_text, " = ", arg_texts[i], sep = "")
			wrote_prefix = true
		}

		body_text = reindent_inline_block_text(body_text, indent, wrote_prefix)
		if body_text != "" {
			if wrote_prefix {
				strings.write_string(&builder, "\n")
			}
			strings.write_string(&builder, body_text)
		}

		return strings.to_string(builder), true
	}

	rewritten_body, rewrite_ok := rewrite_inline_function_body(
		proc_source,
		body,
		return_slots,
		function_name,
		nil,
	)
	if !rewrite_ok {
		return "", false
	}

	indent := get_line_indentation(call_source, expr_stmt.pos.offset)
	builder := strings.builder_make(context.temp_allocator)
	wrote_prefix := false

	for param_spec, i in param_specs {
		if arg_texts[i] == param_spec.name {
			continue
		}

		if wrote_prefix {
			strings.write_string(&builder, "\n")
			strings.write_string(&builder, indent)
		}
		fmt.sbprint(&builder, param_spec.name, ": ", param_spec.type_text, " = ", arg_texts[i], sep = "")
		wrote_prefix = true
	}

	if wrote_prefix {
		fmt.sbprint(&builder, "\n", indent, sep = "")
	}
	fmt.sbprint(&builder, function_name, ": ", rewritten_body, sep = "")

	return strings.to_string(builder), true
}

collect_inline_param_specs :: proc(source: string, proc_type: ^ast.Proc_Type) -> ([]InlineParamSpec, bool) {
	specs := make([dynamic]InlineParamSpec, 0, context.temp_allocator)

	if proc_type.params == nil {
		return specs[:], true
	}

	for field in proc_type.params.list {
		if field == nil || field.type == nil || len(field.names) == 0 {
			return {}, false
		}

		type_text := strings.trim_space(source[field.type.pos.offset:field.type.end.offset])
		if type_text == "" {
			return {}, false
		}

		for name_expr in field.names {
			name_text := strings.trim_space(source[name_expr.pos.offset:name_expr.end.offset])
			if name_text == "" || name_text == "_" {
				return {}, false
			}
			append(&specs, InlineParamSpec{
				name = name_text,
				type_text = type_text,
			})
		}
	}

	return specs[:], true
}

build_inline_value_decl_return_slots :: proc(
	call_source: string,
	value_decl: ^ast.Value_Decl,
	proc_return_slots: []InlineReturnSlot,
) -> ([]InlineReturnSlot, map[string]string, bool) {
	if value_decl == nil || len(value_decl.names) != len(proc_return_slots) {
		return {}, nil, false
	}

	return_slots := make([dynamic]InlineReturnSlot, 0, context.temp_allocator)
	renames := make(map[string]string, 0, context.temp_allocator)
	seen_names := make(map[string]struct{}, 0, context.temp_allocator)

	for proc_slot, i in proc_return_slots {
		name_expr := value_decl.names[i]
		name_text := strings.trim_space(call_source[name_expr.pos.offset:name_expr.end.offset])
		if name_text == "" || name_text == "_" || name_text in seen_names {
			return {}, nil, false
		}

		append(&return_slots, InlineReturnSlot{
			name = name_text,
			type_text = proc_slot.type_text,
		})
		seen_names[name_text] = {}

		if proc_slot.name != name_text {
			renames[proc_slot.name] = name_text
		}
	}

	return return_slots[:], renames, true
}

build_inline_value_decl_text :: proc(
	proc_source: string,
	call_source: string,
	function_name: string,
	proc_lit: ^ast.Proc_Lit,
	call_expr: ^ast.Call_Expr,
	value_decl: ^ast.Value_Decl,
) -> (string, bool) {
	if value_decl == nil || value_decl.is_using || len(value_decl.values) != 1 {
		return "", false
	}

	if value_decl.values[0].pos.offset != call_expr.pos.offset ||
		value_decl.values[0].end.offset != call_expr.end.offset {
		return "", false
	}

	proc_type, type_ok := proc_lit.type.derived.(^ast.Proc_Type)
	if !type_ok {
		return "", false
	}

	param_names, params_ok := collect_inline_param_names(proc_source, proc_type)
	if !params_ok || len(param_names) != len(call_expr.args) {
		return "", false
	}

	for arg_expr, i in call_expr.args {
		arg_text := strings.trim_space(call_source[arg_expr.pos.offset:arg_expr.end.offset])
		if arg_text != param_names[i] {
			return "", false
		}
	}

	proc_return_slots, slots_ok := collect_inline_return_slots(proc_source, proc_type)
	if !slots_ok || len(proc_return_slots) == 0 {
		return "", false
	}

	return_slots, renames, return_ok := build_inline_value_decl_return_slots(
		call_source,
		value_decl,
		proc_return_slots,
	)
	if !return_ok {
		return "", false
	}

	body, body_ok := proc_lit.body.derived.(^ast.Block_Stmt)
	if !body_ok {
		return "", false
	}

	use_temp_return_slots := inline_return_slots_conflict_with_body(body, return_slots)
	final_return_slots := return_slots
	final_renames := renames
	append_final_decl := false

	if use_temp_return_slots {
		final_return_slots, final_renames = build_inline_temp_return_slots(
			proc_source,
			call_source,
			proc_return_slots,
		)
		append_final_decl = true
	}

	rewritten_body, rewrite_ok := rewrite_inline_function_body(
		proc_source,
		body,
		final_return_slots,
		function_name,
		final_renames,
	)
	if !rewrite_ok {
		return "", false
	}

	indent := get_line_indentation(call_source, value_decl.pos.offset)
	builder := strings.builder_make(context.temp_allocator)

	for slot, i in final_return_slots {
		if i > 0 {
			fmt.sbprint(&builder, "\n", indent, sep = "")
		}
		fmt.sbprint(&builder, slot.name, ": ", slot.type_text, sep = "")
	}

	fmt.sbprint(&builder, "\n", indent, function_name, ": ", rewritten_body, sep = "")
	if append_final_decl {
		fmt.sbprint(&builder, "\n", indent, sep = "")
		for name_expr, i in value_decl.names {
			name_text := strings.trim_space(call_source[name_expr.pos.offset:name_expr.end.offset])
			if name_text == "" {
				return "", false
			}
			if i > 0 {
				strings.write_string(&builder, ", ")
			}
			strings.write_string(&builder, name_text)
		}
		strings.write_string(&builder, " := ")
		for slot, i in final_return_slots {
			if i > 0 {
				strings.write_string(&builder, ", ")
			}
			strings.write_string(&builder, slot.name)
		}
	}

	return strings.to_string(builder), true
}

build_inline_call_text :: proc(
	proc_source: string,
	call_source: string,
	function_name: string,
	proc_lit: ^ast.Proc_Lit,
	call_expr: ^ast.Call_Expr,
) -> (string, bool) {
	proc_type, type_ok := proc_lit.type.derived.(^ast.Proc_Type)
	if !type_ok {
		return "", false
	}

	param_list_text, params_ok := build_inline_param_list_text(proc_source, proc_type)
	if !params_ok {
		return "", false
	}

	call_args_text, args_ok := build_inline_call_args_text(call_source, call_expr)
	if !args_ok {
		return "", false
	}

	return_slots, slots_ok := collect_inline_return_slots(proc_source, proc_type)
	if !slots_ok {
		return "", false
	}

	body, body_ok := proc_lit.body.derived.(^ast.Block_Stmt)
	if !body_ok {
		return "", false
	}

	rewritten_body, rewrite_ok := rewrite_inline_function_body(
		proc_source,
		body,
		return_slots,
		function_name,
		nil,
	)
	if !rewrite_ok {
		return "", false
	}

	builder := strings.builder_make(context.temp_allocator)

	strings.write_string(&builder, "(proc")
	strings.write_string(&builder, param_list_text)
	if len(return_slots) > 0 {
		strings.write_string(&builder, " -> (")
		for slot, i in return_slots {
			if i > 0 {
				strings.write_string(&builder, ", ")
			}
			strings.write_string(&builder, slot.type_text)
		}
		strings.write_string(&builder, ")")
	}

	strings.write_string(&builder, " {\n")

	for slot in return_slots {
		fmt.sbprint(&builder, "\t", slot.name, ": ", slot.type_text, "\n", sep = "")
	}

	fmt.sbprint(&builder, "\t", function_name, ": ", rewritten_body, "\n", sep = "")

	if len(return_slots) > 0 {
		strings.write_string(&builder, "\treturn ")
		for slot, i in return_slots {
			if i > 0 {
				strings.write_string(&builder, ", ")
			}
			strings.write_string(&builder, slot.name)
		}
		strings.write_string(&builder, "\n")
	}

	strings.write_string(&builder, "})")
	strings.write_string(&builder, call_args_text)

	return strings.to_string(builder), true
}

build_inline_param_list_text :: proc(source: string, proc_type: ^ast.Proc_Type) -> (string, bool) {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "(")

	if proc_type.params == nil {
		strings.write_string(&builder, ")")
		return strings.to_string(builder), true
	}

	for field, i in proc_type.params.list {
		if field == nil || len(field.names) == 0 {
			return {}, false
		}

		if i > 0 {
			strings.write_string(&builder, ", ")
		}

		for name_expr, j in field.names {
			name_text := strings.trim_space(source[name_expr.pos.offset:name_expr.end.offset])
			if name_text == "" {
				return "", false
			}

			if j > 0 {
				strings.write_string(&builder, ", ")
			}
			strings.write_string(&builder, name_text)
		}

		type_text := ""
		if field.type != nil {
			type_text = strings.trim_space(source[field.type.pos.offset:field.type.end.offset])
			if type_text == "" {
				return "", false
			}
		}

		default_text := ""
		if field.default_value != nil {
			default_text = strings.trim_space(source[field.default_value.pos.offset:field.default_value.end.offset])
			if default_text == "" {
				return {}, false
			}
		}

		if type_text != "" && default_text != "" {
			fmt.sbprint(&builder, ": ", type_text, " = ", default_text, sep = "")
		} else if type_text != "" {
			fmt.sbprint(&builder, ": ", type_text, sep = "")
		} else if default_text != "" {
			fmt.sbprint(&builder, " := ", default_text, sep = "")
		} else {
			return "", false
		}
	}

	strings.write_string(&builder, ")")

	return strings.to_string(builder), true
}

build_inline_call_args_text :: proc(source: string, call_expr: ^ast.Call_Expr) -> (string, bool) {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "(")

	for arg_expr, i in call_expr.args {
		arg_text := strings.trim_space(source[arg_expr.pos.offset:arg_expr.end.offset])
		if arg_text == "" {
			return "", false
		}

		if i > 0 {
			strings.write_string(&builder, ", ")
		}
		strings.write_string(&builder, arg_text)
	}

	strings.write_string(&builder, ")")

	return strings.to_string(builder), true
}

collect_inline_return_slots :: proc(source: string, proc_type: ^ast.Proc_Type) -> ([]InlineReturnSlot, bool) {
	slots := make([dynamic]InlineReturnSlot, 0, context.temp_allocator)
	index := 0
	seen_names := make(map[string]struct{}, 0, context.temp_allocator)

	if proc_type.results == nil {
		return slots[:], true
	}

	for field in proc_type.results.list {
		if field == nil || field.type == nil {
			return {}, false
		}

		type_text := strings.trim_space(source[field.type.pos.offset:field.type.end.offset])
		if type_text == "" {
			return {}, false
		}

		if len(field.names) == 0 {
			append(&slots, InlineReturnSlot{
				name = fmt.tprintf("__ols_inline_ret_%d", index),
				type_text = type_text,
			})
			seen_names[slots[len(slots) - 1].name] = {}
			index += 1
			continue
		}

		for name_expr in field.names {
			name_ident, ok := name_expr.derived.(^ast.Ident)
			if !ok || name_ident.name == "" {
				return {}, false
			}

			slot_name := name_ident.name
			if slot_name == "_" || slot_name in seen_names {
				slot_name = fmt.tprintf("__ols_inline_ret_%d", index)
			}

			append(&slots, InlineReturnSlot{
				name = slot_name,
				type_text = type_text,
			})
			seen_names[slot_name] = {}
			index += 1
		}
	}

	return slots[:], true
}

rewrite_inline_function_body :: proc(
	source: string,
	body: ^ast.Block_Stmt,
	return_slots: []InlineReturnSlot,
	function_name: string,
	result_renames: map[string]string,
) -> (string, bool) {
	rewrites := make([dynamic]InlineReturnRewrite, 0, context.temp_allocator)
	return_ranges := make([dynamic]InlineOffsetRange, 0, context.temp_allocator)

	RewriteData :: struct {
		source:        string,
		return_slots:  []InlineReturnSlot,
		function_name: string,
		rewrites:      ^[dynamic]InlineReturnRewrite,
		return_ranges: ^[dynamic]InlineOffsetRange,
		result_renames: map[string]string,
		ok:            ^bool,
	}

	valid := true
	rewrite_data := RewriteData{
		source = source,
		return_slots = return_slots,
		function_name = function_name,
		rewrites = &rewrites,
		return_ranges = &return_ranges,
		result_renames = result_renames,
		ok = &valid,
	}

	collector := ast.Visitor{
		data = &rewrite_data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}

			data := cast(^RewriteData)visitor.data
			if !data.ok^ {
				return nil
			}

			if _, is_nested_proc := node.derived.(^ast.Proc_Lit); is_nested_proc {
				return nil
			}

			ret_stmt, is_return := node.derived.(^ast.Return_Stmt)
			if !is_return {
				return visitor
			}

			replacement_text, ok := build_inline_return_rewrite(
				data.source,
				ret_stmt,
				data.return_slots,
				data.function_name,
				data.result_renames,
			)
			if !ok {
				data.ok^ = false
				return nil
			}

				append(data.rewrites, InlineReturnRewrite{
					start = ret_stmt.pos.offset,
					end = ret_stmt.end.offset,
					replacement = replacement_text,
				})
				append(data.return_ranges, InlineOffsetRange{
					start = ret_stmt.pos.offset,
					end = ret_stmt.end.offset,
				})

			return visitor
		},
	}

	for stmt in body.stmts {
		ast.walk(&collector, stmt)
	}

	if !valid {
		return "", false
	}

	if len(result_renames) > 0 {
		rewrite_data := RewriteData{
			source = source,
			return_slots = return_slots,
			function_name = function_name,
			rewrites = &rewrites,
			return_ranges = &return_ranges,
			result_renames = result_renames,
			ok = &valid,
		}

		identifier_collector := ast.Visitor{
			data = &rewrite_data,
			visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
				if node == nil {
					return nil
				}

				data := cast(^RewriteData)visitor.data
				if _, is_nested_proc := node.derived.(^ast.Proc_Lit); is_nested_proc {
					return nil
				}

				ident, is_ident := node.derived.(^ast.Ident)
				if !is_ident {
					return visitor
				}

				if !(ident.name in data.result_renames) {
					return visitor
				}

				for return_range in data.return_ranges^ {
					if node.pos.offset >= return_range.start && node.end.offset <= return_range.end {
						return visitor
					}
				}

				append(data.rewrites, InlineReturnRewrite{
					start = node.pos.offset,
					end = node.end.offset,
					replacement = data.result_renames[ident.name],
				})

				return visitor
			},
		}

		for stmt in body.stmts {
			ast.walk(&identifier_collector, stmt)
		}

		if !valid {
			return "", false
		}
	}

	slice.sort_by(rewrites[:], proc(a, b: InlineReturnRewrite) -> bool {
		return b.start < a.start
	})

	start := body.pos.offset
	end := body.end.offset
	out := source[start:end]

	for rewrite in rewrites {
		rel_start := rewrite.start - start
		rel_end := rewrite.end - start
		if rel_start < 0 || rel_end > len(out) || rel_start > rel_end {
			return "", false
		}

		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, out[:rel_start])
		strings.write_string(&b, rewrite.replacement)
		strings.write_string(&b, out[rel_end:])
		out = strings.to_string(b)
	}

	out = strings.trim_space(out)

	return out, true
}

build_inline_return_rewrite :: proc(
	source: string,
	ret_stmt: ^ast.Return_Stmt,
	return_slots: []InlineReturnSlot,
	function_name: string,
	result_renames: map[string]string,
) -> (string, bool) {
	if len(ret_stmt.results) == 0 {
		return fmt.tprintf("break %s", function_name), true
	}

	if len(ret_stmt.results) != len(return_slots) {
		return "", false
	}

	indent := get_line_indentation(source, ret_stmt.pos.offset)
	builder := strings.builder_make(context.temp_allocator)
	wrote_assignment := false

	for result_expr, i in ret_stmt.results {
		result_text := strings.trim_space(source[result_expr.pos.offset:result_expr.end.offset])
		if result_text == "" {
			return "", false
		}
		if result_text in result_renames {
			result_text = result_renames[result_text]
		}

		if result_text == return_slots[i].name {
			continue
		}

		line_indent := "" if !wrote_assignment else indent
		fmt.sbprint(
			&builder,
			line_indent,
			return_slots[i].name,
			" = ",
			result_text,
			"\n",
			sep = "",
		)
		wrote_assignment = true
	}

	if wrote_assignment {
		fmt.sbprint(&builder, indent, "break ", function_name, sep = "")
	} else {
		fmt.sbprint(&builder, "break ", function_name, sep = "")
	}

	return strings.to_string(builder), true
}
