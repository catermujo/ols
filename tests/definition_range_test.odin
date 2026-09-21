package tests

import "core:testing"

import "src:common"
import "src:server"

@(test)
ast_definition_range_clamps_lines_and_utf16_characters :: proc(t: ^testing.T) {
	text := "a😀b\r\nx"
	document := server.Document {
		fullpath = "test/main.odin",
		text = transmute([]u8)text,
		used_text = len(text),
	}
	locations := make([dynamic]common.Location, 0, context.temp_allocator)
	append(&locations, common.Location {
		range = {{line = -2, character = 99}, {line = 99, character = 99}},
	})
	server.sanitize_location_ranges(&document, &locations)
	testing.expect_value(t, locations[0].range.start, common.Position {line = 0, character = 4})
	testing.expect_value(t, locations[0].range.end, common.Position {line = 1, character = 1})
}
