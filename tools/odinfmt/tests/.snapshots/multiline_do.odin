package odinfmt_test

if_multiline_do_call :: proc() {
	if level_commit_transaction(&level_document, Level_Command {
			kind      = .Set_Roof,
			entity_id = id,
			material  = room_id,
			a         = {f32(style), ridge_angle},
			b         = {overhang, gutters ? 1 : 0},
			value     = pitch,
		}, existing >= 0 ? "Update roof" : "Create roof") {return false}
}
