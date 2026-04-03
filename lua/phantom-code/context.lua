local M = {}
local api = vim.api

local COMMON_KW = {
    ['and'] = true,
    ['break'] = true,
    ['do'] = true,
    ['else'] = true,
    ['elseif'] = true,
    ['end'] = true,
    ['false'] = true,
    ['for'] = true,
    ['function'] = true,
    ['goto'] = true,
    ['if'] = true,
    ['in'] = true,
    ['local'] = true,
    ['nil'] = true,
    ['not'] = true,
    ['or'] = true,
    ['repeat'] = true,
    ['return'] = true,
    ['then'] = true,
    ['true'] = true,
    ['until'] = true,
    ['while'] = true,
    ['const'] = true,
    ['let'] = true,
    ['var'] = true,
    ['class'] = true,
    ['extends'] = true,
    ['import'] = true,
    ['export'] = true,
    ['from'] = true,
    ['default'] = true,
    ['async'] = true,
    ['await'] = true,
    ['new'] = true,
    ['this'] = true,
    ['typeof'] = true,
    ['void'] = true,
    ['public'] = true,
    ['private'] = true,
    ['interface'] = true,
    ['type'] = true,
    ['namespace'] = true,
    ['using'] = true,
    ['static'] = true,
}

local import_rows_cache = {}

