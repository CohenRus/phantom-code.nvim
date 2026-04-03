# phantom-code.nvim — Technical Reference

This document covers internal architecture, the request pipeline, and all extension points. If you just want to install and use the plugin, see the [README](../README.md).

---

## Architecture overview

### Inline (Tab-style) completion

```
User types in insert mode
        │
        ▼
[debounce / throttle guard]
        │
        ▼
  virtualtext.schedule()          ← triggered by CursorMovedI / InsertEnter
  blink M:get_completions()       ← called by blink-cmp's source protocol
        │
        ▼
utils.should_skip_inline_request()   ← optional request_gating (e.g. consecutive empty lines)
        │
        ▼
utils.resolve_provider_config('inline')  ← optional inline.provider / provider_options / prompt_overrides
utils.make_cmp_context()          ← snapshot cursor position and current line
utils.get_context()               ← slice buffer text into prefix + suffix
utils.enrich_llm_context()        ← diagnostics + import_context.attach_import_snippets + context_enrich hook
        │
        ▼
backends/<provider>.complete(context, callback, inline_opts)
        │                             inline_opts.provider_options = merged options
        ▼
common.terminate_all_jobs()       ← only the inline job pool (not Expand)
plenary.Job (curl subprocess)     ← registered in common.current_jobs
        │
        ▼
utils.stream_decode()             ← or no_stream_decode() for non-streaming
common.parse_completion_items()   ← split on <endCompletion>
common.filter_context_sequences_in_items() ← trim completions that duplicate existing text
        │
        ▼
callback(items)                   ← delivered to virtualtext or blink source
```

**Virtual text vs blink:** `utils.virtual_text_auto_active(bufnr)` is true when `vim.b.phantom_code_virtual_text_auto_trigger` is set (typically via `inline.virtualtext.auto_trigger_ft`). The blink.cmp source’s `enabled()` returns **false** on those buffers so automatic inline uses **either** built-in ghost text **or** blink’s phantom provider, not both. `CursorMovedI` restarts the debounced `schedule()` at most once per `inline.cursor_moved_throttle_ms` (InsertEnter still calls `schedule()` immediately).

### Expand (selection or cursor + instruction)

```
expand.invoke() / invoke_ask()    ← visual marks, last visual, or normal-mode cursor (empty selection = generate)
        │
        ▼
expand_context_refs.resolve_instruction()  ← strip @file: / @symbol:, build referenced XML for template
        │
        ▼
utils.get_expand_file_surround()  ← context before/after selection (expand.context_window)
utils.build_diagnostics_context()  ← anchor = start line of selection; cfg = merge(diagnostics, expand.diagnostics)
fill_user_template(expand.user_template | user_template_ask)
        │
        ▼
utils.resolve_provider_config('expand')
backends/<chat>.expand_chat(...)   ← implement: system + few_shots + implement_messages[] + new user; ask: separate template chain
        │
        ▼
common.terminate_expand_jobs()    ← optional; per-session via terminate_expand_jobs_for_session(session_id)
plenary.Job                       ← registered in common.expand_jobs with expand_session_id
        │
        ▼
callback(single_string)           ← expand_parse.parse_response → merge → expand_inline_diff.render; review keymaps
```

Each **shipped** backend module exposes `complete(context, callback, inline_opts?)`. Chat backends used for Expand also expose `expand_chat(...)` (see below). The inline `complete` callback receives a list of strings (candidates), or is called with no arguments on failure. Expand uses a separate code path and job list so it does not cancel inline completions and vice versa.

---

## Prompt float behaviour

Both the implement prompt and the ask UI open as anchored **floats** near the selection.

### Positioning

Floats are placed **above** the selection when there is enough room. If the selection is too close to the top of the window, the float falls back to below the selection. When the source buffer window is not visible or the selection row is off-screen, the float is centred on the editor.

`anchored_win_config(bufnr, sr, sc, width, height)` returns the `nvim_open_win` config table and the `row_off` value (distance from `vim.fn.line('w0')` to the selection start). `row_off` is `nil` for the editor-relative fallback.

When the instruction float was opened **below** the selection (not enough rows above) and inline diff adds `virt_lines_above` extmarks on the selection, `reposition_prompt_after_diff()` shifts the float downward by the number of virtual lines so it does not sit on top of the diff preview. The source window is then centered on the selection (`normal! zz`). 

