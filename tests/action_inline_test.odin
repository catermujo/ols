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

	expected := `(proc() -> (int) {
	v := 4
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
})()`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edit(t, &source, INLINE_FUNCTION_ACTION, expected)
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

	expected := `(proc() -> (int, bool) {
	v := 2
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
})()`

	test.expect_action(t, &source, {INLINE_FUNCTION_ACTION})
	test.expect_action_with_edit(t, &source, INLINE_FUNCTION_ACTION, expected)
}
