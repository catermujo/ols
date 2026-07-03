package odinfmt_test

lambda_capture_formatting :: proc() {
	captured_really_long_variable_name_one := 1
	captured_really_long_variable_name_two := 2
	captured_really_long_variable_name_three := 3

	transform := lambda [captured_really_long_variable_name_one,captured_really_long_variable_name_two,&captured_really_long_variable_name_three](x: int) -> int {
		return x
	}

	identity := lambda [ ](n: int) -> int {
		return n
	}

	_ = transform
	_ = identity
}
