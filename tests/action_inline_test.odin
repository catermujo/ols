package tests

import "core:testing"

import test "src:testing"

INLINE_VARIABLE_ACTION :: "Inline variable"
INLINE_CONSTANT_ACTION :: "Inline constant"
INLINE_FUNCTION_ACTION :: "Inline function"

@(test)
action_inline_variable_value :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	value := 10
	out := v{*}alue + 1
	_ = out
}
`,
		packages = {},
	}

	test.expect_action(t, &source, {INLINE_VARIABLE_ACTION})
	test.expect_action_with_edit(t, &source, INLINE_VARIABLE_ACTION, "10")
}

@(test)
action_inline_variable_definition_rewrites_usages :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	value{*} := 10
	one := value + 1
	two := value + 2
	_ = one
	_ = two
}
`,
		packages = {},
	}

	test.expect_action(t, &source, {INLINE_VARIABLE_ACTION})
	test.expect_action_with_edits(t, &source, INLINE_VARIABLE_ACTION, {"10", "10"})
}

@(test)
action_inline_constant_value :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

factor :: 4

main :: proc() {
	out := fa{*}ctor + 1
	_ = out
}
`,
		packages = {},
	}

	test.expect_action(t, &source, {INLINE_CONSTANT_ACTION})
	test.expect_action_with_edit(t, &source, INLINE_CONSTANT_ACTION, "4")
}

@(test)
action_inline_constant_definition_rewrites_usages :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

factor{*} :: 4

main :: proc() {
	one := factor + 1
	two := factor + 2
	_ = one
	_ = two
}
`,
		packages = {},
	}

	test.expect_action(t, &source, {INLINE_CONSTANT_ACTION})
	test.expect_action_with_edits(t, &source, INLINE_CONSTANT_ACTION, {"4", "4"})
}

@(test)
action_inline_variable_typed_comp_lit_value :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Cmd :: struct {
	help: string,
}

main :: proc() {
	cmd: Cmd = {
		help = "hello",
	}

	_ = c{*}md
}
`,
		packages = {},
	}

	expected := `Cmd{
		help = "hello",
	}`

	test.expect_action(t, &source, {INLINE_VARIABLE_ACTION})
	test.expect_action_with_edit(t, &source, INLINE_VARIABLE_ACTION, expected)
}

@(test)
action_inline_function_rewrites_returns_with_tag :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

add_one :: proc(v: int) -> int {
	if v < 0 {
		return 0
	}
	return v + 1
}

main :: proc() {
	out := add_o{*}ne(4)
	_ = out
}
`,
		packages = {},
	}

	expected := `(proc(v: int) -> (int) {
	__ols_inline_ret_0: int
	add_one: {
	if v < 0 {
		__ols_inline_ret_0 = 0
		break add_one
	}
	__ols_inline_ret_0 = v + 1
	break add_one
}
	return __ols_inline_ret_0
})(4)`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edit(t, &source, INLINE_FUNCTION_ACTION, expected)
}

@(test)
action_inline_function_with_default_param_explicit_arg :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

add_one :: proc(v: int, alloc := context.temp_allocator) -> int {
	_ = alloc
	return v + 1
}

main :: proc() {
	out := add_o{*}ne(4, context.allocator)
	_ = out
}
`,
		packages = {},
	}

	expected := `(proc(v: int, alloc := context.temp_allocator) -> (int) {
	__ols_inline_ret_0: int
	add_one: {
	_ = alloc
	__ols_inline_ret_0 = v + 1
	break add_one
}
	return __ols_inline_ret_0
})(4, context.allocator)`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edit(t, &source, INLINE_FUNCTION_ACTION, expected)
}

@(test)
action_inline_function_rewrites_value_decl_into_block :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

parse :: proc(payload: string, alloc := context.temp_allocator) -> (out: int) {
	_ = alloc
	out = len(payload)
	return out
}

main :: proc(payload: string, alloc := context.temp_allocator) {
	result := pa{*}rse(payload, alloc)
	_ = result
}
`,
		packages = {},
	}

	expected := `result: int
	parse: {
	_ = alloc
	result = len(payload)
	break parse
}`

