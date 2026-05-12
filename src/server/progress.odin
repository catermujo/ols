package server

import "core:fmt"
import "core:sync"

Progress_State :: struct {
	enabled:       bool,
	writer:        ^Writer,
	next_token_id: int,
}

@(private = "file")
progress_capability_enabled: bool

@(private = "file")
progress_capability_mutex: sync.Mutex

@(thread_local)
progress_state: Progress_State

progress_setup :: proc(enabled: bool, writer: ^Writer) {
	sync.mutex_lock(&progress_capability_mutex)
	progress_capability_enabled = enabled
	sync.mutex_unlock(&progress_capability_mutex)

	progress_state.enabled = enabled && writer != nil
	progress_state.writer = writer
	progress_state.next_token_id = 0
}

progress_setup_current_thread :: proc(writer: ^Writer) {
	sync.mutex_lock(&progress_capability_mutex)
	enabled := progress_capability_enabled
	sync.mutex_unlock(&progress_capability_mutex)

	progress_state.enabled = enabled && writer != nil
	progress_state.writer = writer
}

progress_available :: proc() -> bool {
	return progress_state.enabled && progress_state.writer != nil
}

progress_token_make :: proc(prefix: string) -> string {
	progress_state.next_token_id += 1
	return fmt.tprintf("%s_%d", prefix, progress_state.next_token_id)
}

progress_create :: proc(token: string) {
	if !progress_available() do return

	request := RequestMessage {
		jsonrpc = "2.0",
		method  = "window/workDoneProgress/create",
		id      = token,
		params  = WorkDoneProgressCreateParams {token = token},
	}
	send_request(request, progress_state.writer)
}

progress_begin :: proc(token: string, title: string, message := "", percentage := -1) {
	if !progress_available() do return

	begin := WorkDoneProgressBegin {
		kind        = "begin",
		title       = title,
		cancellable = false,
	}
	if message != "" {
		begin.message = message
	}
	if percentage >= 0 {
		begin.percentage = percentage
	}

	notification := Notification {
		jsonrpc = "2.0",
		method  = "$/progress",
		params  = ProgressParams {token = token, value = begin},
	}
	send_notification(notification, progress_state.writer)
}

progress_report :: proc(token: string, message := "", percentage := -1) {
	if !progress_available() do return

	report := WorkDoneProgressReport {
		kind        = "report",
		cancellable = false,
	}
	if message != "" {
		report.message = message
	}
	if percentage >= 0 {
		report.percentage = percentage
	}

	notification := Notification {
		jsonrpc = "2.0",
		method  = "$/progress",
		params  = ProgressParams {token = token, value = report},
	}
	send_notification(notification, progress_state.writer)
}

progress_end :: proc(token: string, message := "") {
	if !progress_available() do return

	done := WorkDoneProgressEnd {
		kind = "end",
	}
	if message != "" {
		done.message = message
	}

	notification := Notification {
		jsonrpc = "2.0",
		method  = "$/progress",
		params  = ProgressParams {token = token, value = done},
	}
	send_notification(notification, progress_state.writer)
}

progress_task_begin :: proc(prefix: string, title: string, message := "", percentage := -1) -> string {
	if !progress_available() do return ""

	token := progress_token_make(prefix)
	progress_create(token)
	progress_begin(token, title, message, percentage)
	return token
}
