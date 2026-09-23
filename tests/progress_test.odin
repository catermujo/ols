package tests

import "core:encoding/json"
import "core:strconv"
import "core:strings"
import "core:testing"

import "src:server"

ProgressCapture :: struct {
	bytes: [dynamic]u8,
}

progress_capture_write :: proc(handle: rawptr, data: []u8) -> (int, int) {
	capture := cast(^ProgressCapture)handle
	written := min(len(data), 7)
	append(&capture.bytes, ..data[:written])
	return written, 0
}

@(test)
progress_messages_remain_framed_with_partial_writes :: proc(t: ^testing.T) {
	capture: ProgressCapture
	defer delete(capture.bytes)
	writer := server.make_writer(progress_capture_write, &capture)

	server.progress_create("test-progress", &writer)
	server.progress_begin("test-progress", "Indexing", "Starting", 0, &writer)
	server.progress_report("test-progress", "Scanning", 50, &writer)
	server.progress_end("test-progress", "Ready", &writer)

	remaining := string(capture.bytes[:])
	methods := [4]string{"window/workDoneProgress/create", "$/progress", "$/progress", "$/progress"}
	for method in methods {
		header_end := strings.index(remaining, "\r\n\r\n")
		if !testing.expect(t, header_end >= 0) do return
		length_text := strings.trim_prefix(remaining[:header_end], "Content-Length: ")
		body_length, parsed := strconv.parse_int(length_text)
		if !testing.expect(t, parsed) do return
		body_start := header_end + 4
		if !testing.expect(t, len(remaining) >= body_start + int(body_length)) do return

		body := remaining[body_start:body_start + int(body_length)]
		value, err := json.parse_string(body, parse_integers = true)
		if !testing.expect(t, err == .None) do return
		object, ok := value.(json.Object)
		if !testing.expect(t, ok) do return
		method_value, found := object["method"]
		if !testing.expect(t, found) do return
		testing.expect_value(t, string(method_value.(json.String)), method)
		remaining = remaining[body_start + int(body_length):]
	}
	testing.expect_value(t, len(remaining), 0)
}