### Dynamic height

Prompt and ask UIs start at the minimum height needed for their initial content (typically 1 line). A `TextChanged` / `TextChangedI` autocmd recalculates the height as the user types, capped at the configured maximum (`expand.ui.prompt_height` for implement, `expand.ui.ask_height` for ask). Height updates go through `nvim_win_set_config` and the row is recalculated so the float stays above the selection.

### Footers

Float footers show key hints (e.g. `Enter submit · ^J newline · dismiss · focus_window`). Key labels for `dismiss` / `focus_window` use `utils.keymap_footer_label()`. `@file` / `@symbol` references are **not** shown in the footer — they are documented in the README and available in the instruction text.

---

## Ask session lifecycle

Ask sessions are **non-blocking**: the user can hide the float and continue editing, then reopen it later.

### Session fields

`ExpandSession` carries these ask-specific fields:

| Field | Type | Purpose |
|---|---|---|
| `ask_buf` | `integer\|nil` | Buffer handle; persists across hide/show (`bufhidden = 'hide'`) |
| `ask_win` | `integer\|nil` | Window handle; `nil` when hidden |
| `ask_messages` | `table` | `{ role, content }` pairs — full conversation history (all turns sent to the model via `<conversationBlock>`) |
| `ask_generating` | `boolean\|nil` | `true` while an HTTP request is in flight |
| `ask_hidden` | `boolean\|nil` | `true` when the window was hidden by the user |
| `ask_footer_default` | `string\|nil` | Footer / winbar hint text restored after generation completes |
| `ask_resize_augroup` | `integer\|nil` | Augroup for the `TextChanged` resize autocmd |
| `ui_layout` | `'float'\|nil` | Which chrome path is active for the ask UI |

### Window vs session lifetime

- `close_ask_ui(sess)` closes the ask UI window but **preserves the buffer**. Used by `M.ask_toggle()` when hiding.
- `destroy_ask_ui(sess)` closes the window, deletes the resize augroup, wipes the buffer. Called from `destroy_session()`.

### Keybinds inside the ask UI (and implement / revise prompts)

| Key | Mode | Action |
|---|---|---|
| `<CR>` | n, i | Submit (send question or instruction) |
| `<C-J>` | i | Insert a newline at the cursor |
| `dismiss` | n, i | End the ask session (same as from the code buffer) |
| `focus_window` | n | Toggle: jump out to the source buffer (when already in the expand UI) |

`Esc` is not remapped in expand floats; it behaves as usual (e.g. leave insert mode).

### Toggle (`M.ask_toggle()`)

The `expand.keymap.ask` keybind is dual-purpose:

1. If an active ask session exists with a **visible** window → hide it.
2. If an active ask session exists but is **hidden** → reopen the float, reattach the persisted buffer, restore chrome based on generating state, place cursor at the end.
3. If **no** ask session exists → invoke a new one (`M.invoke_ask()`).

To jump into a hidden ask float without starting a new session, use **`expand.keymap.focus_window`** (`M.focus_nearest_window()`), which reopens the buffer in a float if needed. Returns `true` if an existing session was toggled, `false` otherwise.

### Background generation

When the user hides the ask float (via `ask_toggle`) while the model is generating:

- The HTTP job continues; `on_done` accumulates the response into `sess.ask_messages`.
- `on_done` does not move focus into the float; on a non-empty assistant reply it notifies with `phantom-code: ask response ready` (empty replies only get the existing warning).
- When the user reopens via `ask_toggle` or `focus_nearest_window`, the transcript re-renders with the latest assistant response visible.

### Ask buffer (`ask_render_transcript`)

The buffer is set to `modifiable = true` before writing lines (except while a request is in flight, when it is set non-modifiable after rendering). The UI shows **one view at a time**—no section headers and no full transcript:

- **No messages:** a single empty line for the first question.
- **While awaiting a reply:** one line, `Waiting for reply…` (submit is ignored for that text).
- **Otherwise:** the body of the **last** entry in `sess.ask_messages` only—typically the latest assistant reply; if the model returned empty, the last user message is shown again so the user can edit and resend.

