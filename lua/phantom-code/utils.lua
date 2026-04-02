local M = {}

--- Shorten strings for vim.notify to avoid leaking large API bodies into logs/UI.
---@param s any
---@param max_len? integer
---@return string
local function truncate_for_notify(s, max_len)
    max_len = max_len or 400
    if type(s) ~= 'string' then
        s = vim.inspect(s)
    end
    if #s <= max_len then
        return s
    end
    return s:sub(1, max_len) .. '… (truncated)'
end

--- Inline ghost text / blink / FIM: only one candidate is requested from the model and shown in the UI.
M.INLINE_N_COMPLETIONS = 1

--- If the model returns multiple `<endCompletion>`-separated items, keep only the first for inline.
---@param items string[]|nil
---@return string[]|nil
function M.limit_inline_completion_items(items)
    if not items or #items <= 1 then
        return items
    end
    return { items[1] }
end

function M.notify(msg, level, vim_level, opts)
    local config = require('phantom-code').config
    local notify_levels = {
        debug = 0,
        verbose = 1,
        warn = 2,
        error = 3,
    }

    if config.notify and notify_levels[level] >= notify_levels[config.notify] then
        vim.notify(msg, vim_level, opts)
    end
end

--- Get API key from environment variable or function.
---@param env_var string|function environment variable name or function returning API key
---@return string? API key or nil if not found or invalid
function M.get_api_key(env_var)
    local api_key
    if type(env_var) == 'function' then
        api_key = env_var()
    elseif type(env_var) == 'string' then
        api_key = vim.env[env_var]
    end

    if type(api_key) ~= 'string' or api_key == '' then
        return nil
    end

    return api_key
end

-- referenced from cmp_ai
function M.make_tmp_file(content)
    local tmp_file = vim.fn.tempname()

    local f = io.open(tmp_file, 'w+')
    if f == nil then
        M.notify('Cannot open temporary message file: ' .. tmp_file, 'error', vim.log.levels.ERROR)
        return
    end

    local result, json = pcall(vim.json.encode, content)

    if not result then
        M.notify('Failed to encode completion request data', 'error', vim.log.levels.ERROR)
        return
    end

    f:write(json)
    f:close()

    return tmp_file
end

function M.make_system_prompt(template, n_completion)
    ---- replace the placeholders in the template with the values in the table
    local system_prompt = template.template
    local n_completion_template = template.n_completion_template

    if type(system_prompt) == 'function' then
        system_prompt = system_prompt()
    end

    if type(n_completion_template) == 'function' then
        n_completion_template = n_completion_template()
    end

    if type(n_completion_template) == 'string' and type(n_completion) == 'number' then
        n_completion_template = string.format(n_completion_template, n_completion)
        system_prompt = system_prompt:gsub('{{{n_completion_template}}}', n_completion_template)
    end

    template.template = nil
    template.n_completion_template = nil

    for k, v in pairs(template) do
        if type(v) == 'function' then
            system_prompt = system_prompt:gsub('{{{' .. k .. '}}}', v())
        elseif type(v) == 'string' then
            system_prompt = system_prompt:gsub('{{{' .. k .. '}}}', v)
        end
    end

    ---- remove the placeholders that are not replaced
    system_prompt = system_prompt:gsub('{{{.*}}}', '')

    return system_prompt
end

--- Return val if val is not a function, else call val and return the value
function M.get_or_eval_value(val)
    if type(val) ~= 'function' then
        return val
    end
    return val()
end

---@return string
function M.add_language_comment()
    if vim.bo.ft == nil or vim.bo.ft == '' then
        return ''
    end

    local language_string = 'language: ' .. vim.bo.ft
    local commentstring = vim.bo.commentstring

    if commentstring == nil or commentstring == '' then
        return '# ' .. language_string
    end

    -- Directly replace %s with the comment
    if commentstring:find '%%s' then
        language_string = commentstring:gsub('%%s', language_string)
        return language_string
    end

    -- Fallback to prepending comment if no %s found
    return commentstring .. ' ' .. language_string
end

---@return string
function M.add_tab_comment()
    if vim.bo.ft == nil or vim.bo.ft == '' then
        return ''
    end

    local tab_string
    local tabwidth = vim.bo.softtabstop > 0 and vim.bo.softtabstop or vim.bo.shiftwidth
    local commentstring = vim.bo.commentstring

    if vim.bo.expandtab and tabwidth > 0 then
        tab_string = 'indentation: use ' .. tabwidth .. ' spaces for a tab'
    elseif not vim.bo.expandtab then
        tab_string = 'indentation: use \t for a tab'
    else
        return ''
    end

    if commentstring == nil or commentstring == '' then
        return '# ' .. tab_string
    end

    -- Directly replace %s with the comment
    if commentstring:find '%%s' then
        tab_string = commentstring:gsub('%%s', tab_string)
        return tab_string
    end

    -- Fallback to prepending comment if no %s found
    return commentstring .. ' ' .. tab_string