test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
test.expect_action_with_edit(t, &source, INLINE_FUNCTION_ACTION, expected)
}

@(test)
action_inline_function_rewrites_value_decl_with_local_name_conflict :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

load_runtime :: proc() -> (int, bool) {
	value := 1
	return value, true
}

main :: proc() {
	value, ok := loa{*}d_runtime()
	_ = value
	_ = ok
}
`,
		packages = {},
	}

	expected := `__ols_inline_ret_0: int
	__ols_inline_ret_1: bool
	load_runtime: {
	value := 1
	__ols_inline_ret_0 = value
	__ols_inline_ret_1 = true
	break load_runtime
}
	value, ok := __ols_inline_ret_0, __ols_inline_ret_1`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edit(t, &source, INLINE_FUNCTION_ACTION, expected)
}

@(test)
action_inline_function_rewrites_negated_if_call_into_block :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

ready :: proc(path: string) -> bool {
	if len(path) == 0 {
		return false
	}
	return true
}

main :: proc(path: string) {
	if !rea{*}dy(path) {
		path = "fallback"
	}
	_ = path
}
`,
		packages = {},
	}

	expected := `ready: {
	if len(path) == 0 {
		path = "fallback"
		break ready
	}
	break ready
}`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edit(t, &source, INLINE_FUNCTION_ACTION, expected)
}

@(test)
action_inline_function_rewrites_negated_if_call_with_many_fail_exits_once :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

write_capture :: proc(path: string) -> bool {
	if len(path) == 0 {
		return false
	}
	if path == "bad" {
		return false
	}
	return true
}

main :: proc(path: string) {
	if !write_cap{*}ture(path) {
		path = "fallback"
	}
	_ = path
}
`,
		packages = {},
	}

	expected := `__ols_inline_failed_0 := false
	write_capture: {
	if len(path) == 0 {
		__ols_inline_failed_0 = true
		break write_capture
	}
	if path == "bad" {
		__ols_inline_failed_0 = true
		break write_capture
	}
	break write_capture
}
	if __ols_inline_failed_0 {
		path = "fallback"
	}`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edit(t, &source, INLINE_FUNCTION_ACTION, expected)
}

@(test)
action_inline_function_rewrites_negated_if_call_preserves_param_type_binding :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Meta :: struct {
	value: int,
}

ready :: proc(meta: Meta) -> bool {
	if meta.value == 0 {
		return false
	}
	return true
}

main :: proc() {
	if !rea{*}dy({
		value = 1,
	}) {
		return
	}
}
`,
		packages = {},
	}

	expected := `meta: Meta = {
		value = 1,
	}
	ready: {
	if meta.value == 0 {
		return
		break ready
	}
	break ready
}`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edit(t, &source, INLINE_FUNCTION_ACTION, expected)
}

@(test)
action_inline_function_rewrites_void_call_stmt_into_block :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:fmt"

print_usage :: proc() {
	fmt.println("Usage")
	fmt.println("More")
}

main :: proc() {
	if true {
		print_us{*}age()
	}
}
`,
		packages = {},
	}

	expected := `fmt.println("Usage")
		fmt.println("More")`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edit(t, &source, INLINE_FUNCTION_ACTION, expected)
}

@(test)
action_inline_function_rewrites_void_call_stmt_with_return_into_block :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:fmt"

maybe_print :: proc(ok: bool) {
	if !ok {
		return
	}
	fmt.println("Usage")
}

main :: proc(ok: bool) {
	maybe_pr{*}int(ok)
}
`,
		packages = {},
	}

	expected := `maybe_print: {
	if !ok {
		break maybe_print
	}
	fmt.println("Usage")
}`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edit(t, &source, INLINE_FUNCTION_ACTION, expected)
}

@(test)
action_inline_function_definition_rewrites_calls :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

add_one{*} :: proc(v: int) -> int {
	if v < 0 {
		return 0
	}
	return v + 1
}