---@param line string
---@param base_dir string
---@param out table[] { path: string, names: string[] }
---@param max_imports integer
local function push_js_import_line(line, base_dir, out, max_imports)
    if #out >= max_imports then
        return
    end
    local names = {}
    local path_part
    local brace, p = line:match 'import%s+%{([^}]+)}%s+from%s+["\']([^"\']+)["\']'
    if brace and p then
        path_part = p
        for part in brace:gmatch '[^,]+' do
            local alias = part:match '([%w_]+)%s+as%s+[%w_]+' or part:match '^%s*([%w_]+)%s*$'
            if alias then
                names[#names + 1] = alias
            end
        end
    else
        local default_name, p2 = line:match 'import%s+([%w_]+)%s+from%s+["\']([^"\']+)["\']'
        if default_name and p2 then
            names[1] = default_name
            path_part = p2
        end
    end
    if not path_part or path_part:sub(1, 1) ~= '.' then
        return
    end
    local resolved = M.resolve_relative_file(base_dir, path_part)
    if resolved then
        out[#out + 1] = { path = resolved, names = names }
    end
end

---@param line string
---@param base_dir string
---@param out table[]
---@param max_imports integer
local function push_lua_require_line(line, base_dir, out, max_imports)
    for q in line:gmatch 'require%s*%(%s*["\']([^"\']+)["\']%s*%)' do
        if #out >= max_imports then
            return
        end
        local resolved = M.resolve_lua_require(base_dir, q)
        if resolved then
            out[#out + 1] = { path = resolved, names = {} }
        end
    end
end

---@param base_dir string directory of current buffer
---@param rel string e.g. ./foo or ../bar
---@return string|nil absolute path
function M.resolve_relative_file(base_dir, rel)
    rel = rel:gsub('^%./', '')
    local combined = vim.fn.fnamemodify(base_dir .. '/' .. rel, ':p')
    if vim.fn.filereadable(combined) == 1 then
        return combined
    end
    local no_ext = rel:gsub('%.[^./]+$', '')
    for _, ext in ipairs({ '.ts', '.tsx', '.js', '.mjs', '.cjs', '.jsx', '.vue', '.svelte', '.lua', '' }) do
        local try = vim.fn.fnamemodify(base_dir .. '/' .. no_ext .. ext, ':p')
        if vim.fn.filereadable(try) == 1 then
            return try
        end
    end
    local as_index = vim.fn.fnamemodify(base_dir .. '/' .. rel .. '/index.ts', ':p')
    if vim.fn.filereadable(as_index) == 1 then
        return as_index
    end
    as_index = vim.fn.fnamemodify(base_dir .. '/' .. rel .. '/index.js', ':p')
    if vim.fn.filereadable(as_index) == 1 then
        return as_index
    end
    return nil
end

---@param base_dir string
---@param mod string lua module path
---@return string|nil
function M.resolve_lua_require(base_dir, mod)
    local rel = mod:gsub('%.', '/')
    for _, suf in ipairs({ '.lua', '/init.lua' }) do
        local try = vim.fn.fnamemodify(base_dir .. '/' .. rel .. suf, ':p')
        if vim.fn.filereadable(try) == 1 then
            return try
        end
    end
    local rtp_paths = vim.opt.runtimepath:get()
    for _, rtp in ipairs(rtp_paths) do
        for _, suf in ipairs({ '.lua', '/init.lua' }) do
            local try = vim.fn.fnamemodify(rtp .. '/lua/' .. rel .. suf, ':p')
            if vim.fn.filereadable(try) == 1 then
                return try
            end
        end
    end
    return nil
end

---@param bufnr integer
---@param ft string
---@param max_lines_scan integer
---@param max_imports integer
---@return { path: string, names: string[] }[]
function M.gather_import_rows(bufnr, ft, max_lines_scan, max_imports)
    if not api.nvim_buf_is_valid(bufnr) then
        return {}
    end
    ft = ft or ''
    max_lines_scan = max_lines_scan or 64
    max_imports = max_imports or 128
    local key = table.concat({ bufnr, ft, max_lines_scan, max_imports }, ':')
    local tick = api.nvim_buf_get_changedtick(bufnr)
    local cached = import_rows_cache[key]
    if cached and cached.tick == tick then
        return cached.rows
    end

    local lines = api.nvim_buf_get_lines(bufnr, 0, max_lines_scan, false)
    local base_dir = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr) or '', ':h')
    if base_dir == '' or base_dir == '.' then
        return {}
    end
    local out = {}
    for _, line in ipairs(lines) do
        if #out >= max_imports then
            break
        end
        if ft == 'lua' then
            push_lua_require_line(line, base_dir, out, max_imports)
        elseif ft == 'javascript' or ft == 'typescript' or ft == 'typescriptreact' or ft == 'javascriptreact' then
            if line:find 'import%s' then
                push_js_import_line(line, base_dir, out, max_imports)
            end
        end
    end
    import_rows_cache[key] = { tick = tick, rows = out }
    return out
end

---@param text string
---@param limit integer
---@return string[]
function M.identifiers_near_cursor(text, limit)
    local out = {}
    local seen = {}
    for w in (text or ''):gmatch('[%a_][%w_]*') do
        if not COMMON_KW[w] and not seen[w] then
            seen[w] = true
            out[#out + 1] = w
            if #out >= limit then
                break
            end
        end
    end
    return out
end

---@param names string[]
---@param id_set table<string, true>
---@return boolean
local function row_matches(names, id_set)
    if not names or #names == 0 then
        return false
    end
    for _, n in ipairs(names) do
        if id_set[n] then
            return true
        end
    end
    return false
end

---@param path string
---@param budget integer
---@return string
local function read_file_head(path, budget)
    local fd = io.open(path, 'r')
    if not fd then
        return ''
    end
    local chunk = fd:read(budget + 1)
    fd:close()
    if not chunk then
        return ''
    end
    if #chunk > budget then
        chunk = chunk:sub(1, budget) .. '\n... (truncated)'
    end
    return chunk
end

--- Append resolved import file snippets to context (prefix of `lines_before`).
---@param context { lines_before: string, lines_after: string, opts: table }
---@param cmp_context { bufnr: integer?, cursor: { line: integer }? }
function M.attach_import_snippets(context, cmp_context)
    local config = require('phantom-code').config
    local icfg = (config.inline or {}).import_context or {}
    if icfg.enable == false then
        return
    end
    local bufnr = cmp_context.bufnr or api.nvim_get_current_buf()
    if not api.nvim_buf_is_valid(bufnr) then
        return
    end
    local ft = api.nvim_buf_get_option(bufnr, 'filetype') or ''
    local max_lines_scan = icfg.max_imports_scanned or 64
    local max_files = icfg.max_files or 3
    local max_chars = icfg.max_chars or 4000

    local rows = M.gather_import_rows(bufnr, ft, max_lines_scan, 128)
    if #rows == 0 then
        return
    end

    local tail = context.lines_before or ''
    if #tail > 1200 then
        tail = tail:sub(#tail - 1199)
    end
    local ids = M.identifiers_near_cursor(tail, 48)
    local id_set = {}
    for _, id in ipairs(ids) do
        id_set[id] = true
    end

    local scored = {}
    for _, row in ipairs(rows) do
        local score = 0
        if row_matches(row.names, id_set) then
            score = 2
        elseif #row.names == 0 then
            score = 0
        else
            score = 1
        end
        scored[#scored + 1] = { row = row, score = score }
    end
    table.sort(scored, function(a, b)
        if a.score ~= b.score then
            return a.score > b.score
        end
        return (a.row.path or '') < (b.row.path or '')
    end)

    local used = {}
    local parts = {}
    local used_chars = 0
    for _, s in ipairs(scored) do
        if #parts >= max_files then
            break
        end
        local path = s.row.path
        if path and not used[path] then
            used[path] = true
            local room = max_chars - used_chars - 120
            if room < 200 then
                break
            end
            local body = read_file_head(path, room)
            if body ~= '' then
                local rel = vim.fn.fnamemodify(path, ':.')
                local block = string.format('<importedFile path="%s">\n%s\n</importedFile>\n', rel, body)
                parts[#parts + 1] = block
                used_chars = used_chars + #block
            end
        end
    end

    if #parts == 0 then
        return
    end
    context.lines_before = table.concat(parts, '\n') .. (context.lines_before or '')
end

return M
