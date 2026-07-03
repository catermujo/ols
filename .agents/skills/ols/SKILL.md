---
name: ols
description: Architecture and conventions for the Odin Language Server. Covers LSP protocol handling, analysis engine, document management, completion/diagnostics/hover systems, and testing patterns.
---

# OLS — Odin Language Server

## Architecture

```
stdin/stdout
  ↕ (JSON-RPC)
Reader + Writer (server/reader.odin, writer.odin)
  ↕
request queue (shared [dynamic], mutex-protected)
  ↕
Main thread: consume_requests() → call_map dispatch
  ↕                    ↕                  ↕
document ops      LSP handlers      check worker
(documents.odin)  (requests.odin)   (check.odin → odin check)
                 ↕                  ↕
          analysis engine      diagnostics
          (analysis.odin)      (diagnostics.odin)
          ↕
          symbol collection
          (collector.odin + memory_index.odin)
```

### Threads (3)
- **Main thread**: consumes requests from queue, dispatches via `call_map`, sends responses
- **Reader thread**: reads stdin, pushes JSON-RPC messages to shared queue
- **Check worker thread**: runs `odin check` subprocess, parses JSON errors, pushes diagnostics

## Key Files

### LSP Protocol Layer (`server/`)
| File | Purpose |
|------|---------|
| `reader.odin` | LSP transport framing (headers + body) |
| `writer.odin` | Thread-safe response writing |
| `response.odin` | Response/notification/request marshalling |
| `types.odin` | All LSP protocol types (666 lines) |
| `marshal.odin` / `unmarshal.odin` | JSON serialization |
| `requests.odin` | Central dispatcher with `call_map` + `notification_map` |
| `log.odin` | Logging via `window/logMessage` |

### Document Management (`server/`)
| File | Purpose |
|------|---------|
| `documents.odin` | `Document` struct (URI, text buffer, AST, imports), `DocumentStorage` (global map), arena allocator recycling |

### Analysis Engine (`server/`)
| File | Purpose |
|------|---------|
| `analysis.odin` | `AstContext`, `get_globals()`, `get_locals()`, `resolve_type_expression()`, `resolve_symbol_return()`, `resolve_expression_type()` — the core type system (4966 lines) |
| `symbol.odin` | `Symbol` struct — universal entity representation with tagged union `value` |
| `collector.odin` | `SymbolCollection` — global symbol database, `collect_symbols()` walks AST |
| `memory_index.odin` | `MemoryIndex` — thin wrapper with fuzzy search |
| `indexer.odin` | Thread-local `Indexer` with builtin/runtime package lookups |
| `caches.odin` | `FileResolveCache` for full-file resolution caching |

### Position & Navigation (`server/`)
| File | Purpose |
|------|---------|
| `position_context.odin` | `DocumentPositionContext` — walks AST to find deepest node at cursor |
| `definition.odin` | Go-to-definition |
| `type_definition.odin` | Go-to-type-definition |
| `references.odin` | Find references + document highlights |
| `hover.odin` | Hover information |
| `signature.odin` | Signature help |
| `completion.odin` | Completion engine (2578 lines): implicit, selector, switch-type, identifier, comp-lit, directive, package completion types |

### Diagnostics (`server/`)
| File | Purpose |
|------|---------|
| `diagnostics.odin` | Three diagnostic types: `.Syntax`, `.Unused`, `.Check`. Global map per type. `push_diagnostics()` merges and sends. |
| `check.odin` | `Check_Mode` (.Saved/.Opened/.Workspace), runs `odin check` subprocess, parses JSON errors |

### Other Features (`server/`)
| File | Purpose |
|------|---------|
| `format.odin` | Format document via `odinfmt` |
| `rename.odin` | Rename + prepare rename |
| `document_symbols.odin` | Document symbols |
| `workspace_symbols.odin` | Workspace-wide symbol search |
| `semantic_tokens.odin` | Semantic tokens (colorization) |
| `inlay_hints.odin` | Inlay hints |
| `document_links.odin` | Document links |
| `action.odin`, `action_inline.odin`, `action_invert_if_statements.odin`, `action_populate_switch_cases.odin` | Code actions |

