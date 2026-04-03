--- Inline diff decorations on the source buffer (selection range), avante-inspired.

local api = vim.api

local M = {}

M.ns = api.nvim_create_namespace 'phantom-code.expand_inline_diff'

local function ensure_hl()
    local names = {
        PhantomCodeExpandDiffAdd = 'DiffAdd',
        PhantomCodeExpandDiffDelete = 'DiffDelete',
        PhantomCodeExpandDiffChange = 'DiffText',
    }
    for name, link in pairs(names) do
        if vim.tbl_isempty(api.nvim_get_hl(0, { name = name })) then
            api.nvim_set_hl(0, name, { default = true, link = link })
        end
    end
end

--- Clear all inline diff extmarks in the namespace for bufnr.
---@param bufnr integer
function M.clear(bufnr)
    if bufnr and api.nvim_buf_is_valid(bufnr) then
        api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
    end
end

---@param old_text string
---@param new_text string
---@return { [1]: integer, [2]: integer, [3]: integer, [4]: integer }[]
local function diff_hunks(old_text, new_text)
    local old_lines = vim.split(old_text, '\n', { plain = true })
    local new_lines = vim.split(new_text, '\n', { plain = true })
    if #old_lines == 0 and #new_lines == 0 then
        return {}
    end
    local a = table.concat(old_lines, '\n')
    local b = table.concat(new_lines, '\n')
    local ok, hunks = pcall(vim.diff, a, b, { result_type = 'indices', algorithm = 'histogram' })
    if not ok or type(hunks) ~= 'table' then
        return {}
    end
    return hunks
end

--- Draw diff between selection text and proposed replacement on buffer rows sr..er.
---@param bufnr integer
---@param sr integer 0-based start row of selection
---@param er integer 0-based end row inclusive
---@param old_text string exact selected text
---@param new_text string proposed replacement
---@return integer[] extmark ids
function M.render(bufnr, sr, er, old_text, new_text)
    ensure_hl()
    M.clear(bufnr)
    if not api.nvim_buf_is_valid(bufnr) then
        return {}
    end
    if old_text == new_text then
        return {}
    end

    local old_lines_split = vim.split(old_text, '\n', { plain = true })
    local old_line_count = #old_lines_split
    local new_lines = vim.split(new_text, '\n', { plain = true })
    local hunks = diff_hunks(old_text, new_text)
    local ids = {}

    local function add_extmark(row0, o)
        local id = api.nvim_buf_set_extmark(bufnr, M.ns, row0, 0, o)
        if id and id > 0 then
            ids[#ids + 1] = id
        end
    end

    for _, h in ipairs(hunks) do
        local as, ac, bs, bc = h[1], h[2], h[3], h[4]
        if as == nil or ac == nil or bs == nil or bc == nil then
            goto hunk_done
        end

        -- Pure insertion (ac==0): vim.diff indices are 1-based. Old line `as` is at buffer row sr+as-1.
        -- Insert *before* that line → virt_lines_above on sr+as-1. Append after last old line (as > old_line_count)
        -- → virt_lines below row er (last row of selection).
        if ac == 0 and bc > 0 then
            local virt = {}
            for i = bs, bs + bc - 1 do
                local line = new_lines[i]
                if line ~= nil then
                    virt[#virt + 1] = { { '+ ' .. line, 'PhantomCodeExpandDiffAdd' } }
                end
            end
            if #virt > 0 then
                local last_buf_row = api.nvim_buf_line_count(bufnr) - 1
                local anchor
                local opts = { virt_lines = virt, priority = 199 }
                if as > old_line_count then
                    anchor = math.min(er, last_buf_row)
                    anchor = math.max(sr, anchor)
                else
                    anchor = sr + as - 1
                    if anchor < 0 then
                        anchor = 0
                    end
                    anchor = math.min(anchor, last_buf_row)
                    opts.virt_lines_above = true
                end
                add_extmark(anchor, opts)
            end
            goto hunk_done
        end

        if ac > 0 and as >= 1 then
            local del_hl = 'PhantomCodeExpandDiffDelete'
            local chg_hl = 'PhantomCodeExpandDiffChange'
            for k = 0, ac - 1 do
                local buf_row = sr + as - 1 + k
                if buf_row >= sr and buf_row <= er then
                    local hl = (bc == 0) and del_hl or chg_hl
                    add_extmark(buf_row, {
                        line_hl_group = hl,
                        priority = 200,
                    })
                end
            end
        end

        if ac > 0 and bc > ac then
            local virt = {}
            for i = bs + ac, bs + bc - 1 do
                local line = new_lines[i]
                if line ~= nil then
                    virt[#virt + 1] = { { '+ ' .. line, 'PhantomCodeExpandDiffAdd' } }
                end
            end
            if #virt > 0 then
                local after_row = sr + as + ac - 2
                after_row = math.max(sr, math.min(after_row, er))
                add_extmark(after_row, {
                    virt_lines = virt,
                    priority = 199,
                })
            end
        end

        ::hunk_done::
    end

    return ids
end

--- Count virtual lines from extmarks with `virt_lines_above` in the selection row range (0-based inclusive).
--- Used to nudge anchored floats that sit below the selection so they clear inline-diff preview lines.
---@param bufnr integer
---@param sr integer
---@param er integer
---@return integer
function M.count_virt_lines_above_in_range(bufnr, sr, er)
    if not api.nvim_buf_is_valid(bufnr) then
        return 0
    end
    local marks = api.nvim_buf_get_extmarks(bufnr, M.ns, 0, -1, { details = true })
    local n = 0
    for _, m in ipairs(marks) do
        local row = m[2]
        local details = m[4]
        if
            row >= sr
            and row <= er
            and type(details) == 'table'
            and details.virt_lines_above
            and details.virt_lines
        then
            n = n + #details.virt_lines
        end
    end
    return n
end

return M
