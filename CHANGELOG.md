# Changelog

All notable changes to **phantom-code.nvim** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-04-02

### Added

- **Inline:** `inline.import_context` — resolve relative Lua `require` and JS/TS `import … from './…'`, score against identifiers near the cursor, prepend `<importedFile>` snippets (`context.lua`)
- **Inline:** `inline.request_gating.skip_consecutive_empty_lines` (default off) via `utils.should_skip_inline_request`
- **Inline:** `inline.cursor_moved_throttle_ms` — rate-limits `schedule()` from `CursorMovedI` (default 50 ms)
- **Inline:** blink.cmp phantom source stays **disabled** when virtual-text auto-trigger is on for the buffer (`vim.b.phantom_code_virtual_text_auto_trigger`); use one auto path at a time
- **Expand:** XML-shaped responses (`<phantom_expand>`, `<replacement>`, `<edit>`) with parser and merge (`expand_parse.lua`); inline diff overlay on buffer (`expand_inline_diff.lua`)
- **Expand:** ask mode — separate system/user templates, conversation block, `expand.keymap.ask`, `:PhantomCode expand ask`
- **Expand:** generate-at-cursor — normal mode invoke with empty selection; `expand.system_generate`
- **Expand:** `@file:` / `@symbol:` in instructions — inject referenced file bodies and LSP symbol snippets (`expand_context_refs.lua`); `expand.max_reference_chars`; default user template includes `<referencedContextBlock>`
- **Expand:** multi-turn implement history for revise (few shots + prior user/assistant pairs); `expand.max_conversation_messages` (default 16, `0` = unlimited)
- **Expand:** dismiss key bound during **generating** state (same as review); `terminate_expand_jobs_for_session`
- **Expand:** anchored prompt float with title/footer hints; `expand.ui` sizes; commands `expand accept` / `dismiss` / `revise`
- **Expand:** `expand.keymap.focus_window` — normal-mode toggle between the source buffer and the nearest expand UI (instruction or ask); also bound inside those floats to jump out
- **Expand:** `expand.keymap.toggle_window` — normal-mode hide/show for the ask UI or the pinned implement prompt (after submit); `expand.ui.collapsed_marker` end-of-line virt text on the source row while collapsed; `focus_window` reopens collapsed UI before focusing; `require('phantom-code.expand').toggle_expand_window_view()`
- **Highlight groups:** `PhantomCodeExpandDiffAdd`, `PhantomCodeExpandDiffDelete`, `PhantomCodeExpandDiffChange`

### Changed

- **Removed:** structural completion cache (`completion_cache.lua`), `inline.cache`, and the global `BufUnload` handler that cleared it
- **Expand:** instruction, revise, and ask prompts submit with **Enter** in normal and insert mode; **Ctrl-J** inserts a newline in insert mode (replaces separate `ask_submit` chord)
- **Expand ask:** ask buffer shows a single latest view (empty draft, `Waiting for reply…`, or last message body only); submit uses the whole buffer; no transcript section headers
- **Inline:** leaving the code buffer for an expand prompt in insert mode no longer clears virtual-text completion state on the code buffer (deferred `BufLeave` + buffer-scoped extmark cleanup)
- **Inline:** default `debounce` 400 → **150** ms, `throttle` 1000 → **500** ms
- **Expand:** implement flow reworked around inline diff and XML-first model contract (fallback to raw replacement text)
- **Expand:** unified ask/implement float UX — cursor returns to the code buffer after submit; **`dismiss`** / **`focus_window`** work from inside ask and instruction floats; **`Esc`** / **`q`** are not overridden in those floats (normal Vim `Esc`)
- **Expand:** after inline diff render, instruction float moves down when anchored below the selection if diff `virt_lines_above` lines would overlap; source window is centered with `zz` on the selection
- **Expand ask:** non-empty responses trigger `vim.notify('phantom-code: ask response ready')`; return to the float with **`focus_window`** or the ask keybind
- **README / docs:** expanded configuration reference and technical architecture notes

### Removed

- **Expand:** `expand.keymap.edit_proposal` and the edit-proposal float
- **Expand:** `expand.keymap.ask_submit` (Enter submits everywhere)
- **Expand:** inline “generating…” pulse extmark (status remains on the instruction float title/footer)

## [0.1.0] - 2026-04-01

Initial public release under **GPL-3.0** (derivative of [minuet-ai.nvim](https://github.com/milanglacier/minuet-ai.nvim)).

### Added

- Inline ghost-text completion with debounce, throttle, and configurable context window / ratio
- **Expand**: visual selection + instruction prompt, preview, accept/dismiss keymaps
- Providers: Anthropic (Claude), OpenAI, OpenAI-compatible chat, OpenAI-compatible FIM
- Optional LSP diagnostics injection into completion prompts
- [blink.cmp](https://github.com/Saghen/blink.cmp) source (`phantom-code.blink`)
- `:PhantomCode` commands for virtual text, blink, and expand
- `User` autocmds for request lifecycle (`PhantomCodeRequestStarted*`, `PhantomCodeRequestFinished`)
- Highlight groups for virtual text, blink kind, and expand UI
- Configuration reference in README; advanced topics in `docs/technical.md`

[Unreleased]: https://github.com/CohenRus/phantom-code.nvim/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/CohenRus/phantom-code.nvim/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/CohenRus/phantom-code.nvim/releases/tag/v0.1.0