end

--- Short instruction for FIM prefix (no chat system prompt on that path).
---@return string
function M.add_fim_completion_instruction_comment()
    local instruction = 'Gap-fill: emit only code tokens; no explanatory or fix comments.'
    local commentstring = vim.bo.commentstring

    if commentstring == nil or commentstring == '' then
        return '# ' .. instruction
    end

    if commentstring:find '%%s' then
        return commentstring:gsub('%%s', instruction)
    end

    return commentstring .. ' ' .. instruction
end

--- Text from (row0, col0_byte) through following lines, for brace / overlap logic. col0_byte is 0-based byte index like nvim_win_get_cursor.
---@param bufnr integer
---@param row0 integer 0-based line
---@param col0_byte integer 0-based byte column on row0
---@param max_lines? integer
---@param max_chars? integer
---@return string
function M.text_after_cursor_multiline(bufnr, row0, col0_byte, max_lines, max_chars)
    max_lines = max_lines or 32
    max_chars = max_chars or 1024
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return ''
    end
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if row0 < 0 or row0 >= line_count then
        return ''
    end
    col0_byte = col0_byte or 0
    local first = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1] or ''
    local rest_first = string.sub(first, col0_byte + 1)
    local out = { rest_first }
    local total = vim.fn.strchars(rest_first)
    local r = row0 + 1
    local n = 1
    while r < line_count and n < max_lines and total < max_chars do
        local L = vim.api.nvim_buf_get_lines(bufnr, r, r + 1, false)[1] or ''
        table.insert(out, L)
        total = total + 1 + vim.fn.strchars(L)
        r = r + 1
        n = n + 1
    end
    return table.concat(out, '\n')
end

-- Copied from blink.cmp.Context. Because we might use nvim-cmp instead of
-- blink-cmp, so blink might not be installed, so we create another class here
-- and use it instead.

--- @class phantom-code.BlinkCmpContext
--- @field line string
--- @field cursor number[]
--- @field bufnr number|nil

---@param blink_context phantom-code.BlinkCmpContext?
function M.make_cmp_context(blink_context)
    local self = {}
    local cursor
    if blink_context then
        cursor = blink_context.cursor
        self.cursor_line = blink_context.line
    else
        cursor = vim.api.nvim_win_get_cursor(0)
        self.cursor_line = vim.api.nvim_get_current_line()
    end

    self.cursor = {}
    self.cursor.row = cursor[1]
    self.cursor.col = cursor[2] + 1
    self.cursor.line = self.cursor.row - 1
    -- self.cursor.character = require('cmp.utils.misc').to_utfindex(self.cursor_line, self.cursor.col)
    self.cursor_before_line = string.sub(self.cursor_line, 1, self.cursor.col - 1)
    self.cursor_after_line = string.sub(self.cursor_line, self.cursor.col)
    self.bufnr = (blink_context and blink_context.bufnr) or vim.api.nvim_get_current_buf()
    return self
end

--- Get the context around the cursor position for code completion
---@param cmp_context table The completion context object containing cursor position and line info
---@return table Context information with the following fields:
---   - lines_before: string - Text content before cursor, truncated based on context window size
---   - lines_after: string - Text content after cursor, truncated based on context window size
---   - opts: table - Options indicating if context was truncated:
---     - is_incomplete_before: boolean - True if content before cursor was truncated
---     - is_incomplete_after: boolean - True if content after cursor was truncated
function M.get_context(cmp_context)
    local config = require('phantom-code').config

    local cursor = cmp_context.cursor
    local line = cursor.line
    if line == nil and cursor.row ~= nil then
        line = cursor.row - 1
    end
    line = line or 0

    local bufnr = cmp_context.bufnr or vim.api.nvim_get_current_buf()
    local lines_before_list = vim.api.nvim_buf_get_lines(bufnr, 0, line, false)
    local lines_after_list = vim.api.nvim_buf_get_lines(bufnr, line + 1, -1, false)

    local lines_before = table.concat(lines_before_list, '\n')
    local lines_after = table.concat(lines_after_list, '\n')

    lines_before = lines_before .. '\n' .. cmp_context.cursor_before_line
    lines_after = cmp_context.cursor_after_line .. '\n' .. lines_after

    local n_chars_before = vim.fn.strchars(lines_before)
    local n_chars_after = vim.fn.strchars(lines_after)

    local opts = {
        is_incomplete_before = false,
        is_incomplete_after = false,
    }

    if n_chars_before + n_chars_after > config.context_window then
        -- use some heuristic to decide the context length of before cursor and after cursor
        if n_chars_before < config.context_window * config.context_ratio then
            -- If the context length before cursor does not exceed the maximum
            -- size, we include the full content before the cursor.
            lines_after = vim.fn.strcharpart(lines_after, 0, config.context_window - n_chars_before)
            opts.is_incomplete_after = true
        elseif n_chars_after < config.context_window * (1 - config.context_ratio) then
            -- if the context length after cursor does not exceed the maximum
            -- size, we include the full content after the cursor.
            lines_before = vim.fn.strcharpart(lines_before, n_chars_before + n_chars_after - config.context_window)
            opts.is_incomplete_before = true
        else
            -- at the middle of the file, use the context_ratio to determine the allocation
            lines_after =
                vim.fn.strcharpart(lines_after, 0, math.floor(config.context_window * (1 - config.context_ratio)))

            lines_before = vim.fn.strcharpart(
                lines_before,
                n_chars_before - math.floor(config.context_window * config.context_ratio)
            )

            opts.is_incomplete_before = true
            opts.is_incomplete_after = true
        end
    end

    return {
        lines_before = lines_before,
        lines_after = lines_after,
        opts = opts,
    }
