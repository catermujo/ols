package odinfmt_test

cleanup :: proc(value: int) {}

scope :: proc(value: int) -> int #scope_exit(.explicit, cleanup(value)) {
	return value
}

main :: proc() {
	value := 1
	callback := lambda[&value](increment: int) -> int {
		return value + increment
	}

	with scoped_value := scope(value) {
		_ = callback(scoped_value)
	}
}