On submit, the **entire buffer** (trimmed) is taken as the user question (unless empty or the waiting placeholder). Full history remains in `sess.ask_messages` for `<conversationBlock>` in the ask template.

---

## Context windowing

The `get_context` function (`lua/phantom-code/utils.lua`) reads the entire buffer and slices it around the cursor position. The slicing algorithm respects `context_window` (total character budget) and `context_ratio` (how to split the budget between prefix and suffix):

- If the prefix alone fits within `context_window * context_ratio`, the full prefix is kept and the suffix is trimmed.
- If the suffix alone fits within `context_window * (1 - context_ratio)`, the full suffix is kept and the prefix is trimmed.
- Otherwise both sides are trimmed proportionally.

When either side is trimmed, the corresponding `opts.is_incomplete_before` / `opts.is_incomplete_after` flag is set to `true`. Chat-provider templates use these flags to remove the first/last line of each side (which is likely to be a broken partial line after truncation).

---

## Provider backends

### Chat providers (Claude, OpenAI, openai_compatible)

These in-tree backends encode context as a multi-turn conversation. (`provider_options.gemini` exists in default config, but there is no `backends/gemini.lua` in this repository yet.)

For **inline** `complete()`, they:

1. A system prompt instructs the model to act as a code completion engine and to terminate each candidate with `<endCompletion>`.
2. A few-shot example turn demonstrates the expected input/output format.
3. A user turn contains the actual code context, formatted by the `chat_input` template.

The model's response is a single string containing one or more candidates separated by `<endCompletion>`. `common.parse_completion_items` splits on this delimiter.

For **Expand (implement)**, the same HTTP stack is used via `expand_chat`. The message list is:

- Claude path: `expand.few_shots` (if any) + **stored `implement_messages`** (alternating user/assistant from prior successful turns) + the new user turn built from `expand.user_template` (after `expand_context_refs` and `fill_user_template`).
- OpenAI-shaped path: `system` + `few_shots` + **`implement_messages`** + new user message.

`expand.system_generate` is used when the selection text is empty (generate-at-cursor). The assistant reply is a single string, parsed by `expand_parse.parse_response` (XML `<phantom_expand>` with `<replacement>` and/or `<edit>`; fallback to raw text). **Ask mode** uses `expand.system_ask` and `expand.user_template_ask` with `ask_messages`; it does not use `implement_messages`.

The response is not split on `<endCompletion>` (that delimiter is inline-only).

**Context ordering:** Claude and the default `openai_compatible` config send context in the order `<contextAfterCursor>` then `<contextBeforeCursor>` (suffix-first). OpenAI and Gemini use prefix-first ordering. This is controlled by which `system` / `chat_input` / `few_shots` table is selected — the `_prefix_first` variants vs the plain defaults. The reason for suffix-first ordering with Claude is that it tends to produce higher-quality completions when the model "reads" the surrounding code before the prefix.

### FIM providers (openai_fim_compatible; Codestral-shaped APIs)

`openai_fim_compatible` uses the `prompt` / `suffix` fields of the FIM API. There is no in-tree `backends/codestral.lua`; use `openai_fim_compatible` with Codestral’s OpenAI-compatible FIM URL if needed.

**Chat vs FIM:** Chat inline providers send a system prompt and guidelines (short ghost text, no explanations, `<endCompletion>`, etc.). FIM requests only send `prompt` and `suffix` unless you add fields with `transform` or `optional`. The default FIM prefix prepends language and tab comments plus a short instruction line (`add_fim_completion_instruction_comment()`): code only, no explanatory or fix comments. Override `template.prompt` if you want different wording or to drop the hint.

**Output length:** Default `optional.max_tokens` is `nil`, so the server chooses a limit (often large). Set `optional.max_tokens` (for example 64–256) to reduce multi-line or chatty FIM completions.

**Diagnostics:** With `diagnostics.enable = true`, nearby LSP diagnostics are injected into the FIM prefix inside `<diagnostics>`. That can encourage the model to paraphrase errors as comments instead of emitting fixes. Set `enable = false` temporarily to see whether behavior improves.

**Verification:** Use an endpoint that actually supports FIM or legacy completions (not chat-completions unless you know the server maps it). Any text after the cursor in the buffer is sent as `suffix`; stray markers (e.g. test harness text) will confuse the model.

