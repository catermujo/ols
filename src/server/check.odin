package server

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:strings"
import "core:sync/chan"
import "core:thread"
import "core:time"

import "src:common"

Json_Error :: struct {
	type: string,
	pos:  Json_Type_Error,
	msgs: []string,
}

Json_Type_Error :: struct {
	file:       string,
	offset:     int,
	line:       int,
	column:     int,
	end_column: int,
}

Json_Errors :: struct {
	error_count: int,
	errors:      []Json_Error,
}

Check_Mode :: enum {
	Saved,
	Workspace,
}

Check_Request :: struct {
	check_mode: Check_Mode,
	path:       string,
	config:     ^common.Config,
}

Checker :: struct {
	allocator: mem.Allocator,
	send:      chan.Chan(Check_Request, .Send),
}

@(private = "file")
checker: Checker

@(private = "file")
check_enqueue_count: int

@(private = "file")
check_worker_thread: ^thread.Thread

@(private = "file")
check_mode_to_string :: proc(mode: Check_Mode) -> string {
	switch mode {
	case .Saved:
		return "saved"
	case .Workspace:
		return "workspace"
	}

	return "unknown"
}

queue_check_request :: proc(mode: Check_Mode, path: string, config: ^common.Config) {
	check_enqueue_count += 1
	enqueue_count := check_enqueue_count
	if common.config.verbose {
		log.infof(
			"check queue enqueue #%v mode=%s path=%q",
			enqueue_count,
			check_mode_to_string(mode),
			path,
		)
	}

	path := strings.clone(path, checker.allocator)
	ok := chan.try_send(checker.send, Check_Request{check_mode = mode, path = path, config = config})
	if !ok {
		delete(path, checker.allocator)
		if common.config.verbose {
			log.warnf(
				"Dropped check request #%v mode=%s because check queue is full",
				enqueue_count,
				check_mode_to_string(mode),
			)
		}
	}
}

stop_check_worker :: proc() {
	chan.close(checker.send)
	if check_worker_thread != nil {
		thread.destroy(check_worker_thread)
		check_worker_thread = nil
	}
}

create_and_start_check_worker :: proc(writer: ^Writer) {
	allocator := runtime.heap_allocator()
	check_chan, _ := chan.create(chan.Chan(Check_Request), 8, context.allocator)
	check_send := chan.as_send(check_chan)
	checker = Checker {
		allocator = runtime.heap_allocator(),
		send      = check_send,
	}
	check_recv := chan.as_recv(check_chan)
	check_worker_thread = thread.create_and_start_with_poly_data(
		Consumer{logger = context.logger, ch = check_recv, w = writer},
		run_check_consumer,
	)
}

Consumer :: struct {
	logger: log.Logger,
	ch:     chan.Chan(Check_Request, .Recv),
	w:      ^Writer,
}

run_check_consumer :: proc(c: Consumer) {
	context.logger = c.logger
	for {
		request, ok := chan.recv(c.ch)
		if !ok {
			break
		}

		paths := make([dynamic]string, allocator = context.temp_allocator)
		append(&paths, request.path)

		for request in chan.try_recv(c.ch) {
			append(&paths, request.path)
		}

		if common.config.verbose {
			log.infof(
				"check consumer batch: mode=%s requests=%v first_path=%q",
				check_mode_to_string(request.check_mode),
				len(paths),
				request.path,
			)
		}

		check(request.check_mode, paths[:], request.config)
		push_diagnostics(c.w)
		for path in paths {
			delete(path, checker.allocator)
		}
		free_all(context.temp_allocator)
	}
	free_all(context.temp_allocator)
}