end

-- Per-diagnostic message width when formatting (not configurable).
local DIAG_MESSAGE_CHARS = 200

local function diagnostic_severity_name(severity)
    local S = vim.diagnostic.severity
    if not severity or not S then
        return 'unknown'
    end
    if severity == S.ERROR then
        return 'error'
    elseif severity == S.WARN then
        return 'warn'
    elseif severity == S.INFO then
        return 'info'
    elseif severity == S.HINT then
        return 'hint'
    end
    return tostring(severity)
end

---@param bufnr number
---@param cursor_row_1 number 1-indexed line of anchor (cursor or selection start)
---@param cfg table
---@return string
function M.build_diagnostics_context(bufnr, cursor_row_1, cfg)
    if not cfg or not cfg.enable then
        return ''
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
        return ''
    end

    local radius = cfg.line_radius or 12
    local min_severity = cfg.min_severity or vim.diagnostic.severity.HINT
    local max_chars = cfg.max_chars or 2048

    local lo = math.max(0, cursor_row_1 - 1 - radius)
    local hi = cursor_row_1 - 1 + radius

    local diags = vim.diagnostic.get(bufnr, {
        severity = { min = min_severity },
    })

    local filtered = {}
    for _, d in ipairs(diags) do
        local lnum = d.lnum or 0
        if lnum >= lo and lnum <= hi then
            table.insert(filtered, d)
        end
    end

    table.sort(filtered, function(a, b)
        local sa = a.severity or 99
        local sb = b.severity or 99
        if sa ~= sb then
            return sa < sb
        end
        local la = a.lnum or 0
        local lb = b.lnum or 0
        if la ~= lb then
            return la < lb
        end
        return (a.col or 0) < (b.col or 0)
    end)

    local path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr) or '', ':.')
    if path == '' then
        path = '[No Name]'
    end

    local lines = {}
    for _, d in ipairs(filtered) do
        local lnum1 = (d.lnum or 0) + 1
        local col1 = (d.col or 0) + 1
        local msg = d.message or ''
        msg = msg:gsub('[\r\n]+', ' '):gsub('%s+', ' ')
        msg = vim.fn.strcharpart(msg, 0, DIAG_MESSAGE_CHARS)
        local line = string.format('%s:%d:%d [%s] %s', path, lnum1, col1, diagnostic_severity_name(d.severity), msg)
        local candidate = #lines == 0 and line or (table.concat(lines, '\n') .. '\n' .. line)
        if vim.fn.strchars(candidate) <= max_chars then
            table.insert(lines, line)
        elseif #lines == 0 then
            table.insert(lines, vim.fn.strcharpart(line, 0, math.max(32, max_chars - 24)) .. ' …')
        end
        if vim.fn.strchars(candidate) > max_chars then
            break
        end
    end

    local out = table.concat(lines, '\n')
    if out ~= '' and #lines < #filtered then
        out = out .. '\n... (truncated)'
    end
    return out
end

---@param context { lines_before: string, lines_after: string, opts: table }
---@param cmp_context { bufnr: number?, cursor: { row: number, line: number }? }|nil
function M.apply_diagnostics_context(context, cmp_context)
    local config = require('phantom-code').config
    cmp_context = cmp_context or {}

    local bufnr = cmp_context.bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
        context.opts.diagnostics_context = ''
        return
    end

    local line_0
    if cmp_context.cursor then
        line_0 = cmp_context.cursor.line
        if line_0 == nil and cmp_context.cursor.row then
            line_0 = cmp_context.cursor.row - 1
        end
    end
    if line_0 == nil then
        line_0 = vim.api.nvim_win_get_cursor(0)[1] - 1
    end
    local cursor_row_1 = line_0 + 1

    context.opts.diagnostics_context =
        M.build_diagnostics_context(bufnr, cursor_row_1, config.diagnostics or {})
