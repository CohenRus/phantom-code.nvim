local default_prompt_prefix_first = [[
You are an AI code completion engine modeled after Cursor Tab. Your sole function is to predict and complete what the user is most likely to type next, based on all available context.
Core Behavior

Input markers:
- `<contextAfterCursor>`: Context after cursor
- `<cursorPosition>`: Current cursor location
- `<contextBeforeCursor>`: Context before cursor

Analyze everything before and after <cursorPosition> to infer intent.
Return exactly one completion: the single highest-confidence prediction.
The completion must begin exactly at <cursorPosition> — never repeat or echo any surrounding code.
Preserve the user's exact whitespace, indentation style, and newline conventions.
]]

local default_prompt = default_prompt_prefix_first
    .. [[

Note that the user input will be provided in **reverse** order: first the
context after cursor, followed by the context before cursor.
]]

local default_guidelines = [[
Completion Style

Finish the current line or token first: close brackets/parens/quotes, finish the expression, or add at most one short following line when the cursor is clearly mid-statement
Avoid multi-line blobs, whole functions, or large refactors — keep ghost text small and local (roughly one line unless you are only closing a single syntactic unit)
Match the surrounding code's style: naming, brackets, spacing, idioms
In comments or docstrings, add at most a short clause, not full paragraphs
In string literals, complete only the likely immediate fragment

Output Rules

Output the completion text only — no explanation, no markdown fences, no preamble
Do not reproduce any code that already appears before or after <cursorPosition>
Never begin the completion with tokens already present immediately before <cursorPosition> (e.g. a `{` that already ends the current line). Never end the completion with tokens already present immediately after <cursorPosition> (e.g. a closing `}` or `;` on the next line).
End with <endCompletion>
If no confident completion exists, output only <endCompletion>
]]