Each field is generated by a function (`template.prompt` and `template.suffix` in `provider_options.<provider>.template`). The default implementations prepend language, tab, FIM instruction, and optional diagnostics to the prefix.

FIM providers send one request per inline candidate; the plugin fixes the candidate count at `utils.INLINE_N_COMPLETIONS` (1). Chat providers still use `{{{n_completion_template}}}` in the system table, but the `%d` value passed in is always 1.

---

## Template system

### Chat system prompt

```lua
provider_options = {
  claude = {
    system = {
      -- {{{prompt}}}, {{{guidelines}}}, {{{n_completion_template}}} are replaced
      -- at render time with the corresponding string or function values below.
      template = '{{{prompt}}}\n{{{guidelines}}}\n{{{n_completion_template}}}',
      prompt = 'Your custom prompt...',
      guidelines = 'Your custom guidelines...',
      -- %d is replaced with utils.INLINE_N_COMPLETIONS (always 1)
      n_completion_template = '8. Provide at most %d completion items.',
    },
  },
}
```

Any key in the system table that isn't `template` or `n_completion_template` is available as a `{{{key}}}` placeholder. Values can be strings or zero-argument functions.

### Chat user turn (chat_input)

```lua
provider_options = {
  claude = {
    chat_input = {
      -- Template uses the same {{{...}}} placeholder syntax.
      -- Available placeholders: language, tab, diagnostics,
      --   context_before_cursor, context_after_cursor
      template = '{{{language}}}\n{{{tab}}}\n{{{diagnostics}}}\n'
        .. '<contextAfterCursor>\n{{{context_after_cursor}}}\n'
        .. '<contextBeforeCursor>\n{{{context_before_cursor}}}<cursorPosition>',

      -- Each placeholder maps to a function:
      -- fun(context_before_cursor, context_after_cursor, opts) -> string
      language = function(_, _, _)
        return require('phantom-code.utils').add_language_comment()
      end,
      tab = function(_, _, _)
        return require('phantom-code.utils').add_tab_comment()
      end,
      context_before_cursor = function(before, _, opts)
        if opts.is_incomplete_before then
          -- drop the first (broken) line when context was truncated
          local _, rest = before:match('([^\n]*)\n(.*)')
          return rest or before
        end
        return before
      end,
      context_after_cursor = function(_, after, opts)
        if opts.is_incomplete_after then
          local content = after:match('(.*)[\n][^\n]*$')
          return content or after
        end
        return after
      end,
      diagnostics = function(_, _, opts)
        local s = opts.diagnostics_context
        if type(s) ~= 'string' or s == '' then return '' end
        return '<diagnostics>\n' .. s .. '\n</diagnostics>\n'
      end,
    },
  },
}
```

The `opts` table passed to each function contains:
- `opts.is_incomplete_before` — prefix was truncated
- `opts.is_incomplete_after` — suffix was truncated
- `opts.diagnostics_context` — formatted diagnostic string (empty if disabled)

### FIM template

```lua
provider_options = {
  codestral = {
    template = {
      -- Both functions receive (context_before_cursor, context_after_cursor, opts)
      prompt = function(before, after, opts)
        return before   -- default prepends language/tab/FIM hint/diagnostics
      end,
      suffix = function(before, after, opts)
        return after
      end,
    },
  },
}
```

### Few-shot examples

Chat providers include a few-shot example exchange immediately before the real user turn. You can replace the defaults entirely:

```lua
provider_options = {
  claude = {
    few_shots = {
      { role = 'user',      content = '-- your example input' },
      { role = 'assistant', content = 'your example completion<endCompletion>' },
    },
  },
}
```

Or set `few_shots = {}` to disable them. The few-shot table can also be a zero-argument function that returns the list (useful for dynamic generation).

---

## Transform hooks

Transforms run just before the HTTP request is dispatched. They receive and must return a `{ end_point, headers, body }` table, making it possible to modify any part of the request including headers, the URL, or the JSON body.

```lua
provider_options = {
  openai_compatible = {
    transform = {
      function(data)
        -- Add a custom header
        data.headers['X-Custom-Header'] = 'my-value'
        -- Override a body field
        data.body.temperature = 0.2
        return data
      end,
    },
  },
}
```