main :: proc() {
	a := add_one(4)
	b := add_one(9)
	_ = a
	_ = b
}
`,
		packages = {},
	}

	expected := `(proc(v: int) -> (int) {
	__ols_inline_ret_0: int
	add_one: {
	if v < 0 {
		__ols_inline_ret_0 = 0
		break add_one
	}
	__ols_inline_ret_0 = v + 1
	break add_one
}
	return __ols_inline_ret_0
})(4)`

	expected_two := `(proc(v: int) -> (int) {
	__ols_inline_ret_0: int
	add_one: {
	if v < 0 {
		__ols_inline_ret_0 = 0
		break add_one
	}
	__ols_inline_ret_0 = v + 1
	break add_one
}
	return __ols_inline_ret_0
})(9)`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edits(t, &source, INLINE_FUNCTION_ACTION, {expected, expected_two, ""})
}

@(test)
action_inline_function_definition_rewrites_void_call_stmts_into_blocks :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:fmt"

print_usage{*} :: proc() {
	fmt.println("Usage")
	fmt.println("More")
}

main :: proc() {
	print_usage()
	print_usage()
}
`,
		packages = {},
	}

	expected := `fmt.println("Usage")
	fmt.println("More")`

	expected_two := `fmt.println("Usage")
	fmt.println("More")`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edits(t, &source, INLINE_FUNCTION_ACTION, {expected, expected_two, ""})
}

@(test)
action_inline_function_definition_rewrites_many_fail_exits_once :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

write_capture{*} :: proc(path: string) -> bool {
	if len(path) == 0 {
		return false
	}
	if path == "bad" {
		return false
	}
	return true
}

main :: proc(path: string) {
	if !write_capture(path) {
		path = "fallback-a"
	}
	if !write_capture(path) {
		path = "fallback-b"
	}
	_ = path
}
`,
		packages = {},
	}

	expected := `__ols_inline_failed_0 := false
	write_capture: {
	if len(path) == 0 {
		__ols_inline_failed_0 = true
		break write_capture
	}
	if path == "bad" {
		__ols_inline_failed_0 = true
		break write_capture
	}
	break write_capture
}
	if __ols_inline_failed_0 {
		path = "fallback-a"
	}`

	expected_two := `__ols_inline_failed_0 := false
	write_capture: {
	if len(path) == 0 {
		__ols_inline_failed_0 = true
		break write_capture
	}
	if path == "bad" {
		__ols_inline_failed_0 = true
		break write_capture
	}
	break write_capture
}
	if __ols_inline_failed_0 {
		path = "fallback-b"
	}`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edits(t, &source, INLINE_FUNCTION_ACTION, {expected, expected_two, ""})
}

@(test)
action_inline_function_definition_rewrites_negated_if_calls_into_blocks :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

ready{*} :: proc(path: string) -> bool {
	if len(path) == 0 {
		return false
	}
	return true
}

main :: proc(path: string) {
	if !ready(path) {
		path = "fallback-a"
	}
	if !ready(path) {
		path = "fallback-b"
	}
	_ = path
}
`,
		packages = {},
	}

	expected := `ready: {
	if len(path) == 0 {
		path = "fallback-a"
		break ready
	}
	break ready
}`

	expected_two := `ready: {
	if len(path) == 0 {
		path = "fallback-b"
		break ready
	}
	break ready
}`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edits(t, &source, INLINE_FUNCTION_ACTION, {expected, expected_two, ""})
}

@(test)
action_inline_function_definition_rewrites_value_decl_calls_into_blocks :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

parse{*} :: proc(payload: string, alloc := context.temp_allocator) -> (out: int) {
	_ = alloc
	out = len(payload)
	return out
}

main :: proc(payload: string, alloc := context.temp_allocator) {
	a := parse(payload, alloc)
	b := parse(payload, alloc)
	_ = a
	_ = b
}
`,
		packages = {},
	}

	expected := `a: int
	parse: {
	_ = alloc
	a = len(payload)
	break parse
}`

	expected_two := `b: int
	parse: {
	_ = alloc
	b = len(payload)
	break parse
}`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edits(t, &source, INLINE_FUNCTION_ACTION, {expected, expected_two, ""})
}

@(test)
action_inline_function_definition_rewrites_value_decl_with_local_name_conflict :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

load_runtime{*} :: proc() -> (int, bool) {
	value := 1
	return value, true
}

main :: proc() {
	value, ok := load_runtime()
	_ = value
	_ = ok
}
`,
		packages = {},
	}

	expected := `__ols_inline_ret_0: int
	__ols_inline_ret_1: bool
	load_runtime: {
	value := 1
	__ols_inline_ret_0 = value
	__ols_inline_ret_1 = true
	break load_runtime
}
	value, ok := __ols_inline_ret_0, __ols_inline_ret_1`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edits(t, &source, INLINE_FUNCTION_ACTION, {expected, ""})
}

