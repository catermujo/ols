package odinfmt

import "core:flags"
import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "src:common"
import "src:odin/format"
import "src:odin/printer"

Args :: struct {
	write:  bool `args:"name=w" usage:"write the new format to file"`,
	stdin:  bool `usage:"formats code from standard input"`,
	path:   string `args:"pos=0" usage:"set the file or directory to format"`,
	config: string `usage:"path to a config file"`,
	exclude_dirs: string `usage:"comma-separated directory names to skip when formatting directories recursively"`,
}

default_skip_dirs := []string{
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

	for entry in strings.split(extra_dirs, ",", context.temp_allocator) {
		dir := strings.trim_space(entry)
		if dir != "" {
			skip_dirs[strings.clone(dir, context.temp_allocator)] = {}
		}
	}
	return skip_dirs
}

should_skip_directory :: proc(fullpath: string, skip_dirs: map[string]struct{}) -> bool {
	normalized, _ := filepath.replace_separators(fullpath, '/', context.temp_allocator)
	return filepath.base(normalized) in skip_dirs
}

format_file :: proc(
	filepath: string,
	config: printer.Config,
	allocator := context.allocator,
) -> (
	string,
	bool,
	bool,
) {
	if data, err := os.read_entire_file(filepath, allocator); err == nil {
		if common.has_ignore_file_tag(string(data)) {
			return "", true, true
		}
		formatted, ok := format.format(filepath, string(data), config, {.Optional_Semicolons}, allocator)
		return formatted, ok, false
	} else {
		return "", false, false
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
			fmt.print(source)
		}

		write_failure = !ok
	} else if os.is_file(args.path) {
		data, ok, ignored := format_file(args.path, config, arena_allocator)
		if !ignored {
			if ok && args.write {
				write_formatted_file(args.path, data)
			} else if args.write {
				fmt.eprintf("Failed to write %v", args.path)
				write_failure = true
			} else if ok {
				fmt.print(data)
			}
		}
	} else if os.is_dir(args.path) {
		skip_dirs := make_skip_dir_set(args.exclude_dirs)
		files: [dynamic]string
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

			append(&files, strings.clone(info.fullpath))
		}

		formatted_count := 0
		for file in files {
			data, ok, ignored := format_file(file, config, arena_allocator)
			if ignored {
				free_all(arena_allocator)
				continue
			}
			formatted_count += 1
			fmt.println(file)

			if ok {
				if args.write {
					write_formatted_file(file, data)
				} else {
					fmt.println(data)
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
			formatted_count,
			time.duration_milliseconds(time.tick_lap_time(&tick_time)),
		)
		fmt.printf("Peak memory used: %v \n", watermark / mem.Megabyte)
	} else {
		fmt.eprintf("%v is neither a directory nor a file \n", args.path)
		os.exit(1)
	}

	os.exit(1 if write_failure else 0)
}

write_formatted_file :: proc(path: string, data: string) {
	// capture and preserve original file perms
	info, stat_err := os.stat(path, context.temp_allocator)

	backup_path := strings.concatenate({path, "_bk"})
	defer delete(backup_path)

	os.rename(path, backup_path)

	if err := os.write_entire_file(path, transmute([]byte)data); err == nil {
		if stat_err == nil {
			_ = os.chmod(path, info.mode)
		}

		os.remove(backup_path)
	}
}
