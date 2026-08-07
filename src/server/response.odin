package server

import "core:encoding/json"

send_notification :: proc(notification: Notification, writer: ^Writer) -> bool {
	data, error := marshal(notification, {}, context.temp_allocator)

	if error != nil {
		return false
	}

	return write_message(writer, data)
}

send_request :: proc(request: RequestMessage, writer: ^Writer) -> bool {
	data, error := marshal(request, {}, context.temp_allocator)

	if error != nil {
		return false
	}

	return write_message(writer, data)
}

send_response :: proc(response: ResponseMessage, writer: ^Writer) -> bool {
	data, error := marshal(response, {}, context.temp_allocator)

	if error != nil {
		return false
	}

	return write_message(writer, data)
}

send_error :: proc(response: ResponseMessageError, writer: ^Writer) -> bool {
	data, error := marshal(response, {}, context.temp_allocator)

	if error != nil {
		return false
	}

	return write_message(writer, data)
}
