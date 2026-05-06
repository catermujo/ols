package tests

import "core:encoding/json"
import "core:log"
import "core:testing"

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
	changes := make([dynamic]server.TextDocumentContentChangeEvent)
	append(&changes, server.TextDocumentContentChangeEvent{text = "package test\n"})

	config := common.Config{}

	if result := server.document_apply_changes(uri.uri, changes, 1, &config, nil); result != .InvalidRequest {
		log.errorf("expected .InvalidRequest for unopened document change, got %v", result)
	}
}

@(test)
workspace_config_change_without_workspace_folder_is_safe :: proc(t: ^testing.T) {
	params_json := "{\"settings\":{\"enable_hover\":false}}"
	params, err := json.parse(
		data = transmute([]u8)params_json,
		allocator = context.temp_allocator,
		parse_integers = true,
	)
	if err != json.Error.None {
		log.errorf("failed to parse json params: %v", err)
		return
	}
	defer json.destroy_value(params)

	config := common.Config{enable_hover = true}
	config.workspace_folders = make([dynamic]common.WorkspaceFolder)

	if result := server.notification_workspace_did_change_configuration(params, 0, &config, nil); result != .None {
		log.errorf("expected .None for workspace config change without folders, got %v", result)
	}

	if config.enable_hover {
		log.error(t, "expected enable_hover to be updated from incoming configuration")
	}
}
