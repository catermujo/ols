package odinfmt_test

Proc_Literal_Vtable :: struct {
	add_ref: proc "system" (this: rawptr) -> u32,
	release: proc "system" (this: rawptr) -> u32,
}

proc_literal_param_vtable := Proc_Literal_Vtable {
	add_ref = proc "system" (
		this: rawptr,
	) -> u32 { return intrinsics.atomic_add(&component.references, 1) + 1 },
	release = proc "system" (this: rawptr) -> u32 { return 0 },
}
