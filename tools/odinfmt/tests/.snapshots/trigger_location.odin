package odinfmt_test

check :: proc() {
	#assert(true, #trigger_location)
	#assert(true, "message", #trigger_location)
	#panic("message", #trigger_location)
}