end

--- Add diagnostics and user `context_enrich` to LLM context.
---@param context { lines_before: string, lines_after: string, opts: table }
---@param cmp_context table|nil
---@return table
function M.enrich_llm_context(context, cmp_context)
    context.opts = context.opts or {}
    context.opts.diagnostics_context = ''

    M.apply_diagnostics_context(context, cmp_context or {})

    local config = require('phantom-code').config
    local inline = config.inline or {}
    if type(inline.context_enrich) == 'function' then
        local out = inline.context_enrich(context, cmp_context or {})
        if out ~= nil then
            return out
        end
    end

    return context
end

---remove the sequence and the rest part from text.
---@param text string?
---@param context { lines_before: string?, lines_after: string? }
---@return string?
function M.filter_text(text, context)
    local config = require('phantom-code').config
    local inline = config.inline or {}

    -- Handle nil values
    if not text or not context then
        return text
    end

    local lines_before = context.lines_before
    local lines_after = context.lines_after

    -- Handle nil context values
    if not lines_before and not lines_after then
        return text
    end

    text = M.remove_spaces_single(text, true)
    lines_before = M.remove_spaces_single(lines_before or '')
    lines_after = M.remove_spaces_single(lines_after or '')

    if not text then
        return
    end

    local filtered_text = text

    -- Filter based on context before cursor (trim from the beginning of completion)
    if lines_before and inline.before_cursor_filter_length > 0 then
        local match_before = M.find_longest_match(filtered_text, lines_before)
        local match_len = vim.fn.strchars(match_before)
        if match_before and match_len >= inline.before_cursor_filter_length then
            -- Remove the matching part from the beginning of the completion
            filtered_text = vim.fn.strcharpart(filtered_text, match_len)
        end
    end

    -- Filter based on context after cursor (trim from the end of completion)
    if lines_after and inline.after_cursor_filter_length > 0 then
        local match_after = M.find_longest_match(lines_after, filtered_text)
        local match_len = vim.fn.strchars(match_after)
        if match_after and match_len >= inline.after_cursor_filter_length then
            -- Remove the matching part from the end of the completion
            local text_len = vim.fn.strchars(filtered_text)
            filtered_text = vim.fn.strcharpart(filtered_text, 0, text_len - match_len)
        elseif match_after ~= '' and match_after:gsub('%s', '') == '}' then
            -- Duplicate closing brace / whitespace-only gap before `}`: overlap is too short for after_cursor_filter_length
            local text_len = vim.fn.strchars(filtered_text)
            filtered_text = vim.fn.strcharpart(filtered_text, 0, text_len - match_len)
        end
    end

    return filtered_text
end

--- Remove the trailing and leading spaces for a single string item
---@param item string
---@param keep_leading_newline? boolean
---@return string?
function M.remove_spaces_single(item, keep_leading_newline)
    if not item:find '%S' then -- skip entries that contain only whitespace
        return nil
    end

    local start_pattern = keep_leading_newline and '^[ \t]+' or '^%s+'

    -- replace the trailing spaces
    item = item:gsub('%s+$', '')
    -- replace the leading spaces
    item = item:gsub(start_pattern, '')

    return item
end

--- Remove the trailing and leading spaces for each string in the table
---@param items string[]
---@param keep_leading_newline? boolean
---@return string[]
function M.remove_spaces(items, keep_leading_newline)
    local new = {}

    for _, item in ipairs(items) do
        local item_processed = M.remove_spaces_single(item, keep_leading_newline)
        if item_processed then
            table.insert(new, item_processed)
        end
    end

    return new
end