local default_few_shots = {
    {
        role = 'user',
        content = [[
# language: javascript
<contextAfterCursor>
    return result;
}

const processedData = transformData(rawData, {
    uppercase: true,
    removeSpaces: false
});
<contextBeforeCursor>
function transformData(data, options) {
    const result = [];
    for (let item of data) {
        <cursorPosition>]],
    },
    {
        role = 'assistant',
        content = [[
        if (options.uppercase) {
            item = item.toUpperCase();
        }
        result.push(item);
<endCompletion>
]],
    },
}

local default_few_shots_prefix_first = {
    {
        role = 'user',
        content = [[
# language: javascript
<contextBeforeCursor>
function transformData(data, options) {
    const result = [];
    for (let item of data) {
        <cursorPosition>
<contextAfterCursor>
    return result;
}

const processedData = transformData(rawData, {
    uppercase: true,
    removeSpaces: false
});]],
    },
    default_few_shots[2],
}

local n_completion_template = '8. Provide at most %d completion items.'

local default_expand_system = [[You are a precise coding assistant. The user selected code in their editor and gave an instruction.
Output only the replacement code (or generated code that should replace the selection). Do not wrap the answer in markdown fences unless the file already uses that pattern. No explanations or preamble.
Do NOT echo or repeat the selected code before your replacement. Output only the replacement, exactly once.

If the selection already includes a declaration or signature with an empty block (e.g. `int foo() { }`), output either (a) only the new statements that belong inside the braces, or (b) the full corrected snippet that should replace the entire selection — do not duplicate the same declaration before the body. Prefer (a) when the scaffolding is already correct.]]

local default_expand_user_template = [[File: <filePath>
Language: <fileType>

Instruction:
<instruction>

Selected code:
<selectedCode>

Context before selection:
<fileContextBefore>

Context after selection:
<fileContextAfter>
<diagnosticsBlock>]]

-- use {{{ and }}} to wrap placeholders, which will be further processesed in other function
local default_system_template = '{{{prompt}}}\n{{{guidelines}}}\n{{{n_completion_template}}}'

local default_fim_prompt = function(context_before_cursor, _, opts)
    local utils = require 'phantom-code.utils'
    local language = utils.add_language_comment()
    local tab = utils.add_tab_comment()
    local fim_hint = utils.add_fim_completion_instruction_comment()
    opts = opts or {}

    local extra = ''
    local diag = opts.diagnostics_context
    if type(diag) == 'string' and diag ~= '' then
        extra = extra .. '<diagnostics>\n' .. diag .. '\n</diagnostics>\n'
    end

    context_before_cursor = language .. '\n' .. tab .. '\n' .. fim_hint .. '\n' .. extra .. context_before_cursor

    return context_before_cursor
end

local default_fim_suffix = function(_, context_after_cursor, _)
    return context_after_cursor
end

---@class phantom-code.ChatInputExtraInfo
---@field is_incomplete_before boolean
---@field is_incomplete_after boolean
---@field diagnostics_context string

---@alias phantom-code.ChatInputFunction fun(context_before_cursor: string, context_after_cursor: string, opts: phantom-code.ChatInputExtraInfo): string
---@alias phantom-code.FIMTemplateFunction phantom-code.ChatInputFunction

--- Configuration for formatting chat input to the LLM
---@class phantom-code.ChatInput
---@field template string Template string with placeholders for context parts
---@field language phantom-code.ChatInputFunction function to add language comment based on filetype
---@field tab phantom-code.ChatInputFunction function to add indentation style comment
---@field diagnostics phantom-code.ChatInputFunction optional diagnostics block from top-level `diagnostics` settings
---@field context_before_cursor phantom-code.ChatInputFunction function to process text before cursor
---@field context_after_cursor phantom-code.ChatInputFunction function to process text after cursor

---@type phantom-code.ChatInput
local default_chat_input = {
    template = '{{{language}}}\n{{{tab}}}\n{{{diagnostics}}}\n<contextAfterCursor>\n{{{context_after_cursor}}}\n<contextBeforeCursor>\n{{{context_before_cursor}}}<cursorPosition>',
    language = function(_, _, _)
        local utils = require 'phantom-code.utils'
        return utils.add_language_comment()
    end,
    tab = function(_, _, _)
        local utils = require 'phantom-code.utils'
        return utils.add_tab_comment()
    end,
    context_before_cursor = function(context_before_cursor, _, opts)
        if opts.is_incomplete_before then
            -- Remove first line when context is incomplete at start
            local _, rest = context_before_cursor:match '([^\n]*)\n(.*)'
            return rest or context_before_cursor
        end
        return context_before_cursor
    end,
    context_after_cursor = function(_, context_after_cursor, opts)
        if opts.is_incomplete_after then
            -- Remove last line when context is incomplete at end
            local content = context_after_cursor:match '(.*)[\n][^\n]*$'
            return content or context_after_cursor
        end
        return context_after_cursor
    end,
    diagnostics = function(_, _, opts)
        local s = opts.diagnostics_context
        if type(s) ~= 'string' or s == '' then
            return ''
        end
        return '<diagnostics>\n' .. s .. '\n</diagnostics>\n'
    end,
}

---@type phantom-code.ChatInput
local default_chat_input_prefix_first = vim.deepcopy(default_chat_input)
default_chat_input_prefix_first.template =
    '{{{language}}}\n{{{tab}}}\n{{{diagnostics}}}\n<contextBeforeCursor>\n{{{context_before_cursor}}}<cursorPosition>\n<contextAfterCursor>\n{{{context_after_cursor}}}'

local M = {
    --- Inline Tab completion (virtual text, blink-cmp): UI, timing, prompts, provider overrides. Not used by Expand.
    inline = {
        blink = {
            enable_auto_complete = true,
        },
        virtualtext = {
            -- Specify the filetypes to enable automatic virtual text completion,
            -- e.g., { 'python', 'lua' }. Note that you can still invoke manual
            -- completion even if the filetype is not on your auto_trigger_ft list.
            auto_trigger_ft = {},
            -- specify file types where automatic virtual text completion should be
            -- disabled. This option is useful when auto-completion is enabled for
            -- all file types i.e., when auto_trigger_ft = { '*' }
            auto_trigger_ignore_ft = {},
            keymap = {
                accept = nil,
                accept_line = nil,
                -- accept n lines (prompts for number)
                accept_n_lines = nil,
                -- Cycle to next completion item, or manually invoke completion
                next = nil,
                -- Cycle to prev completion item, or manually invoke completion
                prev = nil,
                dismiss = nil,
            },
            -- Whether show virtual text suggestion when the completion menu
            -- (nvim-cmp or blink-cmp) is visible.
            show_on_completion_menu = false,
        },
        provider = nil,
        provider_options = {},
        prompt_overrides = {},
        --- If set, truncate each completion to at most this many lines (virtual text only).
        max_lines = nil,
        throttle = 1000, -- only send the request every x milliseconds, use 0 to disable throttle.
        -- debounce the request in x milliseconds, set 0 to disable debounce
        debounce = 400,
        -- If completion item has multiple lines, create another completion item
        -- only containing its first line. This option only has impact for cmp and
        -- blink. For virtualtext, no single line entry will be added.
        add_single_line_entry = true,
        -- Ignored: inline completion always requests exactly one candidate (`utils.INLINE_N_COMPLETIONS`).
        -- Kept in config for backward compatibility with existing user `setup()` tables.
        n_completions = 1,
        --  Length of context after cursor used to filter completion text.
        --
        -- This setting helps prevent the language model from generating redundant
        -- text.  When filtering completions, the system compares the suffix of a
        -- completion candidate with the text immediately following the cursor.
        --
        -- If the length of the longest common substring between the end of the
        -- candidate and the beginning of the post-cursor context exceeds this
        -- value, that common portion is trimmed from the candidate.
        --
        -- For example, if the value is 15, and a completion candidate ends with a
        -- 20-character string that exactly matches the 20 characters following the
        -- cursor, the candidate will be truncated by those 20 characters before
        -- being delivered.
        after_cursor_filter_length = 15,
        -- Similar to after_cursor_filter_length but trim the completion item from
        -- prefix instead of suffix.
        before_cursor_filter_length = 2,
        --- On accept (virtual text and blink): re-trim overlap; drop duplicate `{` after `{`; drop trailing `}` when `}` already follows the cursor (including on the next line).
        normalize_on_accept = true,
        -- Optional: after built-in extras, `function(context, cmp_context) return context end`. Return a new table to replace context.
        context_enrich = nil,
        -- **List** of functions to execute. If any function returns `false`, phantom-code
        -- will not trigger auto-completion. Manual completion can still be invoked.
        ---@type (fun(): boolean)[]
        enable_predicates = {},
    },
    --- Expand selection flow (visual range + prompt + chat). Separate prompts and jobs from inline.
    expand = {
        enable = false,
        provider = nil,
        provider_options = {},
        system = default_expand_system,
        user_template = default_expand_user_template,
        few_shots = nil,
        --- Deep-merge over top-level `diagnostics` for Expand only.
        diagnostics = {},
        context_window = nil,
        --- When set, overrides top-level `context_ratio` for Expand file surround only.
        context_ratio = nil,
        request_timeout = nil,
        --- When true (default), starting a new Expand or calling dismiss cancels in-flight requests and clears prior previews. When false, multiple expands may run concurrently; use float preview so each preview has its own accept/dismiss keys. Concurrent inline previews on the same buffer share one accept/dismiss binding (last preview wins).
        cancel_inflight = true,
        max_tokens = nil,
        --- When true, merge model output with the selection (empty `{}` body fill, strip echoed selection, trim extra `}`).
        merge = true,
        --- Optional `function(selected, response, { bufnr, start_row }) return string end` overrides built-in merge.
        merge_fn = nil,
        preview = 'inline_extmark',
        --- `'float'` (default): centered float like preview. `'input'`: `vim.ui.input` on cmdline.
        prompt_ui = 'float',
        keymap = {
            invoke = nil,
            accept = nil,
            dismiss = nil,
        },
    },
    -- Must match `lua/phantom-code/backends/<name>.lua` (codestral/gemini have no module in-repo).
    provider = 'openai_compatible',
    -- the maximum total characters of the context before and after the cursor
    -- 16000 characters typically equate to approximately 4,000 tokens for
    -- LLMs.
    context_window = 16000,
    -- when the total characters exceed the context window, the ratio of
    -- context before cursor and after cursor, the larger the ratio the more
    -- context before cursor will be used. This option should be between 0 and
    -- 1, context_ratio = 0.75 means the ratio will be 3:1.
    context_ratio = 0.75,
    -- Control notification display for request status
    -- Notification options:
    -- false: Disable all notifications (use boolean false, not string "false")
    -- "debug": Display all notifications (comprehensive debugging)
    -- "verbose": Display most notifications
    -- "warn": Display warnings and errors only
    -- "error": Display errors only
    notify = 'warn',
    -- The request timeout, measured in seconds. When streaming is enabled
    -- (stream = true), setting a shorter request_timeout allows for faster
    -- retrieval of completion items, albeit potentially incomplete.
    -- Conversely, with streaming disabled (stream = false), a timeout
    -- occurring before the LLM returns results will yield no completion items.
    request_timeout = 3,
    -- Command used to make HTTP requests.
    curl_cmd = 'curl',
    -- Extra arguments passed to curl (list of strings).
    curl_extra_args = {},
    proxy = nil,
    -- Nearby LSP diagnostics for prompts; fills `opts.diagnostics_context` for chat/FIM templates.
    diagnostics = {
        enable = false,
        line_radius = 12,
        min_severity = vim.diagnostic.severity.HINT,
        max_chars = 2048,
    },
}

M.default_system = {
    template = default_system_template,
    prompt = default_prompt,
    guidelines = default_guidelines,
    n_completion_template = n_completion_template,
}

M.default_system_prefix_first = {
    template = default_system_template,
    prompt = default_prompt_prefix_first,
    guidelines = default_guidelines,
    n_completion_template = n_completion_template,
}

M.default_chat_input = default_chat_input
M.default_chat_input_prefix_first = default_chat_input_prefix_first

M.default_few_shots = default_few_shots
M.default_few_shots_prefix_first = default_few_shots_prefix_first

--- Configuration for FIM template
---@class phantom-code.FIMTemplate
---@field prompt phantom-code.FIMTemplateFunction
---@field suffix phantom-code.FIMTemplateFunction | boolean

---@type phantom-code.FIMTemplate
M.default_fim_template = {
    prompt = default_fim_prompt,
    suffix = default_fim_suffix,
}

M.provider_options = {
    codestral = {
        model = 'codestral-latest',
        end_point = 'https://codestral.mistral.ai/v1/fim/completions',
        api_key = 'CODESTRAL_API_KEY',
        stream = true,
        template = M.default_fim_template,
        optional = {
            stop = nil, -- the identifier to stop the completion generation
            max_tokens = nil,
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
        -- Custom function to extract LLM-generated text from JSON output
        get_text_fn = {},
    },
    openai = {
        model = 'gpt-5.4-nano',
        api_key = 'OPENAI_API_KEY',
        end_point = 'https://api.openai.com/v1/chat/completions',
        system = M.default_system_prefix_first,
        few_shots = M.default_few_shots_prefix_first,
        chat_input = M.default_chat_input_prefix_first,
        stream = true,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    },
    claude = {
        max_tokens = 256,
        api_key = 'ANTHROPIC_API_KEY',
        model = 'claude-haiku-4-5',
        end_point = 'https://api.anthropic.com/v1/messages',
        system = M.default_system,
        chat_input = M.default_chat_input,
        few_shots = M.default_few_shots,
        stream = true,
        optional = {
            stop_sequences = nil,
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    },
    openai_compatible = {
        model = 'mistralai/devstral-small',
        system = M.default_system,
        chat_input = M.default_chat_input,
        few_shots = M.default_few_shots,
        end_point = 'https://openrouter.ai/api/v1/chat/completions',
        api_key = 'OPENROUTER_API_KEY',
        name = 'Openrouter',
        stream = true,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    },
    gemini = {
        model = 'gemini-2.0-flash',
        api_key = 'GEMINI_API_KEY',
        end_point = 'https://generativelanguage.googleapis.com/v1beta/models',
        system = M.default_system_prefix_first,
        chat_input = M.default_chat_input_prefix_first,
        few_shots = M.default_few_shots_prefix_first,
        stream = true,
        optional = {},
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    },
    openai_fim_compatible = {
        model = 'deepseek-chat',
        end_point = 'https://api.deepseek.com/beta/completions',
        api_key = 'DEEPSEEK_API_KEY',
        name = 'Deepseek',
        stream = true,
        template = M.default_fim_template,
        optional = {
            stop = nil,
            max_tokens = nil,
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
        -- Custom function to extract LLM-generated text from JSON output
        get_text_fn = {},
    },
}

return M
