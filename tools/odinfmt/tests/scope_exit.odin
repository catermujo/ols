package odinfmt_test

import "core:fmt"

c :: proc(v: int) {}

scope_exit_formatting :: proc() {
	g := proc(v: int)->(r: int) #scope_exit(.explicit,c(r)){
		return v
	}

	_ = g
}

long_scope_exit_formatting :: proc(
	first_really_long_parameter_name: string,
	second_really_long_parameter_name: string,
) -> (result: string) #scope_exit(.implicit, cleanup_scope_exit_with_a_really_long_name(first_really_long_parameter_name, second_really_long_parameter_name, result)) {
	return first_really_long_parameter_name
}

with_formatting :: proc() {
	with value := 1;
		fmt.println(value) {
			with fmt.tprint("nested") {
				fmt.println(value)
			}
		}
}
