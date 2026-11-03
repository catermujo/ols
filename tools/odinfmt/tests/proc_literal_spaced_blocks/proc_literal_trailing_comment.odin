package odinfmt_test

Proc_Literal_Entry :: struct {
	other: proc() -> bool,
	more:  proc() -> bool,
}

proc_literal_trailing_block_comment := Proc_Literal_Entry {
	other = proc() -> bool { return first_condition_value && second_condition_value_long_name_xyz_abc /* c */ },
	more = proc() -> bool { return dirty },
}
