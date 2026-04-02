# phantom-code.nvim

> **Based on [minuet-ai.nvim](https://github.com/milanglacier/minuet-ai.nvim)** by Milan Glacier (GPL-3.0).
> This project is a derivative of minuet-ai.nvim and is distributed under the same **GPL-3.0** license.

AI-powered code completion and rewriting for Neovim. Get inline ghost text suggestions as you type, and rewrite selected code with natural language instructions.

## Highlights

- **Inline completion** -- ghost text suggestions appear as you type, powered by any LLM
- **Expand** -- select code, describe what you want, and the plugin rewrites it in place
- **Multi-provider** -- Claude, OpenAI, OpenRouter, DeepSeek, Ollama, or any OpenAI-compatible API
- **Two completion strategies** -- chat-based (system prompt + context) or fill-in-the-middle (FIM)
- **[blink.cmp](https://github.com/Saghen/blink.cmp) integration** -- use ghost text, the popup menu, or both
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
      keymap = {
        invoke = '<leader>ae',
        accept = '<leader>ay',
        dismiss = '<leader>an',
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

The plugin sends surrounding code (controlled by `context_window` / `context_ratio`) and optional LSP diagnostics to the LLM, then displays the result as virtual text.

### Expand

1. Select code in visual mode
2. Press your invoke keymap (e.g. `<leader>ae`)
3. Type an instruction in the floating prompt (e.g. "add error handling", "convert to async")
4. Review the preview, then accept or dismiss

Expand uses a separate chat request with its own system prompt and context budget, so it works independently from inline completion.

## Providers

| Key                     | Strategy | Notes                                                            |
| ----------------------- | -------- | ---------------------------------------------------------------- |
| `claude`                | Chat     | Anthropic Messages API                                           |
| `openai`                | Chat     | OpenAI Chat Completions API                                      |
| `openai_compatible`     | Chat     | OpenRouter, Groq, local servers, or any OpenAI-compatible API    |
| `openai_fim_compatible` | FIM      | DeepSeek, Ollama `/v1/completions`, or any FIM-compatible API    |

You can use different providers for inline and Expand by setting `inline.provider` and `expand.provider` separately.

## Commands

`:PhantomCode` subcommands complete with Tab.

| Command                        | Effect                                          |
| ------------------------------ | ----------------------------------------------- |
| `:PhantomCode virtualtext enable`  | Enable virtual-text auto-trigger in this buffer |
| `:PhantomCode virtualtext disable` | Disable auto-trigger in this buffer             |
| `:PhantomCode virtualtext toggle`  | Toggle auto-trigger in this buffer              |
| `:PhantomCode blink enable`        | Enable blink auto-complete for phantom-code source  |
| `:PhantomCode blink disable`       | Disable blink auto-complete                     |
| `:PhantomCode blink toggle`        | Toggle blink auto-complete                      |
| `:PhantomCode expand`              | Run Expand using visual marks `'<` `'>`         |

## Configuration

All keys are optional -- omit anything you don't need and defaults apply. See the full annotated config below.

<details>
<summary>Full configuration reference</summary>

```lua
require('phantom-code').setup({
  -- Default backend if inline.provider / expand.provider are unset
  provider = 'openai_compatible',

  -- Max characters of context sent to the model
  context_window = 16000,

  -- Fraction of context_window placed before the cursor (rest goes after)
  context_ratio = 0.75,

  -- Curl timeout in seconds
  request_timeout = 3,

  -- Notification level: false | "error" | "warn" | "verbose" | "debug"
  notify = 'warn',

  -- Curl executable
  curl_cmd = 'curl',
  curl_extra_args = {},
  proxy = nil,

  -- Inject nearby LSP diagnostics into the prompt
  diagnostics = {
    enable = false,
    line_radius = 12,
    min_severity = vim.diagnostic.severity.HINT,
    max_chars = 2048,
  },

  inline = {
    provider = 'openai_fim_compatible',
    provider_options = {},
    prompt_overrides = {},
    -- max_lines = 3,
    throttle = 1000,
    debounce = 400,
    add_single_line_entry = true,
    n_completions = 1,
    after_cursor_filter_length = 15,
    before_cursor_filter_length = 2,
    context_enrich = function(ctx, _) return ctx end,
    enable_predicates = {},

    virtualtext = {
      auto_trigger_ft = {},
      auto_trigger_ignore_ft = {},
      keymap = {
        accept = nil,
        accept_line = nil,
        accept_n_lines = nil,
        next = nil,
        prev = nil,
        dismiss = nil,
      },
      show_on_completion_menu = false,
    },

    blink = {
      enable_auto_complete = true,
    },
  },

  expand = {
    enable = false,
    -- provider = 'openai_compatible',
    diagnostics = {},
    -- context_window = 12000,
    -- context_ratio = 0.6,
    -- request_timeout = 60,
    -- max_tokens = 4096,
    -- cancel_inflight = false,
    preview = 'inline_extmark',
    -- prompt_ui = 'input',
    -- system = '...',
    -- user_template = '...',
    -- few_shots = {},
    provider_options = {},
    keymap = {
      -- invoke = '<leader>ae',
      -- accept = '<leader>ay',
      -- dismiss = '<leader>an',
    },
  },

  provider_options = {
    openai = {
      model = 'gpt-5.4-nano',
      api_key = 'OPENAI_API_KEY',
      end_point = 'https://api.openai.com/v1/chat/completions',
      stream = true,
      optional = { stop = nil, max_tokens = nil },
      transform = {},
    },

    claude = {
      max_tokens = 256,
      api_key = 'ANTHROPIC_API_KEY',
      model = 'claude-haiku-4-5',
      end_point = 'https://api.anthropic.com/v1/messages',
      stream = true,
      optional = { stop_sequences = nil },
      transform = {},
    },

    openai_compatible = {
      model = 'mistralai/devstral-small',
      api_key = 'OPENROUTER_API_KEY',
      end_point = 'https://openrouter.ai/api/v1/chat/completions',
      name = 'Openrouter',
      stream = true,
      optional = { stop = nil, max_tokens = nil },
      transform = {},
    },

    openai_fim_compatible = {
      model = 'deepseek-chat',
      end_point = 'https://api.deepseek.com/beta/completions',
      api_key = 'DEEPSEEK_API_KEY',
      name = 'Deepseek',
      stream = true,
      optional = { stop = nil, max_tokens = nil },
      transform = {},
      get_text_fn = {},
    },
  },
})
```

</details>

## Highlight groups

| Group                     | Default              | Purpose                              |
| ------------------------- | -------------------- | ------------------------------------ |
| `PhantomCodeVirtualText`      | `Comment`            | Inline ghost text                    |
| `BlinkCmpItemKindPhantomCode` | `BlinkCmpItemKind`   | blink.cmp kind color                 |
| `PhantomCodeExpandPulse1`     | `Comment`            | Expand busy pulse A                  |
| `PhantomCodeExpandPulse2`     | `Special`            | Expand busy pulse B                  |
| `PhantomCodeExpandPreview`    | `PhantomCodeVirtualText` | Expand preview text                  |
| `PhantomCodeExpandGenBar`     | `Pmenu`              | Expand generating status padding     |
| `PhantomCodeExpandGenAccent`  | `DiagnosticInfo`     | Expand generating left rule          |
| `PhantomCodeExpandGenLabel`   | `Title`              | Expand generating label              |
| `PhantomCodeExpandGenPrompt`  | `Special`            | Expand generating instruction snippet|

## Events

`User` autocmds fired during requests. `args.data` contains metadata (provider, model, timestamp, etc.).

| Pattern                    | When                      |
| -------------------------- | ------------------------- |
| `PhantomCodeRequestStartedPre` | Before spawning HTTP jobs |
| `PhantomCodeRequestStarted`    | After each job starts     |
| `PhantomCodeRequestFinished`   | After each job finishes   |

## Advanced

Prompt templates, FIM suffix handling, `transform` pipelines, and job pools are documented in [docs/technical.md](docs/technical.md).