Multiple transforms are applied in order. This is the right place for provider-specific quirks (extra auth headers, routing params, body field renaming, etc.) without touching the core backend code.

---

## Completion filtering

After raw text is returned from the LLM, two filtering passes run before delivering candidates:

**Suffix overlap filter (`after_cursor_filter_length`):** If the end of a completion candidate overlaps with the beginning of the text after the cursor (more than `after_cursor_filter_length` chars match), the overlapping portion is trimmed. This prevents the model from re-generating code that already exists.

**Closing-brace-only overlap:** If the overlap between the candidate suffix and the text after the cursor is only whitespace plus a single `}` (for example the model duplicated a closing brace that already appears in the suffix), that overlap is trimmed even when it is shorter than `after_cursor_filter_length`.

**Prefix overlap filter (`before_cursor_filter_length`):** Same idea for the beginning of the candidate vs. the text before the cursor. The default threshold is 2, which is intentionally low — it primarily catches cases where the model echoes the very start of the cursor position.

**Accept time:** When `inline.normalize_on_accept` is not false, `normalize_inline_accept_suggestion` runs on accept (virtual text) and when building blink `insertText`. It repeats overlap trimming and removes a trailing `}` when the buffer already has `}` ahead of the cursor, including when that brace is on the next line (using a short multiline lookahead from the cursor).

Both thresholds are tunable:

```lua
require('phantom-code').setup({
  inline = {
    after_cursor_filter_length = 15,
    before_cursor_filter_length = 2,
  },
})
```

---

## Context enrichment

Order inside `utils.enrich_llm_context` (inline):

1. `apply_diagnostics_context` — fills `opts.diagnostics_context`.
2. **`context.attach_import_snippets`** — if `inline.import_context.enable ~= false`, prepends `<importedFile path="…">` blocks to `lines_before` (Lua `require`, JS/TS relative `import`; see `lua/phantom-code/context.lua`).
3. **`inline.context_enrich`** — if this function returns a **new** table, that table replaces the context entirely (import + diagnostics work on the original table only if you replace early).

`inline.context_enrich` is a free-form escape hatch. Return a new context table to replace the current one, or return `nil` to leave it unchanged.

```lua
require('phantom-code').setup({
  inline = {
    context_enrich = function(context, cmp_context)
      -- Append the current git branch to the prefix as a comment
      local branch = vim.fn.system('git branch --show-current'):gsub('%s+$', '')
      context.lines_before = '-- branch: ' .. branch .. '\n' .. context.lines_before
      return context
    end,
  },
})
```

The `context` table has:
- `context.lines_before` — string, text before cursor
- `context.lines_after` — string, text after cursor
- `context.opts.is_incomplete_before` — bool
- `context.opts.is_incomplete_after` — bool
- `context.opts.diagnostics_context` — string

The `cmp_context` table contains the blink-cmp context object (or an equivalent struct built by the plugin for the virtual text path), with `cursor`, `cursor_line`, `bufnr`, etc.

### Diagnostics in prompts

Top-level `diagnostics` controls whether and how `vim.diagnostic` entries near the anchor are formatted into `opts.diagnostics_context` (used by `chat_input.diagnostics` and FIM `template.prompt`). `utils.apply_diagnostics_context` fills that string for inline. For Expand, `vim.tbl_deep_extend` merges top-level `diagnostics` with `expand.diagnostics` (Expand wins on overlapping keys).

---

## Enable predicates

`inline.enable_predicates` is a list of functions evaluated before every auto-trigger. If any function returns `false`, the request is suppressed. Manual invocation (via keymap or command) always bypasses predicates.

```lua
require('phantom-code').setup({
  inline = {
    enable_predicates = {
      -- skip completions in markdown and text files
      function() return not vim.tbl_contains({ 'markdown', 'text', 'txt' }, vim.bo.ft) end,
      -- skip completions when the buffer has unsaved changes to a big file
      function() return vim.fn.line('$') < 5000 end,
    },
  },
})
```

Keep these functions cheap — they run on every keystroke when auto-trigger is active.

---

## Events reference

All events are `User` autocmds. The `args.data` table is a `phantom-code.EventData`:

