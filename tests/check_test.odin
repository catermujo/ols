package tests

import "core:path/filepath"
import "core:testing"

import "src:common"
import "src:server"

@(test)
saved_check_only_uses_own_workspace :: proc(t: ^testing.T) {
	root, err := filepath.abs(".", context.temp_allocator)
	if !testing.expect(t, err == nil) do return

	workspace, workspace_err := filepath.join({root, "workspace"}, context.temp_allocator)
	if !testing.expect(t, workspace_err == nil) do return
	sibling, sibling_err := filepath.join({root, "workspace-other", "main.odin"}, context.temp_allocator)
	if !testing.expect(t, sibling_err == nil) do return
	child, child_err := filepath.join({workspace, "src", "main.odin"}, context.temp_allocator)
	if !testing.expect(t, child_err == nil) do return

	config: common.Config
	testing.expect(t, server.saved_check_path_in_workspace(child, &config))
	append(&config.workspace_folders, common.WorkspaceFolder{uri = common.create_uri(workspace, context.temp_allocator).uri})
	defer delete(config.workspace_folders)

	testing.expect(t, server.saved_check_path_in_workspace(child, &config))
	testing.expect(t, !server.saved_check_path_in_workspace(sibling, &config))
	testing.expect(t, !server.saved_check_path_in_workspace(root, &config))
}
