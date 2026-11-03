package odinfmt_test

Proc_Literal_Entry :: struct {
	flags:   bit_set[Proc_Literal_Flag],
	visible: proc() -> bool,
	label:   proc() -> string,
	dirty:   proc() -> bool,
}

proc_literal_wrapped_return := Proc_Literal_Entry {
	flags = {.capture},
	visible = proc() -> bool {return(
			first_condition_value &&
			second_condition_value &&
			third_condition_value \
		)},
	dirty = proc() -> bool {return dirty},
}

proc_literal_long_body := Proc_Literal_Entry {
	label = proc() -> string {return(
			"a string literal that is far too long for one line" \
		)},
	dirty = proc() -> bool {return dirty},
}
