package server

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

write_message :: proc(writer: ^Writer, header, body: []byte) -> bool {
	sync.mutex_lock(&writer.writer_mutex)
	defer sync.mutex_unlock(&writer.writer_mutex)

	parts := [2][]byte{header, body}
	for input in parts {
		part := input
		for len(part) > 0 {
			written, err := writer.writer_fn(writer.writer_context, part)
			if err != 0 || written <= 0 {
				return false
			}
			part = part[written:]
		}
	}

	return true
}
