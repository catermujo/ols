package server

import "core:os"
import "core:strings"

ignore_file_tag_prefix :: "#+ignore"

line_has_ignore_file_tag :: proc(line: string) -> bool {
	if !strings.starts_with(line, ignore_file_tag_prefix) {
		return false
	}

	if len(line) == len(ignore_file_tag_prefix) {
		return true
	}

	return strings.is_space(rune(line[len(ignore_file_tag_prefix)]))
}

source_has_ignore_file_tag :: proc(source: string) -> bool {
	line_start := 0
	for line_start < len(source) {
		line_end := line_start
		for line_end < len(source) && source[line_end] != '\n' {
			line_end += 1
		}

		trimmed := strings.trim_space(source[line_start:line_end])
		if trimmed == "" {
			line_start = line_end + 1
			continue
		}

		if !strings.starts_with(trimmed, "#+") {
			return false
		}

		if line_has_ignore_file_tag(trimmed) {
			return true
		}

		line_start = line_end + 1
	}

	return false
}

file_has_ignore_file_tag :: proc(fullpath: string, allocator := context.temp_allocator) -> bool {
	data, err := os.read_entire_file(fullpath, allocator)
	if err != nil {
		return false
	}

	return source_has_ignore_file_tag(string(data))
}
