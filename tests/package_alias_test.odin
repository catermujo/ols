package tests

import "core:fmt"
import "core:log"
import "core:slice"
import "core:testing"

import "src:common"
import "src:server"

test_root_path :: proc() -> string {
	when ODIN_OS == .Windows {
		return "C:/ols-alias-test"
	} else {
		return "/tmp/ols-alias-test"
	}
}

reset_package_alias_test_state :: proc() {
	server.clear_all_package_aliases()
	clear(&common.config.collections)
}

@(test)
package_alias_adds_matching_collection_only :: proc(t: ^testing.T) {
	root := test_root_path()
	vendor_root := fmt.tprintf("%s/vendor", root)
	pkg_dir := fmt.tprintf("%s/rt/drift", root)

	common.config.collections = make(map[string]string)
	common.config.collections["studio"] = root
	common.config.collections["vendor"] = vendor_root

	server.build_cache.pkg_aliases = make(map[string][dynamic]string)
	defer reset_package_alias_test_state()

	changed := server.add_package_alias_for_dir(pkg_dir)
	if !changed {
		log.error(t, "expected package alias to be added")
	}

	studio_aliases := server.build_cache.pkg_aliases["studio"]
	if !slice.contains(studio_aliases[:], "rt/drift") {
		log.error(t, "missing studio alias")
	}

	if _, exists := server.build_cache.pkg_aliases["vendor"]; exists {
		log.error(t, "unexpected vendor alias")
	}
}

@(test)
package_alias_remove_drops_empty_collection_entry :: proc(t: ^testing.T) {
	root := test_root_path()
	pkg_dir := fmt.tprintf("%s/rt/drift", root)

	common.config.collections = make(map[string]string)
	common.config.collections["studio"] = root

	server.build_cache.pkg_aliases = make(map[string][dynamic]string)
	aliases := make([dynamic]string)
	append(&aliases, "rt/drift")
	server.build_cache.pkg_aliases["studio"] = aliases
	defer reset_package_alias_test_state()

	changed := server.remove_package_alias_for_dir(pkg_dir)
	if !changed {
		log.error(t, "expected package alias to be removed")
	}

	if _, exists := server.build_cache.pkg_aliases["studio"]; exists {
		log.error(t, "expected empty collection entry to be removed")
	}
}
