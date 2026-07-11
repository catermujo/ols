package odinfmt_test

import "core:fmt"

c :: proc(v: int) {}

scope_exit_formatting :: proc() {
	g := proc(v: int)->(r: int) #scope_exit(.explicit,c(r)){
		return v
	}

	_ = g
}

with_formatting :: proc() {
	with value := 1;
		fmt.println(value) {
			with fmt.tprint("nested") {
				fmt.println(value)
			}
		}
}
