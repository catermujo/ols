package server

import "core:fmt"
import "core:sync"

WriterFn :: proc(_: rawptr, _: []byte) -> (int, int)

Writer :: struct {
	writer_fn:      WriterFn,
	writer_context: rawptr,
	writer_mutex:   sync.Mutex,
}

make_writer :: proc(writer_fn: WriterFn, writer_context: rawptr) -> Writer {
	writer := Writer {
		writer_context = writer_context,
		writer_fn      = writer_fn,
	}
	return writer
}

write_sized :: proc(writer: ^Writer, data: []byte) -> bool {
	sync.mutex_lock(&writer.writer_mutex)
	defer sync.mutex_unlock(&writer.writer_mutex)

	remaining := data
	for len(remaining) > 0 {
		written, err := writer.writer_fn(writer.writer_context, remaining)

		if err != 0 || written <= 0 || written > len(remaining) {
			return false
		}

		remaining = remaining[written:]
	}

	return true
}

write_message :: proc(writer: ^Writer, data: []byte) -> bool {
	header := fmt.tprintf("Content-Length: %v\r\n\r\n", len(data))
	message := make([]u8, len(header) + len(data), context.temp_allocator)
	copy(message, transmute([]u8)header)
	copy(message[len(header):], data)
	return write_sized(writer, message)
}
