package odinfmt_test

Proc_Literal_Entry :: struct {
	label: proc() -> string,
	count: proc() -> int,
	step:  proc(by: int) -> int,
	dirty: proc() -> bool,
}

proc_literal_spaced_long_body := Proc_Literal_Entry{label = proc() -> string { return "a string literal that is far too long for one line" }, dirty = proc() -> bool { return dirty }}

proc_literal_unbreakable_body := Proc_Literal_Entry{count = proc() -> int { counter_with_a_name_long_enough_to_overflow_the_line_width += 1 }, dirty = proc() -> bool { return dirty }}

proc_literal_unbreakable_param_body := Proc_Literal_Entry{step = proc(by: int) -> int { counter_with_a_name_long_enough_to_overflow_any_line_width += by }, dirty = proc() -> bool { return dirty }}

proc_literal_spaced_top_level :: proc() -> string { return "a string literal that is far too long to stay on one line" }

proc_literal_spaced_short :: proc() -> bool { return dirty }