@(private = "file")
decode_check_results :: proc(data: []u8, allocator: mem.Allocator) -> (Json_Errors, bool) {
	json_errors: Json_Errors

	get_int :: proc(v: json.Value) -> (int, bool) {
		#partial switch x in v {
		case json.Integer:
			return int(x), true
		case json.Float:
			return int(x), true
		case:
			return 0, false
		}
	}

	s := ensure_valid_utf8(string(data), allocator)
	root_value, parse_err := json.parse_string(data = s, allocator = allocator, parse_integers = true)
	if parse_err != .None {
		log.errorf("Failed to parse check results: %v, %v", parse_err, s)
		return json_errors, false
	}

	root, root_ok := root_value.(json.Object)
	if !root_ok {
		log.errorf("Failed to decode check results root object: %v", s)
		return json_errors, false
	}

	if count_value, has_count := root["error_count"]; has_count {
		if count, count_ok := get_int(count_value); count_ok {
			json_errors.error_count = count
		}
	}

	errors_value, has_errors := root["errors"]
	if !has_errors {
		return json_errors, true
	}

	errors_array, errors_ok := errors_value.(json.Array)
	if !errors_ok {
		log.errorf("Failed to decode check result errors array: %v", s)
		return json_errors, false
	}

	parsed_errors := make([dynamic]Json_Error, 0, len(errors_array), allocator)

	for error_value in errors_array {
		error_object, error_ok := error_value.(json.Object)
		if !error_ok {
			continue
		}

		entry: Json_Error

		if type_value, has_type := error_object["type"]; has_type {
			if type_name, type_ok := type_value.(json.String); type_ok {
				entry.type = strings.clone(type_name, allocator)
			}
		}

		if pos_value, has_pos := error_object["pos"]; has_pos {
			if pos_object, pos_ok := pos_value.(json.Object); pos_ok {
				if file_value, has_file := pos_object["file"]; has_file {
					if file, file_ok := file_value.(json.String); file_ok {
						entry.pos.file = strings.clone(file, allocator)
					}
				}

				if offset_value, has_offset := pos_object["offset"]; has_offset {
					if offset, offset_ok := get_int(offset_value); offset_ok {
						entry.pos.offset = offset
					}
				}
				if line_value, has_line := pos_object["line"]; has_line {
					if line, line_ok := get_int(line_value); line_ok {
						entry.pos.line = line
					}
				}
				if column_value, has_column := pos_object["column"]; has_column {
					if column, column_ok := get_int(column_value); column_ok {
						entry.pos.column = column
					}
				}
				if end_column_value, has_end_column := pos_object["end_column"]; has_end_column {
					if end_column, end_column_ok := get_int(end_column_value); end_column_ok {
						entry.pos.end_column = end_column
					}
				}
			}
		}

		if msgs_value, has_msgs := error_object["msgs"]; has_msgs {
			if msgs_array, msgs_ok := msgs_value.(json.Array); msgs_ok {
				messages := make([dynamic]string, 0, len(msgs_array), allocator)
				for msg_value in msgs_array {
					if msg, msg_ok := msg_value.(json.String); msg_ok {
						append(&messages, strings.clone(msg, allocator))
					}
				}
				entry.msgs = messages[:]
			}
		}

		append(&parsed_errors, entry)
	}

	json_errors.errors = parsed_errors[:]
	if json_errors.error_count == 0 && len(parsed_errors) > 0 {
		json_errors.error_count = len(parsed_errors)
	}

	return json_errors, true
}

//If the user does not specify where to call odin check, it'll just find all directory with odin, and call them seperately.
fallback_find_odin_directories :: proc(config: ^common.Config) -> []string {
	data := make([dynamic]string, context.temp_allocator)

	for workspace in config.workspace_folders {
		if uri, ok := common.parse_uri(workspace.uri, context.temp_allocator); ok {
			append_packages(uri.path, &data, config.checker_skip_packages, context.temp_allocator)
		}
	}

	return data[:]
}

