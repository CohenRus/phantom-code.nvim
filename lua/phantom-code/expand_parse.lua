--- Parse structured `<phantom_expand>` responses and apply `<edit>` hunks within the selection.

local M = {}

---@class phantom-code.ExpandEdit
---@field startLine integer 1-based inclusive, first line of selection = 1
---@field endLine integer 1-based inclusive
---@field content string replacement body (may be multiple lines)

---@param lines string[]
---@param s integer 1-based start line in selection coordinates
---@param en integer 1-based end line inclusive
---@param new_l string[]
---@return string[]
local function splice_lines(lines, s, en, new_l)
    local out = {}
    for i = 1, s - 1 do
        out[#out + 1] = lines[i]
    end
    for _, nl in ipairs(new_l) do
        out[#out + 1] = nl
    end
    for i = en + 1, #lines do
        out[#out + 1] = lines[i]
    end
    return out
end

---@param selected string
---@param edits phantom-code.ExpandEdit[]
---@return string|nil
function M.apply_edits(selected, edits)
    local lines = vim.split(selected, '\n', { plain = true })
    table.sort(edits, function(a, b)
        return a.startLine > b.startLine
    end)
    for _, e in ipairs(edits) do
        local s, en = e.startLine, e.endLine
        if not s or not en or s < 1 or en < s or s > #lines or en > #lines then
            return nil
        end
        local new_l = vim.split(e.content, '\n', { plain = true })
        lines = splice_lines(lines, s, en, new_l)
    end
    return table.concat(lines, '\n')
end

---@param s string
---@return string
local function strip_outer_fence(s)
    local t = vim.trim(s or '')
    -- Lua patterns: use %s for whitespace (not \s).
    t = t:gsub('^```%w*%s*\n', '')
    t = t:gsub('\n%s*```%s*$', '')
    return vim.trim(t)
end

---@param inner string
---@return phantom-code.ExpandEdit[]
local function parse_edits(inner)
    local edits = {}
    local i = 1
    while true do
        local open_start = inner:find('<edit%s+', i, false)
        if not open_start then
            break
        end
        local gt = inner:find('>', open_start + 5, true)
        if not gt then
            break
        end
        local attrs = inner:sub(open_start + 5, gt - 1)
        local close_start = inner:find('</edit>', gt + 1, true)
        if not close_start then
            break
        end
        local body = vim.trim(inner:sub(gt + 1, close_start - 1))
        local sl = tonumber(attrs:match('startLine%s*=%s*["\']?(%d+)'))
        local el = tonumber(attrs:match('endLine%s*=%s*["\']?(%d+)'))
        if sl and el then
            edits[#edits + 1] = {
                startLine = sl,
                endLine = el,
                content = body,
            }
        end
        i = close_start + 7
    end
    return edits
end

---@param inner string
---@return string|nil
local function parse_replacement(inner)
    local s, e = inner:find('<replacement>', 1, true)
    if not s then
        return nil
    end
    local close = inner:find('</replacement>', e + 1, true)
    if not close then
        return nil
    end
    return vim.trim(inner:sub(e + 1, close - 1))
end

---@param raw string
---@param selected string
---@return string proposed full text replacing selection
---@return 'replacement'|'edits'|'fallback' kind
function M.parse_response(raw, selected)
    local text = strip_outer_fence(raw)
    local inner
    do
        local s1, e1 = text:find('<phantom_expand%s*>', 1, false)
        if not s1 then
            s1, e1 = text:find('<phantom_expand>', 1, true)
        end
        if s1 then
            local close = text:find('</phantom_expand>', e1 + 1, true)
            if close then
                inner = text:sub(e1 + 1, close - 1)
            end
        end
    end

    if inner then
        inner = vim.trim(inner)
        local edits = parse_edits(inner)
        if #edits > 0 then
            local merged = M.apply_edits(selected, edits)
            if merged then
                return merged, 'edits'
            end
        end
        local repl = parse_replacement(inner)
        if repl then
            return repl, 'replacement'
        end
        -- Root present but unusable: strip tags and use inner as code
        local stripped = inner
            :gsub('<%/?[^>]+>', '')
        stripped = vim.trim(stripped)
        if stripped ~= '' then
            return stripped, 'fallback'
        end
    end

    return text, 'fallback'
end

return M
