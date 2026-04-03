# phantom-code.nvim

> **Based on [minuet-ai.nvim](https://github.com/milanglacier/minuet-ai.nvim)** by Milan Glacier (GPL-3.0).
> This project is a derivative of minuet-ai.nvim and is distributed under the same **GPL-3.0** license.

AI-powered code completion and rewriting for Neovim. Get inline ghost text suggestions as you type, and rewrite selected code with natural language instructions.

## Highlights

- **Inline completion** -- ghost text suggestions appear as you type, powered by any LLM
- **Import-aware context** -- optional snippets from **relative** imports (`require`, `import … from './…'`) are prepended to inline prompts
- **Expand** -- select code (or generate at the cursor), describe what you want, inline diff preview, accept / dismiss / revise
- **Expand ask** -- Q&A over a selection in a non-blocking float; cursor returns to the buffer after you send a question; ask follow-ups via `focus_window` or the ask keybind
- **Multi-provider** -- Claude, OpenAI, OpenRouter, DeepSeek, Ollama, or any OpenAI-compatible API
- **Two completion strategies** -- chat-based (system prompt + context) or fill-in-the-middle (FIM)
- **[blink.cmp](https://github.com/Saghen/blink.cmp) integration** -- popup-menu completions when virtual-text **auto**-trigger is off for the buffer; with `auto_trigger_ft` enabled, phantom-code uses built-in ghost text only for auto inline
- **Diagnostics-aware** -- optionally injects nearby LSP diagnostics into the prompt for smarter suggestions
- **Separate flows** -- inline and Expand use independent job pools so they never cancel each other

## Installation

Requires **Neovim 0.10+**, [plenary.nvim](https://github.com/nvim-lua/plenary.nvim), and `curl`.

```lua
-- lazy.nvim
{
  'CohenRus/phantom-code.nvim',
  dependencies = { 'nvim-lua/plenary.nvim' },
  event = 'InsertEnter',
  opts = {
    provider = 'claude',
    provider_options = {
      claude = {
        api_key = 'ANTHROPIC_API_KEY',
        model = 'claude-haiku-4-5',
      },
    },
    inline = {
      virtualtext = {
        auto_trigger_ft = { '*' },
        keymap = {
          accept = '<Tab>',
          accept_line = '<S-Tab>',
          next = '<M-]>',
          prev = '<M-[>',
          dismiss = '<C-e>',
        },
      },
    },
    expand = {
      enable = true,
      ui = {
        prompt_height = 10,
        prompt_width = 72,
        ask_height = 16,
        ask_width = 80,
        collapsed_marker = ' ⋯ expand', -- eol virt text when UI is collapsed via toggle_window; "" to disable
      }, -- heights are max; windows auto-size
      inline_diff = { enable = true },
      keymap = {
        invoke = '<leader>ae',
        ask = '<leader>aq',
        accept = '<leader>ay',
        dismiss = '<leader>an',
        revise = '<leader>ar',
        focus_window = '<leader>aw',
      },
    },
  },
}
```

Set your API key as an environment variable (e.g. `ANTHROPIC_API_KEY`). The `api_key` field is the **name** of the env var, not the secret itself.

For **blink.cmp**, register the source in your blink config with `module = 'phantom-code.blink'`.

## Usage

### Inline completion

Start typing in insert mode. Ghost text appears after a short debounce. Use your configured keymaps to accept, cycle, or dismiss suggestions.

The plugin sends surrounding code (controlled by `context_window` / `context_ratio`), optional LSP diagnostics, and (by default) **import snippets** from resolved relative imports (`inline.import_context`) to the LLM. Defaults: `inline.debounce = 150` ms, `inline.throttle = 500` ms, `inline.cursor_moved_throttle_ms = 50` (limits how often `CursorMovedI` restarts the debounced request).

### Expand (implement)

1. **Selection:** Select code in visual mode, use `'<` / `'>` from the last visual selection, **or** stay in **normal mode** at the cursor for **generate-at-cursor** (empty selection).
2. Press your invoke keymap (e.g. `<leader>ae`) or run `:PhantomCode expand`.
3. Enter an instruction in the expand float. The float auto-sizes and anchors near the selection when there is room. **Enter** submits in both normal and insert mode; use **Ctrl-J** in insert mode to insert a newline. After you submit, focus returns to the code buffer while the prompt float stays open with a generating/review title.
4. **Context references** (optional): in the instruction, use `@file:relative/or/abs/path` or `@file:"path with spaces"` to inject file contents, and `@symbol:Name` to inject a snippet from **LSP document symbols** (same buffer). Stripped from the visible instruction and merged into the prompt (budget: `expand.max_reference_chars`).
5. The model should return `<phantom_expand>` XML: either `<replacement>...</replacement>` for a full selection replace, or one or more `<edit startLine="N" endLine="M">...</edit>` blocks (lines are 1-based within the selection). If the XML is missing, the plugin falls back to treating the reply as a single replacement.
6. **Inline diff** (Avante-style) is drawn on the buffer over the selection: changed/deleted lines are highlighted; added lines appear as virtual `+` lines. No separate diff popup.
7. Use your keymaps (or commands below): **accept** applies the proposal, **dismiss** cancels (also works **while the model is generating** and from inside expand floats), **focus_window** toggles between the code buffer and the open instruction or ask UI, **revise** opens a new instruction float while keeping the previous diff visible until you submit a new request.

**Revise history:** Each implement turn appends user + assistant messages for the session. Long chains are capped by `expand.max_conversation_messages` (default 16 messages ≈ 8 rounds; set `0` for unlimited).

Expand uses a separate chat request with its own system prompt and context budget, independent from inline completion. **Generate mode** uses `expand.system_generate` when the selection is empty.

### Expand ask

1. Select the code you want the model to see as context
2. Run `:PhantomCode expand ask` or map `expand.keymap.ask`
3. Type your question in the ask buffer (same **Enter** / **Ctrl-J** as implement). The buffer shows only the latest reply or your draft—no transcript headers. History is still sent to the model via the ask template’s conversation block.
4. After you submit, focus moves back to the code buffer; when the assistant returns non-empty text you get a `phantom-code: ask response ready` notification
5. Use `**focus_window`** (or the ask keybind) to jump back into the float for follow-ups; `**focus_window`** again jumps out to the code buffer
6. `**dismiss**` closes the session from the code buffer or from inside the float

## Providers


| Key                     | Strategy | Notes                                                         |
| ----------------------- | -------- | ------------------------------------------------------------- |
| `claude`                | Chat     | Anthropic Messages API                                        |
| `openai`                | Chat     | OpenAI Chat Completions API                                   |
| `openai_compatible`     | Chat     | OpenRouter, Groq, local servers, or any OpenAI-compatible API |
| `openai_fim_compatible` | FIM      | DeepSeek, Ollama `/v1/completions`, or any FIM-compatible API |


You can use different providers for inline and Expand by setting `inline.provider` and `expand.provider` separately.

## Commands

`:PhantomCode` subcommands complete with Tab.


| Command                            | Effect                                                      |
| ---------------------------------- | ----------------------------------------------------------- |
| `:PhantomCode virtualtext enable`  | Enable virtual-text auto-trigger in this buffer             |
| `:PhantomCode virtualtext disable` | Disable auto-trigger in this buffer                         |
| `:PhantomCode virtualtext toggle`  | Toggle auto-trigger in this buffer                          |
| `:PhantomCode blink enable`        | Enable blink auto-complete for phantom-code source          |
| `:PhantomCode blink disable`       | Disable blink auto-complete                                 |
| `:PhantomCode blink toggle`        | Toggle blink auto-complete                                  |
| `:PhantomCode expand`              | Run Expand (implement) using visual marks `'<` `'>`         |
| `:PhantomCode expand ask`          | Expand ask mode (Q&A over selection)                        |
| `:PhantomCode expand accept`       | Accept the current Expand implement proposal (review state) |
| `:PhantomCode expand dismiss`      | Dismiss expand session / clear inline diff                  |
| `:PhantomCode expand revise`       | Revise instruction (implement review state)                 |


## Configuration

Defaults below mirror `lua/phantom-code/config.lua`. **You do not need to paste this whole block**—only override what you want. Pattern: a one-line comment above each option (what it does), then `key = default,` with a trailing comment for allowed types or values (multi-line strings end with `]], -- type` on the closing line).

For provider entries, `system` / `few_shots` / `chat_input` (chat) and `template` (FIM) are set inside the plugin unless you add them yourself; the snippet lists the scalar defaults only.

```lua
require('phantom-code').setup({
  -- Default backend name when `inline.provider` / `expand.provider` are nil (must match `lua/phantom-code/backends/<name>.lua`)
  provider = 'openai_compatible', -- string

  -- Max characters of buffer context around the cursor sent to inline / default provider prompts
  context_window = 16000, -- integer

  -- Share of `context_window` used for text before the cursor; rest after (0.0–1.0)
  context_ratio = 0.75, -- number 0–1

  -- HTTP timeout in seconds for inline completion (and default when expand does not override)
  request_timeout = 3, -- integer (seconds)

  -- Which notifications the plugin may show
  notify = 'warn', -- false | "error" | "warn" | "verbose" | "debug"

  -- Curl binary used for HTTP
  curl_cmd = 'curl', -- string

  -- Extra curl CLI arguments
  curl_extra_args = {}, -- list of strings

  -- Proxy URL for curl, or nil
  proxy = nil, -- string | nil

  -- Inject nearby LSP diagnostics into inline / FIM / chat-style prompts (`opts.diagnostics_context`)
  diagnostics = {
    -- Turn diagnostic injection on or off
    enable = false, -- boolean
    -- How many lines above/below the cursor to scan
    line_radius = 12, -- integer
    -- Minimum diagnostic severity to include (vim.diagnostic.severity.*)
    min_severity = vim.diagnostic.severity.HINT, -- integer (vim.diagnostic.severity)
    -- Max characters of diagnostic text in the prompt
    max_chars = 2048, -- integer
  },

  inline = {
    -- Override top-level `provider` for inline only; nil = use `provider`
    provider = nil, -- string | nil

    -- Options merged into `provider_options[inline.provider]` for inline
    provider_options = {}, -- table

    -- Override pieces of the inline system prompt (plugin-specific keys)
    prompt_overrides = {}, -- table

    -- blink.cmp integration (phantom source is off on buffers where virtual-text auto is on)
    blink = {
      enable_auto_complete = true, -- boolean — automatic blink triggers when virtual auto-trigger is off
    },

    -- Ghost-text (virtual text) UI
    virtualtext = {
      -- Filetypes that auto-trigger ghost text (empty = none; often `{ '*' }`). When set for the buffer,
      -- the blink.cmp phantom-code source does not run there.
      auto_trigger_ft = {}, -- list of filetype strings

      -- Filetypes excluded when `auto_trigger_ft` is broad (e.g. `{ '*' }`)
      auto_trigger_ignore_ft = {}, -- list of filetype strings

      -- Buffer-local keymaps for virtual text (nil = unbound)
      keymap = {
        accept = nil, -- string | nil — insert full suggestion
        accept_line = nil, -- string | nil — first line only
        accept_n_lines = nil, -- string | nil — prompts for count
        next = nil, -- string | nil — next candidate / manual trigger
        prev = nil, -- string | nil — previous candidate / manual trigger
        dismiss = nil, -- string | nil — clear ghost text
      },

      -- Show ghost text while nvim-cmp / blink popup is open
      show_on_completion_menu = false, -- boolean
    },

    -- Truncate each completion to at most this many lines (virtual text only)
    max_lines = nil, -- integer | nil

    -- Minimum milliseconds between inline HTTP requests (0 = no throttle)
    throttle = 500, -- integer

    -- Debounce after typing before requesting (0 = off)
    debounce = 150, -- integer

    -- Minimum ms between CursorMovedI-driven schedule restarts (0 = off)
    cursor_moved_throttle_ms = 50, -- integer

    -- Extra gates before sending an inline request
    request_gating = {
      skip_consecutive_empty_lines = false, -- boolean — skip if current and previous line are blank
    },

    -- Snippets from resolved relative imports added to inline context
    import_context = {
      enable = true, -- boolean
      max_chars = 4000, -- integer — total chars from imports
      max_files = 3, -- integer — max files appended
      max_imports_scanned = 64, -- integer — import lines scanned
    },

    -- Add a single-line duplicate item for multi-line candidates (cmp/blink)
    add_single_line_entry = true, -- boolean

    -- Ignored at runtime (inline always requests one candidate); kept for compatibility
    n_completions = 1, -- integer

    -- Trim completion suffix when it overlaps this many chars with text after the cursor
    after_cursor_filter_length = 15, -- integer

    -- Trim completion prefix overlap with text before the cursor
    before_cursor_filter_length = 2, -- integer

    -- On accept, normalize braces / overlap with cursor (virtual text + blink)
    normalize_on_accept = true, -- boolean

    -- Optional `function(context, cmp_context) return context end` after built-in enrichment
    context_enrich = nil, -- function | nil

    -- If any function returns false, auto inline does not run (manual still works)
    enable_predicates = {}, -- list of fun(): boolean
  },

  expand = {
    -- Master switch for expand keymaps / commands
    enable = false, -- boolean

    -- Expand-only provider; nil = top-level `provider`
    provider = nil, -- string | nil

    -- Merged into `provider_options[expand.provider]`
    provider_options = {}, -- table

    -- Implement mode: system message (default below is the plugin XML contract)
    system = [[You are a precise coding assistant. The user selected code and gave an instruction.

Respond ONLY with a single XML document (no markdown fences, no preamble) of this shape:

<phantom_expand>
  <!-- Option A — replace the entire selection: -->
  <replacement>...full new text for the selection...</replacement>

  <!-- Option B — one or more edits inside the selection (line numbers are 1-based; line 1 = first line of the selection): -->
  <!-- <edit startLine="2" endLine="4">new lines replacing those lines</edit> -->

  Use Option B when several localized changes are clearer than one big replacement. You may use multiple <edit> elements; they must not overlap. Prefer Option A for small selections or full rewrites.

  Do not echo the original selected code outside the tags. No explanations outside the XML.
]], -- string | fun(cfg): string

    -- Generate-at-cursor (empty selection) system prompt
    system_generate = [[You are a precise coding assistant. The user wants new code inserted at the cursor (there may be no selected text).

Respond ONLY with a single XML document (no markdown fences, no preamble) of this shape:

<phantom_expand>
  <replacement>...code to insert at the cursor...</replacement>
</phantom_expand>

Prefer concise, idiomatic code that fits the surrounding file. No explanations outside the XML.
]], -- string | fun(cfg): string

    -- Implement user message template (`<instruction>`, `<selectedCode>`, `<referencedContextBlock>`, …)
    user_template = [[File: <filePath>
Language: <fileType>

<referencedContextBlock>
Instruction:
<instruction>

Selected code:
<selectedCode>

Context before selection:
<fileContextBefore>

Context after selection:
<fileContextAfter>
<diagnosticsBlock>]], -- string | fun(vars, cfg): string

    -- `@file:` / `@symbol:` payload budget
    max_reference_chars = 8000, -- integer

    -- Cap stored implement revise messages (user+assistant pairs); 0 = unlimited
    max_conversation_messages = 16, -- integer

    -- Extra few-shot messages for implement chat API
    few_shots = nil, -- list of { role, content } | nil

    -- Merged over top-level `diagnostics` for expand prompts only
    diagnostics = {}, -- table

    -- Override top-level `context_window` for expand file surround
    context_window = nil, -- integer | nil

    -- Override top-level `context_ratio` for expand file surround
    context_ratio = nil, -- number | nil

    -- Override top-level `request_timeout` for expand HTTP
    request_timeout = nil, -- integer | nil

    -- New expand / dismiss cancels in-flight jobs when true
    cancel_inflight = true, -- boolean

    -- Provider-specific max tokens when supported
    max_tokens = nil, -- integer | nil

    -- Merge model output with selection using built-in rules
    merge = true, -- boolean

    -- Custom merge: `function(selected, response, { bufnr, start_row }) return string end`
    merge_fn = nil, -- function | nil

    -- Legacy preview mode (implement uses inline diff regardless)
    preview = 'inline_extmark', -- string

    -- Implement instruction UI: anchored float vs cmdline input
    prompt_ui = 'float', -- "float" | "input"

    -- Ask mode system prompt
    system_ask = [[You are a helpful coding assistant. Answer clearly and concisely. You may use short markdown (fenced code blocks) when showing examples. Do not invent file paths or APIs not implied by the context.]], -- string | fun(cfg): string

    -- Ask user template (`<question>`, `<conversationBlock>`, …)
    user_template_ask = [[File: <filePath>
Language: <fileType>

Selected code:
<selectedCode>

Context before selection:
<fileContextBefore>

Context after selection:
<fileContextAfter>
<diagnosticsBlock>

<conversationBlock>

Current question:
<question>]], -- string | fun(vars, cfg): string

    ui = {
      -- Max height (lines) for implement prompt float
      prompt_height = 10, -- integer

      -- Width (columns) for implement float
      prompt_width = 72, -- integer

      -- Max height (lines) for ask float
      ask_height = 16, -- integer

      -- Width (columns) for ask float
      ask_width = 80, -- integer

      -- End-of-line virtual text on the selection row while expand UI is hidden (`toggle_window`); `""` disables
      collapsed_marker = ' ⋯ expand', -- string
    },

    inline_diff = {
      -- Draw expand preview as buffer highlights + virtual lines
      enable = true, -- boolean
    },

    keymap = {
      invoke = nil, -- string | nil — implement expand
      ask = nil, -- string | nil — ask / toggle ask
      accept = nil, -- string | nil — apply proposal (buffer-local on code + prompt)
      accept_global = nil, -- string | nil — same as accept, global map while in review (any window)
      dismiss = nil, -- string | nil — cancel session
      revise = nil, -- string | nil — new instruction in review
      focus_window = nil, -- string | nil — jump between code and expand UI
      toggle_window = nil, -- string | nil — hide/show expand float (ask or pinned implement prompt)
    },
  },

  -- Per-provider defaults (merge). Omitted nested tables use `lua/phantom-code/config.lua`.
  provider_options = {
    codestral = {
      model = 'codestral-latest', -- string
      end_point = 'https://codestral.mistral.ai/v1/fim/completions', -- string
      api_key = 'CODESTRAL_API_KEY', -- string — env var name
      stream = true, -- boolean
      optional = { stop = nil, max_tokens = nil }, -- table
      transform = {}, -- list of transform functions
      get_text_fn = {}, -- list — extract text from JSON
    },

    openai = {
      model = 'gpt-5.4-nano', -- string
      api_key = 'OPENAI_API_KEY', -- string — env var name
      end_point = 'https://api.openai.com/v1/chat/completions', -- string
      stream = true, -- boolean
      optional = { stop = nil, max_tokens = nil }, -- table
      transform = {}, -- list
    },

    claude = {
      max_tokens = 256, -- integer
      api_key = 'ANTHROPIC_API_KEY', -- string — env var name
      model = 'claude-haiku-4-5', -- string
      end_point = 'https://api.anthropic.com/v1/messages', -- string
      stream = true, -- boolean
      optional = { stop_sequences = nil }, -- table
      transform = {}, -- list
    },

    openai_compatible = {
      model = 'mistralai/devstral-small', -- string
      api_key = 'OPENROUTER_API_KEY', -- string — env var name
      end_point = 'https://openrouter.ai/api/v1/chat/completions', -- string
      name = 'Openrouter', -- string — sub-provider label for model cards, etc.
      stream = true, -- boolean
      optional = { stop = nil, max_tokens = nil }, -- table
      transform = {}, -- list
    },

    gemini = {
      model = 'gemini-2.0-flash', -- string
      api_key = 'GEMINI_API_KEY', -- string — env var name
      end_point = 'https://generativelanguage.googleapis.com/v1beta/models', -- string
      stream = true, -- boolean
      optional = {}, -- table
      transform = {}, -- list
    },

    openai_fim_compatible = {
      model = 'deepseek-chat', -- string
      end_point = 'https://api.deepseek.com/beta/completions', -- string
      api_key = 'DEEPSEEK_API_KEY', -- string — env var name
      name = 'Deepseek', -- string
      stream = true, -- boolean
      optional = { stop = nil, max_tokens = nil }, -- table
      transform = {}, -- list
      get_text_fn = {}, -- list
    },
  },
})
```

## Highlight groups


| Group                         | Default                  | Purpose                                    |
| ----------------------------- | ------------------------ | ------------------------------------------ |
| `PhantomCodeVirtualText`      | `Comment`                | Inline ghost text                          |
| `BlinkCmpItemKindPhantomCode` | `BlinkCmpItemKind`       | blink.cmp kind color                       |
| `PhantomCodeExpandPulse1`     | `Comment`                | Expand busy pulse A                        |
| `PhantomCodeExpandPulse2`     | `Special`                | Expand busy pulse B                        |
| `PhantomCodeExpandPreview`    | `PhantomCodeVirtualText` | Expand preview text                        |
| `PhantomCodeExpandGenBar`     | `Pmenu`                  | Expand generating status padding           |
| `PhantomCodeExpandGenAccent`  | `DiagnosticInfo`         | Expand generating left rule                |
| `PhantomCodeExpandGenLabel`   | `Title`                  | Expand generating label                    |
| `PhantomCodeExpandGenPrompt`  | `Special`                | Expand generating instruction snippet      |
| `PhantomCodeExpandDiffAdd`    | `DiffAdd`                | Expand inline diff: added line virt text   |
| `PhantomCodeExpandDiffDelete` | `DiffDelete`             | Expand inline diff: deleted line highlight |
| `PhantomCodeExpandDiffChange` | `DiffText`               | Expand inline diff: changed line highlight |


## Events

`User` autocmds fired during requests. `args.data` contains metadata (provider, model, timestamp, etc.).


| Pattern                        | When                      |
| ------------------------------ | ------------------------- |
| `PhantomCodeRequestStartedPre` | Before spawning HTTP jobs |
| `PhantomCodeRequestStarted`    | After each job starts     |
| `PhantomCodeRequestFinished`   | After each job finishes   |


## Advanced

Prompt templates, FIM suffix handling, `transform` pipelines, and job pools are documented in [docs/technical.md](docs/technical.md).