-- Find the longest string that is a prefix of A and a suffix of B. The
-- function iterates from the longest possible match length downwards for
-- efficiency.  If A or B are not strings, it returns an empty string.
---@param a string?
---@param b string?
function M.find_longest_match(a, b)
    -- Ensure both inputs are strings to avoid errors.
    if type(a) ~= 'string' or type(b) ~= 'string' then
        return ''
    end

    -- The longest possible match is limited by the shorter of the two strings.
    local max_len = math.min(#a, #b)

    -- Iterate downwards from the maximum possible length to 1.
    -- This is more efficient because the first match we find will be the longest one.
    for len = max_len, 1, -1 do
        -- Extract the prefix from string 'a'.
        local prefix_a = string.sub(a, 1, len)

        -- Extract the suffix from string 'b'.
        -- Negative indices in string.sub count from the end of the string.
        local suffix_b = string.sub(b, -len)

        -- If the prefix of 'a' matches the suffix of 'b', we've found our longest match.
        if prefix_a == suffix_b then
            return prefix_a
        end
    end

    -- If the loop completes without finding any match, return an empty string.
    return ''
end

--- If the last word of b is not a substring of the first word of a,
--- And it there are no trailing spaces for b and no leading spaces for a,
--- prepend the last word of b to a.
---@param a string?
---@param b string?
---@return string?
function M.prepend_to_complete_word(a, b)
    if not a or not b then
        return a
    end

    local last_word_b = b:match '[%w_-]+$'
    local first_word_a = a:match '^[%w_-]+'

    if last_word_b and first_word_a and not first_word_a:find(last_word_b, 1, true) then
        a = last_word_b .. a
    end

    return a
end

---Adjust indentation of lines based on direction
---@param lines string The string containing the lines to adjust
---@param ref_line string The reference line used to adjust identation
---@param direction "+" | "-" "+" for adding, "-" for removing
---@return string Lines Adjusted lines
function M.adjust_indentation(lines, ref_line, direction)
    local indentation = string.match(ref_line or '', '^%s*') or ''

    ---@diagnostic disable-next-line:cast-local-type
    lines = vim.split(lines, '\n')
    local new_lines = {}

    for _, line in ipairs(lines) do
        if direction == '+' then
            table.insert(new_lines, indentation .. line)
        elseif direction == '-' then
            -- Remove indentation if it exists at the start of the line
            if line:sub(1, #ref_line) == indentation then
                line = line:sub(#ref_line + 1)
            end
            table.insert(new_lines, line)
        end
    end

    return table.concat(new_lines, '\n')
end

---@param context table
---@param template table
---@return string[]
function M.make_chat_llm_shot(context, template)
    local inputs = template.template
    if type(inputs) == 'string' then
        inputs = { inputs }
    end
    local context_before_cursor = context.lines_before
    local context_after_cursor = context.lines_after
    local opts = context.opts

    -- Store the template value before clearing it
    template.template = nil
    local results = {}

    for _, input in ipairs(inputs) do
        local parts = {}
        local last_pos = 1
        while true do
            local start_pos, end_pos = input:find('{{{.-}}}', last_pos)
            if not start_pos then
                -- Add the remaining part of the string
                table.insert(parts, input:sub(last_pos))
                break
            end

            -- Add the text before the placeholder
            table.insert(parts, input:sub(last_pos, start_pos - 1))

            -- Extract placeholder key
            local key = input:sub(start_pos + 3, end_pos - 3)

            -- Get the replacement value if it exists
            if template[key] then
                local value = template[key](context_before_cursor, context_after_cursor, opts)
                table.insert(parts, value)
            end

            last_pos = end_pos + 1
        end

        local result = table.concat(parts)
        table.insert(results, result)
    end

    return results
end

function M.no_stream_decode(response, exit_code, data_file, provider, get_text_fn)
    os.remove(data_file)

    if exit_code ~= 0 then
        if exit_code == 28 then
            M.notify('Request timed out.', 'warn', vim.log.levels.WARN)
        else
            M.notify(string.format('Request failed with exit code %d', exit_code), 'error', vim.log.levels.ERROR)
        end
        return
    end

    local result = table.concat(response:result(), '\n')
    local success, json = pcall(vim.json.decode, result)
    if not success then
        if result ~= '' then
            M.notify(
                'Failed to parse ' .. provider .. ' API response as json: ' .. truncate_for_notify(result),
                'error',
                vim.log.levels.INFO
            )
        end
        return
    end

    local result_str

    success, result_str = pcall(get_text_fn, json)

    if not success or not result_str or result_str == '' then
        if result:find 'error' then
            M.notify(provider .. ' returns error: ' .. truncate_for_notify(result), 'error', vim.log.levels.INFO)
        else
            M.notify(provider .. ' returns no text: ' .. truncate_for_notify(json), 'verbose', vim.log.levels.INFO)
        end
        return
    end

    return result_str
end

function M.stream_decode(response, exit_code, data_file, provider, get_text_fn)
    os.remove(data_file)

    if not (exit_code == 28 or exit_code == 0) then
        M.notify(string.format('Request failed with exit code %d', exit_code), 'error', vim.log.levels.ERROR)
        return
    end

    local result = {}
    local responses = response:result()

    for _, line in ipairs(responses) do
        local success, json, text

        line = line:gsub('^data:', '')
        success, json = pcall(vim.json.decode, line)
        if not success then
            goto continue
        end

        success, text = pcall(get_text_fn, json)
        if not success then
            goto continue
        end

        if type(text) == 'string' and text ~= '' then
            table.insert(result, text)
        end
        ::continue::
    end

    local result_str = #result > 0 and table.concat(result) or nil

    if not result_str then
        local notified_on_error = false
        for _, line in ipairs(responses) do
            if line:find 'error' then
                local sample = {}
                for i = 1, math.min(3, #responses) do
                    sample[i] = truncate_for_notify(responses[i], 200)
                end
                M.notify(
                    string.format(
                        '%s streaming error (%d chunk(s)); sample: %s',
                        provider,
                        #responses,
                        table.concat(sample, ' | ')
                    ),
                    'error',
                    vim.log.levels.INFO
                )

                notified_on_error = true

                break
            end
        end

        if not notified_on_error then
            local sample = {}
            for i = 1, math.min(3, #responses) do
                sample[i] = truncate_for_notify(responses[i], 200)
            end
            M.notify(
                string.format(
                    '%s returned no text on streaming (%d chunk(s)); sample: %s',
                    provider,
                    #responses,
                    table.concat(sample, ' | ')
                ),
                'verbose',
                vim.log.levels.INFO
            )
        end
        return
    end

    return result_str
end

M.add_single_line_entry = function(list)
    if M.INLINE_N_COMPLETIONS <= 1 then
        return list
    end
    local newlist = {}

    for _, item in ipairs(list) do
        if type(item) == 'string' then
            -- single line completion item should be preferred.
            table.insert(newlist, item)
            table.insert(newlist, 1, vim.split(item, '\n')[1])
        end
    end

    return newlist
end

--- dedup the items in a list
M.list_dedup = function(list)
    local hash = {}
    local items_cleaned = {}
    for _, item in ipairs(list) do
        if type(item) == 'string' and not hash[item] then
            hash[item] = true
            table.insert(items_cleaned, item)
        end
    end
    return items_cleaned
end

---@class phantom-code.EventData
---@field provider string the name of the provider
---@field name string the name of the subprovider for openai-compatible and openai-fim-compatible
---@field model string the model name used during this event
---@field n_requests number the number of requests launched during this event
---@field request_idx? number the index of the current request
---@field timestamp number the timestamp of the event at PhantomCodeRequestStartedPre

---@param event string The phantom-code event to run
---@param opts phantom-code.EventData The phantom-code data event
function M.run_event(event, opts)
    opts = opts or {}
    vim.api.nvim_exec_autocmds('User', { pattern = event, data = opts })
end

---@param end_point string
---@param headers table<string, string>
---@param data_file string
---@return string[]
---@param max_time? number Override `config.request_timeout` (seconds).
function M.make_curl_args(end_point, headers, data_file, max_time)
    local config = require('phantom-code').config

    local args = { '-L' }
    for _, arg in ipairs(config.curl_extra_args) do
        table.insert(args, arg)
    end

    for k, v in pairs(headers) do
        table.insert(args, '-H')
        table.insert(args, k .. ': ' .. v)
    end
    table.insert(args, '--max-time')
    table.insert(args, tostring(max_time or config.request_timeout))
    table.insert(args, '-d')
    table.insert(args, '@' .. data_file)

    if config.proxy then
        table.insert(args, '--proxy')
        table.insert(args, config.proxy)
    end

    table.insert(args, end_point)

    return args
end

--- Runs a list of functions one by one.
--- Stops and returns false immediately if a function returns false.
--- @param hooks function[] A list of functions to run.
--- @param ... any Arguments to pass to each function.
--- @return boolean Returns false if any hook fails, true otherwise.
function M.run_hooks_until_failure(hooks, ...)
    if #hooks == 0 then
        return true
    end
    for _, func in ipairs(hooks) do
        local result = func(...)

        if not result then
            return false
        end
    end

    return true
end

--- If selection ends with `{` … whitespace … `}`, return text before that `{`.
---@param sel string
---@return string?
local function trailing_empty_brace_prefix(sel)
    if type(sel) ~= 'string' or sel == '' then
        return nil
    end
    local last_open
    for i = #sel, 1, -1 do
        if sel:sub(i, i) == '{' then
            last_open = i
            break
        end
    end
    if not last_open then
        return nil
    end
    local tail = sel:sub(last_open)
    if not tail:match('^%{%s*%}%s*$') then
        return nil
    end
    return sel:sub(1, last_open - 1)
end

--- When the model echoes the selection then continues, keep only the continuation.
---@param selected string
---@param response string
---@return string
local function strip_expand_echo_prefix(selected, response)
    if selected == '' or response == '' then
        return response
    end
    if response:sub(1, #selected) == selected then
        return (response:sub(#selected + 1):gsub('^%s+', ''))
    end
    return response
end

--- Drop a duplicated closing `}` when the model adds an extra brace before real suffix.
---@param selected string
---@param response string
---@return string
local function strip_expand_extra_closing_brace(selected, response)
    if not selected:match('%}%s*$') then
        return response
    end
    local t = vim.trim(response)
    if t:match('%}%s*%}$') then
        return (response:gsub('(%})%s*%}$', '%1'))
    end
    return response
end

--- Indent each line of body; uses buffer shiftwidth when bufnr/row are valid.
---@param body string
---@param inner_indent string
---@return string
local function indent_body_lines(body, inner_indent)
    local lines = vim.split(body, '\n', { plain = true })
    local out = {}
    for _, L in ipairs(lines) do
        if L == '' then
            table.insert(out, '')
        else
            table.insert(out, inner_indent .. vim.trim(L))
        end
    end
    return table.concat(out, '\n')
end

--- Merge model output with the original selection: empty `{}` → splice body; trim echoes / extra `}`.
---@param selected string
---@param response string
---@param opts? { bufnr?: integer, start_row?: integer }
---@return string
function M.merge_expand_replacement(selected, response, opts)
    if type(response) ~= 'string' or response == '' then
        return response
    end
    opts = opts or {}
    local r = strip_expand_echo_prefix(selected, response)
    r = strip_expand_extra_closing_brace(selected, r)

    local prefix = trailing_empty_brace_prefix(selected)
    if not prefix then
        return r
    end

    local trim_r = vim.trim(r)
    local trim_prefix = vim.trim(prefix)
    if trim_r == '' then
        return r
    end

    if trim_prefix ~= '' and trim_r:sub(1, #trim_prefix) == trim_prefix then
        return r
    end

    if trim_r:match('^%b{}$') or (trim_r:sub(1, 1) == '{' and trim_r:match('%}%s*$')) then
        local open = trim_r:sub(1, 1) == '{' and trim_r or ('{' .. trim_r:sub(2))
        return (prefix:gsub('%s+$', '')) .. ' ' .. open
    end

    -- Likely a full replacement (another decl, return with braced init, nested blocks).
    if trim_r:find('{', 1, true) and trim_r:sub(1, 1) ~= '{' then
        return r
    end

    local bufnr, row0 = opts.bufnr, opts.start_row
    local leader = ''
    local sw = 4
    if bufnr and row0 ~= nil and vim.api.nvim_buf_is_valid(bufnr) then
        local first_line = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1] or ''
        leader = first_line:match('^(%s*)') or ''
        sw = vim.bo[bufnr].shiftwidth
        if sw == 0 then
            sw = vim.bo[bufnr].tabstop
        end
    end
    local inner_indent = leader .. string.rep(' ', sw)
    local body = indent_body_lines(trim_r, inner_indent)
    return (prefix:gsub('%s+$', '')) .. ' {\n' .. body .. '\n' .. leader .. '}'
end

--- Re-apply prefix/suffix overlap trimming at accept time (cursor-aware) and drop a duplicate `{` after `{`.
---@param before_part string  text from start of line to cursor (0-based col)
---@param after_part string  text from cursor to end of line
---@param suggestion string
---@param opts? { bufnr?: integer, row0?: integer, col0_byte?: integer }
---@return string
function M.normalize_inline_accept_suggestion(before_part, after_part, suggestion, opts)
    if type(suggestion) ~= 'string' or suggestion == '' then
        return suggestion
    end
    opts = opts or {}
    local config = require('phantom-code').config
    local inline = config.inline or {}
    local before_len = inline.before_cursor_filter_length or 0
    local after_len = inline.after_cursor_filter_length or 0

    local sug = M.remove_spaces_single(suggestion, true) or suggestion
    local before = M.remove_spaces_single(before_part or '', false) or ''
    local after = M.remove_spaces_single(after_part or '', false) or ''

    if before ~= '' and before_len > 0 then
        local match_before = M.find_longest_match(sug, before)
        local n = vim.fn.strchars(match_before)
        if match_before and n >= before_len then
            sug = vim.fn.strcharpart(sug, n)
        end
    end

    if after ~= '' and after_len > 0 then
        local match_after = M.find_longest_match(after, sug)
        local n = vim.fn.strchars(match_after)
        if match_after and n >= after_len then
            local text_len = vim.fn.strchars(sug)
            sug = vim.fn.strcharpart(sug, 0, text_len - n)
        elseif match_after ~= '' and match_after:gsub('%s', '') == '}' then
            local text_len = vim.fn.strchars(sug)
            sug = vim.fn.strcharpart(sug, 0, text_len - n)
        end
    end

    if before:match('%{%s*$') and sug:match('^%s*%{') then
        sug = sug:gsub('^%s*%{', '', 1)
    end

    local after_for_brace = after
    if opts.bufnr and opts.row0 ~= nil and opts.col0_byte ~= nil and vim.api.nvim_buf_is_valid(opts.bufnr) then
        local ml = M.text_after_cursor_multiline(opts.bufnr, opts.row0, opts.col0_byte, 32, 1024)
        if ml ~= '' then
            after_for_brace = ml
        end
    end

    if after_for_brace:match('^%s*%}') and sug:find('%}%s*$') then
        local ts = vim.trim(sug)
        if ts:sub(-1) == '}' then
            sug = sug:gsub('%s*%}%s*$', '', 1)
        end
    end

    return sug
end

--- Strip a single leading/trailing markdown code fence if present.
---@param text string?
---@return string?
function M.strip_optional_code_fences(text)
    if type(text) ~= 'string' then
        return text
    end
    local s = vim.trim(text)
    s = s:gsub('^```%w*%s*\n', '')
    s = s:gsub('\n%s*```%s*$', '')
    return vim.trim(s)
end

---@param feature 'inline'|'expand'
---@return { provider: string, options: table }
function M.resolve_provider_config(feature)
    local config = require('phantom-code').config
    local block = feature == 'expand' and (config.expand or {}) or (config.inline or {})
    local provider = block.provider or config.provider
    local base_opts = vim.deepcopy(config.provider_options[provider] or {})
    local per_feature = block.provider_options and block.provider_options[provider] or {}
    local merged = vim.tbl_deep_extend('force', base_opts, per_feature)
    if feature == 'inline' then
        local po = config.inline and config.inline.prompt_overrides and config.inline.prompt_overrides[provider] or {}
        merged = vim.tbl_deep_extend('force', merged, po)
    end
    return { provider = provider, options = merged }
end

---@param provider string
---@return boolean
function M.provider_supports_expand_chat(provider)
    return provider ~= 'codestral' and provider ~= 'openai_fim_compatible'
end

--- Text before (sr,sc) in buffer lines (0-based row/col; `lines` is nvim_buf_get_lines, 1-indexed).
local function expand_text_before(lines, sr, sc)
    local parts = {}
    for r = 0, sr - 1 do
        table.insert(parts, lines[r + 1] or '')
    end
    local line = lines[sr + 1]
    if line then
        table.insert(parts, vim.fn.strcharpart(line, 0, sc))
    end
    return table.concat(parts, '\n')
end

---@param lines string[]
---@param er integer 0-based end row of selection
---@param ec integer 0-based exclusive end column
local function expand_text_after(lines, er, ec)
    local parts = {}
    local row_line = lines[er + 1]
    if row_line then
        table.insert(parts, vim.fn.strcharpart(row_line, ec))
    end
    for i = er + 2, #lines do
        table.insert(parts, lines[i])
    end
    return table.concat(parts, '\n')
end

--- Surrounding file text for Expand (selection excluded), with `context_window`-style truncation.
---@param bufnr integer
---@param sr integer 0-based start row
---@param sc integer 0-based start column
---@param er integer 0-based end row
---@param ec integer 0-based exclusive end column
---@param context_window integer
---@param context_ratio number
---@return { lines_before: string, lines_after: string, opts: table }
function M.get_expand_file_surround(bufnr, sr, sc, er, ec, context_window, context_ratio)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local lines_before = expand_text_before(lines, sr, sc)
    local lines_after = expand_text_after(lines, er, ec)

    local n_chars_before = vim.fn.strchars(lines_before)
    local n_chars_after = vim.fn.strchars(lines_after)

    local opts = {
        is_incomplete_before = false,
        is_incomplete_after = false,
    }

    if n_chars_before + n_chars_after > context_window then
        if n_chars_before < context_window * context_ratio then
            lines_after = vim.fn.strcharpart(lines_after, 0, context_window - n_chars_before)
            opts.is_incomplete_after = true
        elseif n_chars_after < context_window * (1 - context_ratio) then
            lines_before =
                vim.fn.strcharpart(lines_before, n_chars_before + n_chars_after - context_window)
            opts.is_incomplete_before = true
        else
            lines_after =
                vim.fn.strcharpart(lines_after, 0, math.floor(context_window * (1 - context_ratio)))
            lines_before = vim.fn.strcharpart(
                lines_before,
                n_chars_before - math.floor(context_window * context_ratio)
            )
            opts.is_incomplete_before = true
            opts.is_incomplete_after = true
        end
    end

    return {
        lines_before = lines_before,
        lines_after = lines_after,
        opts = opts,
    }
end

return M
