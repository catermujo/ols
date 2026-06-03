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

InlineReturnSlot :: struct {
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

make_workspace_edit_from_dynamic_map :: proc(changes: map[string][dynamic]TextEdit) -> WorkspaceEdit {
	workspace_edit := WorkspaceEdit{}
	workspace_edit.changes = make(map[string][]TextEdit, len(changes), context.temp_allocator)

	for uri, edits in changes {
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
		call_expr, call_ok := position_context.call.derived.(^ast.Call_Expr)
		if !call_ok {
			return {}, false
		}

		call_range := common.get_token_range(position_context.call^, ast_context.file.src)
		inline_text, inline_ok := build_inline_call_text(ast_context.file.src, declaration_symbol.name, proc_lit, call_expr)
		if !inline_ok || inline_text == "" {
			return {}, false
		}

		edit := TextEdit{
			range = call_range,
			newText = inline_text,
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

		call_expr, call_ok := position_context.call.derived.(^ast.Call_Expr)
		if !call_ok {
			if loaded_document.document != nil {
				release_inline_action_document(&loaded_document)
			}
			return {}, false
		}

		call_range := common.get_token_range(position_context.call^, reference_document.ast.src)
		inline_text, inline_ok := build_inline_call_text(
			reference_document.ast.src,
			declaration_symbol.name,
			proc_lit,
			call_expr,
		)
		if !inline_ok || inline_text == "" {
			if loaded_document.document != nil {
				release_inline_action_document(&loaded_document)
			}
			return {}, false
		}

		append_workspace_edit(
			&changes,
			location.uri,
			TextEdit{
				range = call_range,
				newText = inline_text,
			},
		)

		if loaded_document.document != nil {
			release_inline_action_document(&loaded_document)
		}
	}

	return CodeAction{
			title = INLINE_FUNCTION_ACTION,
			kind = "refactor.inline",
			edit = make_workspace_edit_from_dynamic_map(changes),
			isPreferred = false,
		},
		true
}

build_inline_call_text :: proc(
	source: string,
	function_name: string,
	proc_lit: ^ast.Proc_Lit,
	call_expr: ^ast.Call_Expr,
) -> (string, bool) {
	proc_type, type_ok := proc_lit.type.derived.(^ast.Proc_Type)
	if !type_ok {
		return "", false
	}

	param_names, params_ok := collect_inline_param_names(proc_type)
	if !params_ok || len(param_names) != len(call_expr.args) {
		return "", false
	}

	for arg_expr in call_expr.args {
		if _, is_named_arg := arg_expr.derived.(^ast.Field_Value); is_named_arg {
			return "", false
		}
	}

	return_slots, slots_ok := collect_inline_return_slots(source, proc_type)
	if !slots_ok {
		return "", false
	}

	body, body_ok := proc_lit.body.derived.(^ast.Block_Stmt)
	if !body_ok {
		return "", false
	}

	rewritten_body, rewrite_ok := rewrite_inline_function_body(
		source,
		body,
		return_slots,
		function_name,
	)
	if !rewrite_ok {
		return "", false
	}

	builder := strings.builder_make(context.temp_allocator)

	strings.write_string(&builder, "(proc()")
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

	for arg_expr, i in call_expr.args {
		arg_text := strings.trim_space(source[arg_expr.pos.offset:arg_expr.end.offset])
		if arg_text == "" {
			return "", false
		}
		fmt.sbprint(&builder, "\t", param_names[i], " := ", arg_text, "\n", sep = "")
	}

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

	strings.write_string(&builder, "})()")

	return strings.to_string(builder), true
}

collect_inline_param_names :: proc(proc_type: ^ast.Proc_Type) -> ([]string, bool) {
	names := make([dynamic]string, 0, context.temp_allocator)

	if proc_type.params == nil {
		return names[:], true
	}

	for field in proc_type.params.list {
		if field == nil || field.type == nil || len(field.names) == 0 {
			return {}, false
		}

		if _, is_variadic := field.type.derived.(^ast.Ellipsis); is_variadic {
			return {}, false
		}

		for name_expr in field.names {
			name_ident, ok := name_expr.derived.(^ast.Ident)
			if !ok || name_ident.name == "" || name_ident.name == "_" {
				return {}, false
			}
			append(&names, name_ident.name)
		}
	}

	return names[:], true
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
) -> (string, bool) {
	rewrites := make([dynamic]InlineReturnRewrite, 0, context.temp_allocator)

	RewriteData :: struct {
		source:        string,
		return_slots:  []InlineReturnSlot,
		function_name: string,
		rewrites:      ^[dynamic]InlineReturnRewrite,
		ok:            ^bool,
	}

	valid := true
	rewrite_data := RewriteData{
		source = source,
		return_slots = return_slots,
		function_name = function_name,
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

			replacement_text, ok := build_inline_return_rewrite(
				data.source,
				ret_stmt,
				data.return_slots,
				data.function_name,
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

	out = strings.trim_space(out)

	return out, true
}

build_inline_return_rewrite :: proc(
	source: string,
	ret_stmt: ^ast.Return_Stmt,
	return_slots: []InlineReturnSlot,
	function_name: string,
) -> (string, bool) {
	if len(ret_stmt.results) == 0 {
		return fmt.tprintf("break %s", function_name), true
	}

	if len(ret_stmt.results) != len(return_slots) {
		return "", false
	}

	indent := get_line_indentation(source, ret_stmt.pos.offset)
	builder := strings.builder_make(context.temp_allocator)

	for result_expr, i in ret_stmt.results {
		result_text := strings.trim_space(source[result_expr.pos.offset:result_expr.end.offset])
		if result_text == "" {
			return "", false
		}
		line_indent := i == 0 ? "" : indent
		fmt.sbprint(
			&builder,
			line_indent,
			return_slots[i].name,
			" = ",
			result_text,
			"\n",
			sep = "",
		)
	}
	fmt.sbprint(&builder, indent, "break ", function_name, sep = "")

	return strings.to_string(builder), true
}
