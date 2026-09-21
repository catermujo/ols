package do_headers

ready :: proc(first: string, second: string, third: string, fourth: string) -> bool {
	return first != "" && second != "" && third != "" && fourth != ""
}

main :: proc() {
	if ready(
		"first value is deliberately long",
		"second value is deliberately long",
		"third value is deliberately long",
		"fourth value is deliberately long",
	) {return}

	for ready(
		    "first value is deliberately long",
		    "second value is deliberately long",
		    "third value is deliberately long",
		    "fourth value is deliberately long",
	    ) {break}

	if ready("ok", "ok", "ok", "ok") do return

	when ODIN_OS == .Darwin &&
	ODIN_OS == .Darwin &&
	ODIN_OS == .Darwin &&
	ODIN_OS == .Darwin &&
	ODIN_OS == .Darwin &&
	ODIN_OS == .Darwin &&
	ODIN_OS == .Darwin {return}
}