### Common (`common/`)
| File | Purpose |
|------|---------|
| `types.odin` | Error codes, workspace folder, parser warning handler |
| `config.odin` | `Config` struct — all server configuration booleans/settings |
| `position.odin` | `Position`, `Range`, `Location`, UTF-16↔UTF-8 offset conversion |
| `uri.odin` | URI parsing/creation, percent encoding |
| `fuzzy.odin` | LLVM/clangd port — fuzzy matching for completion scoring |

### Testing (`testing/`)
| File | Purpose |
|------|---------|
| `testing.odin` | `Source` struct, `setup()`/`teardown()`, `expect_*` helper procs for every LSP feature |

### Session (`session/`)
| File | Purpose |
|------|---------|
| `capture.odin` | Stub — not yet implemented |
| `replay.odin` | Stub — not yet implemented |

## How to Add a New LSP Feature

1. **Add types** in `server/types.odin` (params struct, result struct, options if needed)
2. **Add handler** in `server/requests.odin`:
   - Pattern: unmarshal params → `document_get(uri)` → call core logic → `send_response()`
   - Register in `call_map`
3. **Update capabilities** in `request_initialize` / `ServerCapabilities` if needed
4. **Implement core logic** in a new/existing file in `server/`:
   - `get_document_position_context(doc, pos, hint)` to find what's at cursor
   - `make_ast_context(doc.ast, ...)` for type resolution
   - `get_globals()` + `get_locals()` for symbol table
   - Resolve symbol → produce result
5. **Add tests** in `testing/testing.odin`:
   - `setup(src)` with `{*}` cursor marker
   - Call the same public function the server uses
   - Assert with `expect_*` helpers

## How to Add a Config Option

1. Add field to `Config` in `common/config.odin`
2. Add corresponding `Maybe(bool)` field to `OlsConfig` in `server/types.odin`
3. Wire up in `read_ols_initialize_options()` in `requests.odin`

## Allocator Conventions

- **Temp allocator**: `init_global_temporary_allocator(100 MB)` — freed via `free_all(context.temp_allocator)` at end of each request. Most procs use this.
- **Document arenas**: Each document has its own `core:mem/virtual.Arena`. Freed allocators recycled in `free_allocators` pool.
- **Index**: `@(thread_local)` — main thread only.

## Key Patterns

### Feature dispatch (every positional request)
```
request → unmarshal → document_get(uri)
  → get_document_position_context(doc, pos, hint)
  → make_ast_context(doc.ast, ...)
  → get_globals() + get_locals()
  → resolve symbol at position
  → produce result → marshal → send_response
```

### Symbol is universal
Everything (variables, procs, structs, enums, packages, builtins) is a `Symbol` with tagged union `value`. Understanding `Symbol` and its variants in `symbol.odin` is key to modifying any analysis feature.

## Test Pattern

```odin
src := Source{
    main = `package test
    My_Struct :: struct { x: int }
    main :: proc() {
        val: My_Struct
        {*}val
    }`,
}
defer teardown(&src)
setup(&src)

expect_hover(&src, "My_Struct")
expect_completion_labels(&src, {"x"})
```

- `{*}` in source marks cursor position, extracted by `source_remove_cursor()`
- `setup()` parses, indexes, creates Document
- `teardown()` frees arena + index
- `expect_*` calls the same public server function

## Build & Test

```
cd ~/install/ols
./build.sh                 # build OLS
./ci.sh                    # run tests
./ols --help               # CLI options
```

## Debugging

- Run with `--log-file /tmp/ols.log` for verbose logging
- Or run OLS directly and inspect: `echo '{"jsonrpc":"2.0","id":1,"method":"initialize"}' | ./ols`
- Test with `./ci.sh` which builds and runs all test cases
