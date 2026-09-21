package odinfmt_test

c :: proc(v: int) {}

scope_exit_formatting :: proc() {
	g := proc(v: int)->(r: int) #scope_exit(.explicit,c(r)){
		return v
	}

	_ = g
}
