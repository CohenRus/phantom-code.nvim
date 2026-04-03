local M = {}
local api = vim.api

--- Escape text for use inside double-quoted XML attributes.
---@param s string
---@return string
local function xml_attr(s)
    s = s or ''
    return (s:gsub('&', '&amp;'):gsub('"', '&quot;'):gsub('<', '&lt;'))
end

---@param path string
---@param max_bytes integer
---@return string
local function read_file_capped(path, max_bytes)
    local f = io.open(path, 'r')
    if not f then
        return ''
    end
    local body = f:read(max_bytes + 1)
    f:close()
    if not body then
        return ''
    end
    if #body > max_bytes then
        return body:sub(1, max_bytes) .. '\n... (truncated)'
    end
    return body
end

---@param bufnr integer
---@param r table LSP Range (0-based lines)
---@param max_bytes integer
---@return string
local function lines_from_range(bufnr, r, max_bytes)
    if not r or not r.start or not r['end'] then
        return ''
    end
    local sr, er = r.start.line, r['end'].line
    local lines = api.nvim_buf_get_lines(bufnr, sr, er + 1, false)
    local chunk = table.concat(lines, '\n')
    if #chunk > max_bytes then
        chunk = chunk:sub(1, max_bytes) .. '\n... (truncated)'
    end
    return chunk
end

---@param items table[]
---@param name string
---@param depth integer
---@return table|nil
local function find_sym_tree(items, name, depth)
    depth = depth or 0
    if depth > 40 then
        return nil
    end
    for _, it in ipairs(items) do
        local nm = it.name or it.text or ''
        if nm == name and (it.selectionRange or it.range) then
            return it
        end
        if it.children then
            local x = find_sym_tree(it.children, name, depth + 1)
            if x then
                return x
            end
        end
    end
    return nil
end

---@param bufnr integer
---@param name string
---@param max_bytes integer
---@param done fun(snippet: string)
local function lsp_symbol_snippet_async(bufnr, name, max_bytes, done)
    if type(done) ~= 'function' then
        return
    end
    if not api.nvim_buf_is_valid(bufnr) then
        done('')
        return
    end

    local clients = vim.lsp.get_clients { bufnr = bufnr }
    if #clients == 0 or not vim.lsp.buf_request_all then
        done('')
        return
    end

    local params = { textDocument = vim.lsp.util.make_text_document_params(bufnr) }
    local cur_uri = vim.uri_from_bufnr(bufnr)
    local function uri_same(u)
        if type(u) ~= 'string' then
            return false
        end
        if u == cur_uri then
            return true
        end
        local ok_u, fn_u = pcall(vim.uri_to_fname, u)
        local ok_cur, fn_cur = pcall(vim.uri_to_fname, cur_uri)
        return ok_u and ok_cur and fn_u == fn_cur
    end

    vim.lsp.buf_request_all(bufnr, 'textDocument/documentSymbol', params, function(results)
        if type(results) ~= 'table' then
            done('')
            return
        end

        for _, result in pairs(results) do
            local res = result and result.result
            if type(res) == 'table' and #res > 0 then
                -- Flat SymbolInformation[] (name + location) vs DocumentSymbol[] tree.
                if res[1].location and res[1].name then
                    for _, it in ipairs(res) do
                        if it.name == name and it.location and it.location.range and uri_same(it.location.uri) then
                            done(lines_from_range(bufnr, it.location.range, max_bytes))
                            return
                        end
                    end
                else
                    local sym = find_sym_tree(res, name)
                    if sym then
                        local r = sym.selectionRange or sym.range
                        if r then
                            done(lines_from_range(bufnr, r, max_bytes))
                            return
                        end
                    end
                end
            end
        end

        done('')
    end)
end

--- Strip `@file:` / `@symbol:` references, return cleaned instruction and XML blocks (within budget).
---@param instruction string
---@param bufnr integer
---@param max_chars integer
---@param done fun(clean_instruction: string, ref_xml: string)
function M.resolve_instruction(instruction, bufnr, max_chars, done)
    if type(done) ~= 'function' then
        return
    end
    max_chars = max_chars or 8000
    local blocks = {}
    local used = 0
    local function add_block(s)
        if not s or s == '' then
            return
        end
        if used + #s > max_chars then
            return
        end
        blocks[#blocks + 1] = s
        used = used + #s
    end

    local clean = instruction
    local base = vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr) or '', ':h')

    local function add_file_ref(path)
        local full = path
        if vim.fn.filereadable(path) ~= 1 then
            full = vim.fn.fnamemodify(base .. '/' .. path, ':p')
        end
        if vim.fn.filereadable(full) ~= 1 then
            return
        end
        local room = math.min(8000, max_chars - used - 100)
        if room < 64 then
            return
        end
        local body = read_file_capped(full, room)
        if body ~= '' then
            local rel = vim.fn.fnamemodify(full, ':.')
            add_block(string.format('<referencedFile path="%s">\n%s\n</referencedFile>', xml_attr(rel), body))
        end
    end

    clean = clean:gsub('@file:("[^"]+")', function(q)
        local path = q:sub(2, -2)
        add_file_ref(path)
        return ''
    end)

    clean = clean:gsub('@file:([%S]+)', function(spec)
        local path = spec:gsub('^"', ''):gsub('"$', '')
        add_file_ref(path)
        return ''
    end)

    local symbol_refs = {}
    clean = clean:gsub('@symbol:([%w_]+)', function(sym)
        symbol_refs[#symbol_refs + 1] = sym
        return ''
    end)

    clean = vim.trim(clean:gsub('\n%s*\n%s*\n', '\n\n'))
    if #symbol_refs == 0 then
        done(clean, table.concat(blocks, '\n'))
        return
    end

    local symbol_blocks = {}
    local pending = #symbol_refs
    for idx, sym in ipairs(symbol_refs) do
        lsp_symbol_snippet_async(bufnr, sym, math.min(4000, max_chars), function(body)
            if body ~= '' then
                symbol_blocks[idx] = string.format('<referencedSymbol name="%s">\n%s\n</referencedSymbol>', xml_attr(sym), body)
            end

            pending = pending - 1
            if pending == 0 then
                for i = 1, #symbol_refs do
                    add_block(symbol_blocks[i])
                end
                done(clean, table.concat(blocks, '\n'))
            end
        end)
    end
end

return M
