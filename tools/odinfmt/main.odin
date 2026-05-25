package odinfmt

import "core:flags"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "src:odin/format"
import "src:odin/printer"

Args :: struct {
	write:  bool `args:"name=w" usage:"write the new format to file"`,
	stdin:  bool `usage:"formats code from standard input"`,
	path:   string `args:"pos=0" usage:"set the file or directory to format"`,
	config: string `usage:"path to a config file"`,
	exclude_dirs: string `usage:"comma-separated directory names to skip when formatting directories recursively"`,
}

default_skip_dirs :: []string{
	".git",
	".jj",
	".hg",
	".svn",
	".emcache",
	".venv",
	"__pycache__",
	"node_modules",
	"build",
	"dist",
	"out",
	"vendor",
}

make_skip_dir_set :: proc(extra_dirs: string) -> map[string]struct{} {
	skip_dirs := make(map[string]struct{}, context.temp_allocator)

	for dir in default_skip_dirs {
		skip_dirs[dir] = {}
	}

	if extra_dirs != "" {
		extra, _ := strings.split(extra_dirs, ",", context.temp_allocator)
		for dir in extra {
			trimmed := strings.trim_space(dir)
			if trimmed == "" {
				continue
			}

			skip_dirs[strings.clone(trimmed, context.temp_allocator)] = {}
		}
	}

	return skip_dirs
}

should_skip_directory :: proc(fullpath: string, skip_dirs: map[string]struct{}) -> bool {
	path, _ := filepath.replace_separators(fullpath, '/', context.temp_allocator)
	dir_name := filepath.base(path)
	_, should_skip := skip_dirs[dir_name]
	return should_skip
}

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

has_ignore_file_tag :: proc(source: string) -> bool {
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

Format_File_Result :: struct {
	source:  string,
	ok:      bool,
	skipped: bool,
}

format_file :: proc(
	filepath: string,
	config: printer.Config,
	allocator := context.allocator,
) -> Format_File_Result {
	if data, err := os.read_entire_file(filepath, allocator); err == nil {
		source := string(data)
		if has_ignore_file_tag(source) {
			return Format_File_Result {ok = true, skipped = true}
		}

		formatted, ok := format.format(filepath, source, config, {.Optional_Semicolons}, allocator)
		return Format_File_Result {
			source = formatted,
			ok     = ok,
		}
	} else {
		return {}
	}
}

main :: proc() {
	arena: vmem.Arena
	arena_err := vmem.arena_init_growing(&arena)
	ensure(arena_err == nil)
	arena_allocator := vmem.arena_allocator(&arena)

	init_global_temporary_allocator(mem.Megabyte * 20) //enough space for the walk

	args: Args
	flags.parse_or_exit(&args, os.args)

	// only allow the path to not be specified when formatting from stdin
	if args.path == "" {
		if args.stdin {
			// use current directory as the starting path to look for `odinfmt.json`
			args.path = "."
		} else {
			fmt.fprint(os.stderr, "Missing path to format\n")
			flags.write_usage(os.to_stream(os.stderr), Args, os.args[0])
			os.exit(1)
		}
	}

	tick_time := time.tick_now()

	write_failure := false

	watermark: uint = 0

	config: printer.Config
	if args.config == "" {
		config = format.find_config_file_or_default(args.path)
	} else {
		config = format.read_config_file_from_path_or_default(args.config)
	}

	if args.stdin {
		data := make([dynamic]byte, arena_allocator)

		for {
			tmp: [mem.Kilobyte]byte

			r, err := os.read(os.stdin, tmp[:])
			if err != os.ERROR_NONE || r <= 0 do break

			append(&data, ..tmp[:r])
		}

		source, ok := format.format(
			"<stdin>",
			string(data[:]),
			config,
			{.Optional_Semicolons},
			arena_allocator,
		)

		if ok {
			fmt.println(source)
		}

		write_failure = !ok
	} else if os.is_file(args.path) {
		if args.write {
			result := format_file(args.path, config, arena_allocator)
			if !result.skipped && result.ok {
				backup_path := strings.concatenate({args.path, "_bk"})
				defer delete(backup_path)

				os.rename(args.path, backup_path)

				if err := os.write_entire_file(args.path, transmute([]byte)result.source); err == nil {
					os.remove(backup_path)
				}
			} else if !result.skipped {
				fmt.eprintf("Failed to write %v", args.path)
				write_failure = true
			}
		} else {
			result := format_file(args.path, config, arena_allocator)
			if !result.skipped && result.ok {
				fmt.println(result.source)
			}
		}
	} else if os.is_dir(args.path) {
		skip_dirs := make_skip_dir_set(args.exclude_dirs)
		files_formatted := 0
		w := os.walker_create(args.path)
		defer os.walker_destroy(&w)
		for info in os.walker_walk(&w) {
			if info.type == .Directory {
				if should_skip_directory(info.fullpath, skip_dirs) {
					os.walker_skip_dir(&w)
				}
				continue
			}

			if filepath.ext(info.name) != ".odin" {
				continue
			}

			file := info.fullpath
			result := format_file(file, config, arena_allocator)
			if result.skipped {
				watermark = max(watermark, arena.total_used)
				free_all(arena_allocator)
				continue
			}

			files_formatted += 1
			fmt.println(file)

			if result.ok {
				if args.write {
					backup_path := strings.concatenate({file, "_bk"})
					os.rename(file, backup_path)

					if err := os.write_entire_file(file, transmute([]byte)result.source); err == nil {
						os.remove(backup_path)
					}
					delete(backup_path)
				} else {
					fmt.println(result.source)
				}
			} else {
				fmt.eprintf("Failed to format %v", file)
				write_failure = true
			}

			watermark = max(watermark, arena.total_used)

			free_all(arena_allocator)
		}

		fmt.printf(
			"Formatted %v files in %vms \n",
			files_formatted,
			time.duration_milliseconds(time.tick_lap_time(&tick_time)),
		)
		fmt.printf("Peak memory used: %v \n", watermark / mem.Megabyte)
	} else {
		fmt.eprintf("%v is neither a directory nor a file \n", args.path)
		os.exit(1)
	}

	os.exit(1 if write_failure else 0)
}
