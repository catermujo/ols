package odinfmt_test

main :: proc() {
	#no_bounds_check for i := 0; i < 100; i += 1 {
	}

	#no_bounds_check buf = buf[8:]
}

procedure_no_bounds_check :: proc() where 1 == 1 #no_bounds_check {}
procedure_multiple_tags_line_wrap :: proc(a, b, c: int) -> (int, bool) where really_long_const_name_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > really_long_const_name_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb #optional_ok #no_bounds_check {}

// odinfmt: disable
@(require_results)
foo :: proc() -> int {
    return 0
}
// odinfmt: enable
