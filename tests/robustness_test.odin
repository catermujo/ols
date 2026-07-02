package tests

import "core:encoding/json"
import "core:log"
import "core:mem"
import "core:testing"
import "base:runtime"

import "src:common"
import "src:server"

missing_document_path :: proc() -> string {
	when ODIN_OS == .Windows {
		return "C:/tmp/ols-missing-document.odin"
	} else {
		return "/tmp/ols-missing-document.odin"
	}
}

@(test)
document_apply_changes_missing_document_returns_invalid_request :: proc(t: ^testing.T) {
	uri := common.create_uri(missing_document_path(), context.temp_allocator)
	changes := make([dynamic]server.TextDocumentContentChangeEvent, context.temp_allocator)
	append(&changes, server.TextDocumentContentChangeEvent{text = "package test\n"})

	config := common.Config{}

	if result := server.document_apply_changes(uri.uri, changes, 1, &config, nil); result != .InvalidRequest {
		log.errorf("expected .InvalidRequest for unopened document change, got %v", result)
	}
}

@(test)
workspace_config_change_without_workspace_folder_is_safe :: proc(t: ^testing.T) {
	json_arena: runtime.Arena
	_ = runtime.arena_init(&json_arena, mem.Kilobyte * 4, runtime.default_allocator())
	defer runtime.arena_destroy(&json_arena)

	params_json := "{\"settings\":{\"enable_hover\":false}}"
	params, err := json.parse(
		data = transmute([]u8)params_json,
		allocator = runtime.arena_allocator(&json_arena),
		parse_integers = true,
	)
	if err != json.Error.None {
		log.errorf("failed to parse json params: %v", err)
		return
	}

	config := common.Config{enable_hover = true}
	when ODIN_OS == .Windows {
		config.odin_root_override = "C:/tmp"
	} else {
		config.odin_root_override = "/tmp"
	}
	config.workspace_folders = make([dynamic]common.WorkspaceFolder)
	defer delete(config.workspace_folders)
	defer {
		if config.profile.arch != "" {
			delete(config.profile.arch)
		}
	}
	defer {
		for name, path in config.collections {
			delete(name)
			delete(path)
		}
		delete(config.collections)
	}

	if result := server.notification_workspace_did_change_configuration(params, 0, &config, nil); result != .None {
		log.errorf("expected .None for workspace config change without folders, got %v", result)
	}

	if config.enable_hover {
		log.error(t, "expected enable_hover to be updated from incoming configuration")
	}
}