```lua
---@class phantom-code.EventData
---@field provider string   backend name, e.g. "Claude"
---@field name string       sub-provider name for *_compatible backends
---@field model string      model ID used for this request
---@field n_requests number total HTTP jobs spawned for this trigger
---@field request_idx number|nil  index of this job (present in Started/Finished)
---@field timestamp number  os.time() captured at PhantomCodeRequestStartedPre
```

Example — statusline spinner:

```lua
local _pending = 0

vim.api.nvim_create_autocmd('User', {
  pattern = 'PhantomCodeRequestStarted',
  callback = function() _pending = _pending + 1 end,
})

vim.api.nvim_create_autocmd('User', {
  pattern = 'PhantomCodeRequestFinished',
  callback = function() _pending = math.max(0, _pending - 1) end,
})

-- In your statusline:
-- if _pending > 0 then show "⏳ AI" end
```

---

## Virtual text Lua API

All virtual text actions are exposed on the module for use in custom keymaps:

```lua
local vt = require('phantom-code.virtualtext')

vt.action.accept()         -- insert full current suggestion
vt.action.accept_line()    -- insert first line only
vt.action.accept_n_lines() -- prompt user for N, then insert N lines
vt.action.next()           -- cycle to next candidate (triggers if none yet)
vt.action.prev()           -- cycle to previous candidate
vt.action.dismiss()        -- clear suggestion and cancel pending request
vt.action.is_visible()     -- returns true if a suggestion is currently shown

vt.action.enable_auto_trigger()   -- buffer-local enable
vt.action.disable_auto_trigger()  -- buffer-local disable
vt.action.toggle_auto_trigger()   -- buffer-local toggle
```

---

## blink-cmp manual trigger

`require('phantom-code').make_blink_map()` returns a keymap table you can pass to blink-cmp to manually invoke phantom-code completions independently of other sources:

```lua
-- In your blink-cmp keymap config:
keymap = {
  ['<C-x>'] = require('phantom-code').make_blink_map(),
},
```

---

## Custom text extraction (get_text_fn)

FIM-compatible backends support a `get_text_fn` list for providers whose streaming or non-streaming JSON responses have a non-standard structure. Each function receives the decoded JSON object and must return the completion string. Functions are tried in order until one succeeds.

```lua
provider_options = {
  openai_fim_compatible = {
    get_text_fn = {
      function(json) return json.choices[1].text end,
    },
  },
}
```

---

## Ollama — `optional` field behavior

When using `openai_fim_compatible` pointed at Ollama's `/v1/completions` endpoint, the `optional` table is merged directly into the JSON request body. Here's what Ollama's OpenAI-compatible endpoint actually respects:

| Field | Works? | Notes |
|---|---|---|
| `max_tokens` | Yes | Standard OpenAI param; controls how many tokens the model generates |
| `temperature` | Yes | Standard OpenAI param |
| `top_p` | Yes | Standard OpenAI param |
| `num_ctx` | **No** | Sent in the request body but silently ignored by Ollama's `/v1/completions` endpoint |

`num_ctx` is an Ollama-native option that belongs under the `options` object in Ollama's own API (`/api/generate`). The OpenAI-compatible layer doesn't map it. The only way to set the context window size for an Ollama model via the OpenAI-compatible endpoint is to bake it into a custom Modelfile:

```
FROM qwen2.5-coder:14b
PARAMETER num_ctx 8192
```

```sh
ollama create qwen2.5-coder-8k -f ./Modelfile
```

Then reference that custom model in your config:

```lua
openai_fim_compatible = {
  model = 'qwen2.5-coder-8k',
  -- num_ctx is now baked in; no need for optional.num_ctx
  optional = {
    max_tokens = 750,
    temperature = 0.15,
    top_p = 0.92,
  },
}
```

---

## Per-feature providers and inline overrides

`utils.resolve_provider_config('inline' | 'expand')` returns `{ provider = string, options = table }`:

- **`inline`:** `inline.provider` or global `provider`; merge order is `provider_options[provider]` → `inline.provider_options[provider]` → `inline.prompt_overrides[provider]`. Virtual text and blink pass `inline_opts = { provider_options = resolved.options }` into `complete()`.
- **`expand`:** `expand.provider` or global `provider`; merge order is `provider_options[provider]` → `expand.provider_options[provider]`. Expand does **not** read `inline.prompt_overrides`.

