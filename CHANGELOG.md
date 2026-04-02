# Changelog

All notable changes to **phantom-code.nvim** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/CohenRus/phantom-code.nvim/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/CohenRus/phantom-code.nvim/releases/tag/v0.1.0
