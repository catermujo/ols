package tests

import "core:log"
import "core:testing"

import "src:common"
import "src:server"

@(test)
index_file_clears_cross_file_resolve_cache :: proc(t: ^testing.T) {
	server.setup_index(server.get_builtin_path())
	defer server.free_index()

	server.file_resolve_cache.files = make(map[string]server.FileResolve)
	server.file_resolve_cache.files["file:///tmp/other.odin"] = {}

	uri := common.create_uri("/tmp/index-cache-test.odin", context.temp_allocator)
	if result := server.index_file(uri, "package test\nID :: u32\n"); result != .None {
		log.errorf("index_file failed: %v", result)
	}

	if len(server.file_resolve_cache.files) != 0 {
		log.error(t, "expected cross-file resolve cache to be cleared")
	}
}
