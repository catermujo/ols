package nested_do

Material :: struct {
	dynamic_viscosity: f32,
}

Adapter :: struct {
	materials:       [4]Material,
	component_count: int,
}

// A nested `do` header of the same kind must not decide whether the outer converted block gets its closing brace.
main :: proc() {
	adapter: Adapter
	inviscid := true

	if inviscid { for material in adapter.materials[:adapter.component_count] do if material.dynamic_viscosity != 0 do inviscid = false }

	if inviscid do for material in adapter.materials do if material.dynamic_viscosity != 0 do inviscid = false

	when ODIN_DEBUG { for material in adapter.materials[:adapter.component_count] do when ODIN_OS == .Darwin do inviscid = false }

	for i := 0;
	    i < adapter.component_count * adapter.component_count * adapter.component_count;
	    i += 1 { for j := 0; j < 1; j += 1 do inviscid = false }
}