@(test)
action_inline_function_definition_rewrites_find_playable_track_load_runtime :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:fmt"

Config :: struct {
	client_id: string,
}

Runtime_Data :: struct {
	token_type: string,
}

load_runtime{*} :: proc() -> (Config, Runtime_Data, bool) {
	client_id := "a"
	has_client_id := true
	if !has_client_id {
		return {}, {}, false
	}

	cfg := Config{}
	cfg.client_id = client_id

	data: Runtime_Data = {
		token_type = "Bearer",
	}
	return cfg, data, true
}

print_usage :: proc() {
	fmt.println("Usage")
}

main :: proc() {
	cfg, session_data, ok := load_runtime()
	if !ok {
		print_usage()
	}
	_ = cfg
	_ = session_data
}
`,
		packages = {},
	}

	expected := `__ols_inline_ret_0: Config
	__ols_inline_ret_1: Runtime_Data
	__ols_inline_ret_2: bool
	load_runtime: {
	client_id := "a"
	has_client_id := true
	if !has_client_id {
		__ols_inline_ret_0 = {}
		__ols_inline_ret_1 = {}
		__ols_inline_ret_2 = false
		break load_runtime
	}

	cfg := Config{}
	cfg.client_id = client_id

	data: Runtime_Data = {
		token_type = "Bearer",
	}
	__ols_inline_ret_0 = cfg
	__ols_inline_ret_1 = data
	__ols_inline_ret_2 = true
	break load_runtime
}
	cfg, session_data, ok := __ols_inline_ret_0, __ols_inline_ret_1, __ols_inline_ret_2`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edits(t, &source, INLINE_FUNCTION_ACTION, {expected, ""})
}

@(test)
action_inline_function_definition_rewrites_calls_with_default_param :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

add_one{*} :: proc(v: int, alloc := context.temp_allocator) -> int {
	_ = alloc
	return v + 1
}

main :: proc() {
	a := add_one(4, context.allocator)
	b := add_one(9)
	_ = a
	_ = b
}
`,
		packages = {},
	}

	expected := `(proc(v: int, alloc := context.temp_allocator) -> (int) {
	__ols_inline_ret_0: int
	add_one: {
	_ = alloc
	__ols_inline_ret_0 = v + 1
	break add_one
}
	return __ols_inline_ret_0
})(4, context.allocator)`

	expected_two := `(proc(v: int, alloc := context.temp_allocator) -> (int) {
	__ols_inline_ret_0: int
	add_one: {
	_ = alloc
	__ols_inline_ret_0 = v + 1
	break add_one
}
	return __ols_inline_ret_0
})(9)`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edits(t, &source, INLINE_FUNCTION_ACTION, {expected, expected_two, ""})
}

@(test)
action_inline_function_multi_return_values :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pair :: proc(v: int) -> (int, bool) {
	if v > 0 {
		return v, true
	}
	return 0, false
}

main :: proc() {
	a, ok := pa{*}ir(2)
	_ = a
	_ = ok
}
`,
		packages = {},
	}

	expected := `(proc(v: int) -> (int, bool) {
	__ols_inline_ret_0: int
	__ols_inline_ret_1: bool
	pair: {
	if v > 0 {
		__ols_inline_ret_0 = v
		__ols_inline_ret_1 = true
		break pair
	}
	__ols_inline_ret_0 = 0
	__ols_inline_ret_1 = false
	break pair
}
	return __ols_inline_ret_0, __ols_inline_ret_1
})(2)`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edit(t, &source, INLINE_FUNCTION_ACTION, expected)
}