Use this to pair `openai_fim_compatible` for inline ghost text with `openai_compatible` for Expand on the same host.

---

## Job pools (`backends/common.lua`)

- **`current_jobs` + `register_job(job)` / `register_job(job, 'inline')` + `terminate_all_jobs()`** — inline completion jobs only.
- **`expand_jobs` + `register_job(job, 'expand', expand_session_id?)` + `terminate_expand_jobs()`** — Expand HTTP jobs only. Jobs may carry `_phantom_code_expand_session` for per-session cancellation.
- **`terminate_expand_jobs_for_session(session_id)`** — SIGTERM only Expand jobs tagged with that Expand session id (used when dismissing one concurrent preview).

`remove_job(job)` removes from whichever list holds the PID. This keeps Tab completions and Expand from killing each other’s in-flight `curl` processes.

Expand `expand_chat` / `expand_openai_chat` accept `request_opts.cancel_existing_expand_jobs` (default true) and `request_opts.expand_session_id`. When `expand.cancel_inflight` is false, `expand.lua` passes `cancel_existing_expand_jobs = false` so multiple `curl` jobs can run; dismissing a single preview terminates only that session’s jobs.

While `state == 'generating'`, the same **dismiss** keymap as in review is bound on the source buffer (`generating_keymaps`) and calls `M.dismiss` → `terminate_expand_jobs_for_session` + session teardown.

After each successful implement response, `implement_messages` gains a user + assistant pair; `trim_implement_messages` drops oldest **pairs** when `expand.max_conversation_messages` is exceeded (`0` disables trimming).

---

## `complete` vs `expand_chat`

| | `complete(context, callback, inline_opts?)` | `expand_chat(...)` |
|---|---|---|
| **Used by** | Virtual text, blink | `expand.lua` only |
| **Messages** | System from `make_system_prompt`, inline `few_shots`, `chat_input` user turn | Implement: `expand.system` (or `system_generate` if empty selection) + `expand.few_shots` + **`implement_messages`** + templated user message. Ask: `system_ask` + ask template + `ask_messages`. |
| **Output** | List of candidates (`<endCompletion>` split) | Single string (XML or fallback plain replacement) |
| **Job pool** | Inline (default) | Always `expand` |
| **OpenAI-shaped APIs** | `openai_base.complete_openai_base` | `openai_base.expand_openai_chat` |
| **Claude** | `claude.complete` | `claude.expand_chat(system_text, messages, ...)` — top-level `system` field |

`utils.make_curl_args(end_point, headers, data_file, max_time?)` accepts an optional fourth argument (seconds) to override `config.request_timeout` (used for Expand when `expand.request_timeout` is set).

---

## File map

```
lua/phantom-code/
├── init.lua                 Setup, commands, change_model/provider
├── config.lua               Default config, inline/expand blocks, prompts (incl. ask + generate)
├── virtualtext.lua          Ghost text; CursorMovedI throttled schedule + debounced trigger
├── blink.lua                blink-cmp source; disabled when virtual-text auto is on for buffer
├── context.lua              Import resolution + import_context snippets for enrich_llm_context
├── expand.lua               Sessions, prompt floats, implement + ask, generating/review keymaps
├── expand_parse.lua         Parse <phantom_expand> / <edit> / <replacement>
├── expand_inline_diff.lua   Namespace extmarks for diff overlay on selection
├── expand_context_refs.lua  @file / @symbol resolution for expand instructions
├── utils.lua                Context, diagnostics, should_skip_inline_request, enrich_llm_context, expand surround
├── modelcard.lua            Known models per provider (change_model tab-complete)
├── deprecate.lua            Breaking-change notification helper
└── backends/
    ├── common.lua              Job pools, transform application, item parsing, per-session expand cancel
    ├── claude.lua              Anthropic API: complete + expand_chat
    ├── openai.lua              OpenAI API: complete + expand_chat
    ├── openai_base.lua         Shared OpenAI chat + FIM + expand_openai_chat
    ├── openai_compatible.lua   Generic chat endpoint
    └── openai_fim_compatible.lua  Generic FIM endpoint
```
