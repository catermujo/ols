package server

progress_create :: proc(token: string, writer: ^Writer) {
	request := RequestMessage {
		jsonrpc = "2.0",
		method = "window/workDoneProgress/create",
		id = token,
		params = WorkDoneProgressCreateParams{token = token},
	}
	send_request(request, writer)
}

progress_begin :: proc(token, title, message: string, percentage: int, writer: ^Writer) {
	notification := Notification {
		jsonrpc = "2.0",
		method = "$/progress",
		params = ProgressParams {
			token = token,
			value = WorkDoneProgressBegin{kind = "begin", title = title, message = message, percentage = percentage},
		},
	}
	send_notification(notification, writer)
}

progress_report :: proc(token, message: string, percentage: int, writer: ^Writer) {
	notification := Notification {
		jsonrpc = "2.0",
		method = "$/progress",
		params = ProgressParams {
			token = token,
			value = WorkDoneProgressReport{kind = "report", message = message, percentage = percentage},
		},
	}
	send_notification(notification, writer)
}

progress_end :: proc(token, message: string, writer: ^Writer) {
	notification := Notification {
		jsonrpc = "2.0",
		method = "$/progress",
		params = ProgressParams{token = token, value = WorkDoneProgressEnd{kind = "end", message = message}},
	}
	send_notification(notification, writer)
}