check_unused_imports :: proc(document: ^Document, config: ^common.Config) {
	if !config.enable_unused_imports_reporting {
		return
	}

	unused_imports := find_unused_imports(document, context.temp_allocator)

	path := document.uri.path

	when ODIN_OS == .Windows {
		path = common.get_case_sensitive_path(path, context.temp_allocator)
	}

	uri := common.create_uri(path, context.temp_allocator)

	remove_diagnostics(.Unused, uri.uri)

	for imp in unused_imports {
		add_diagnostics(
			.Unused,
			uri.uri,
			Diagnostic {
				range = common.get_token_range(imp.import_decl, document.ast.src),
				severity = DiagnosticSeverity.Hint,
				code = "Unused",
				message = "unused import",
				tags = {.Unnecessary},
			},
		)
	}
}

resolve_check_paths :: proc(mode: Check_Mode, paths: []string, config: ^common.Config) -> []string {
	if len(config.profile.checker_path) > 0 {
		return config.profile.checker_path[:]
	}

	if mode == .Saved || config.enable_checker_only_saved {
		results := make([dynamic]string, context.temp_allocator)
		for p in paths {
			if p == "" {
				continue
			}
			dir := path.dir(p, context.temp_allocator)
			if dir not_in config.checker_skip_packages {
				append(&results, dir)
			}
		}
		return results[:]
	}

	if mode == .Workspace && config.enable_checker_workspace_diagnostics {
		return fallback_find_odin_directories(config)
	}

	return {}
}

CheckProcess :: struct {
	process:  os.Process,
	reader:   ^os.File,
	finished: bool,
	buffer:   [dynamic]u8,
}

check :: proc(mode: Check_Mode, check_paths: []string, config: ^common.Config) {
	check_start := time.now()
	paths := resolve_check_paths(mode, check_paths, config)

	if len(paths) == 0 {
		if common.config.verbose {
			log.infof(
				"check skipped: mode=%s input_paths=%v resolved_paths=0",
				check_mode_to_string(mode),
				len(check_paths),
			)
		}
		return
	}

	if common.config.verbose {
		log.infof(
			"check start: mode=%s input_paths=%v resolved_paths=%v",
			check_mode_to_string(mode),
			len(check_paths),
			len(paths),
		)
	}

	clear_diagnostics(.Check)

	collections := make([dynamic]string, context.temp_allocator)

	for k, v in common.config.collections {
		if k == "" || k == "core" || k == "vendor" || k == "base" {
			continue
		}
		append(&collections, fmt.aprintf("-collection:%v=%v", k, v))
	}

	max_concurrent_checks := max(1, os.get_processor_core_count())
	processes := make([dynamic]CheckProcess, 0, len(paths))

	errors := make([dynamic]Json_Errors, 0, len(paths), context.temp_allocator)

	next_index := 0
	running_count := 0
	start := time.now()
	timed_out := false

	for running_count > 0 || next_index < len(paths) {
		for running_count < max_concurrent_checks && next_index < len(paths) {
			check_path := paths[next_index]
			p, ok := start_check_process(check_path, collections[:], config)
			next_index += 1
			if !ok {
				continue
			}
			append(&processes, p)
			running_count += 1
			if common.config.verbose {
				log.infof(
					"check process started: mode=%s path=%q running=%v max=%v",
					check_mode_to_string(mode),
					check_path,
					running_count,
					max_concurrent_checks,
				)
			}
		}

		if time.since(start) > 20 * time.Second {
			timed_out = true
			log.error("`odin check` timed out")
			for &p in processes {
				if !p.finished {
					if err := os.process_kill(p.process); err != nil {
						log.error("Failed to kill `odin check` process: %v", err)
					}
				}
			}
			break
		}

		for &p in processes {
			if p.finished {
				continue
			}

			buf: [1024]u8
			n, _ := os.read(p.reader, buf[:])
			if n > 0 {
				_, _ = append(&p.buffer, ..buf[:n])
			}

			state, err := os.process_wait(p.process, 0)
			if err != nil {
				continue
			}

			if !state.exited {
				continue
			}

			p.finished = true
			running_count -= 1

			for {
				n, read_err := os.read(p.reader, buf[:])
				if n > 0 {
					_, _ = append(&p.buffer, ..buf[:n])
				}
				if read_err != nil {
					break
				}
			}

				os.close(p.reader)
				p.reader = nil

				if len(p.buffer) > 0 {
					if json_errors, ok := decode_check_results(p.buffer[:], context.temp_allocator); ok {
						append(&errors, json_errors)
					}
				}
			}

		if running_count > 0 || next_index < len(paths) {
			time.sleep(1 * time.Millisecond)
		}
	}

	for p in processes {
		os.close(p.reader)
	}

	DiagnosticKey :: struct {
		path:    string,
		message: string,
		line:    int,
		column:  int,
	}

	diagnostics := make(map[DiagnosticKey]struct{}, context.temp_allocator)
	for e in errors {
		for error in e.errors {
			if len(error.msgs) == 0 {
				continue
			}

			message := strings.join(error.msgs, "\n", context.temp_allocator)

			if strings.contains(message, "Redeclaration of 'main' in this scope") {
				continue
			}

			path := error.pos.file

			when ODIN_OS == .Windows {
				path = common.get_case_sensitive_path(path, context.temp_allocator)
				path, _ = filepath.replace_separators(path, '/', context.temp_allocator)
			}

			key := DiagnosticKey {
				path    = path,
				message = message,
				line    = error.pos.line,
				column  = error.pos.column,
			}
			if key in diagnostics {
				continue
			}

			diagnostics[key] = {}

			if is_ols_builtin_file(path) {
				continue
			}

			uri := common.create_uri(path, context.temp_allocator)

			add_diagnostics(
				.Check,
				uri.uri,
				Diagnostic {
					code = "checker",
					severity = map_diagnostic_severity(error.type),
					range = {
						// odin will sometimes report errors on column 0, so we ensure we don't provide a negative column/line to the client
						start = {character = max(error.pos.column - 1, 0), line = max(error.pos.line - 1, 0)},
						end = {character = max(error.pos.end_column - 1, 0), line = max(error.pos.line - 1, 0)},
					},
					message = message,
				},
			)
		}
	}

	if common.config.verbose {
		log.infof(
			"check done: mode=%s resolved_paths=%v diagnostics=%v timed_out=%v elapsed_ms=%v",
			check_mode_to_string(mode),
			len(paths),
			len(diagnostics),
			timed_out,
			time.duration_milliseconds(time.since(check_start)),
		)
	}

}
@(private = "file")
start_check_process :: proc(
	check_path: string,
	collections: []string,
	config: ^common.Config,
) -> (
	CheckProcess,
	bool,
) {
	command: string

	if config.odin_command != "" {
		command = config.odin_command
	} else {
		command = "odin"
	}

	entry_point_opt := filepath.ext(check_path) == ".odin" ? "-file" : "-no-entry-point"
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, command, "check", check_path)
	for c in collections {
		append(&cmd, c)
	}
	for k, v in config.profile.defines {
		append(&cmd, fmt.tprintf("-define:%s=%s", k, v))
	}
	append(&cmd, entry_point_opt, "-json-errors")
	args, _ := strings.split(config.checker_args, " ", context.temp_allocator)
	for arg in args {
		if arg != "" {
			append(&cmd, arg)
		}
	}

	r, w, err := os.pipe()
	if err != nil {
		log.errorf("failed to create pipe for `odin check`: %v\n", err)
		return CheckProcess{}, false
	}
	defer os.close(w)

	desc := os.Process_Desc {
		command = cmd[:],
		stdout  = w,
		stderr  = w,
	}

	p, perr := os.process_start(desc)
	if perr != nil {
		os.close(r)
		log.errorf("failed to start process for `odin check`: %v\n", perr)
		return CheckProcess{}, false
	}

	buffer := make([dynamic]u8, 0, mem.Kilobyte * 200, context.temp_allocator)
	return CheckProcess{process = p, reader = r, buffer = buffer}, true
}

@(private = "file")
map_diagnostic_severity :: proc(type: string) -> DiagnosticSeverity {
	if strings.equal_fold(type, "warning") {
		return .Warning
	}

	return .Error
}
