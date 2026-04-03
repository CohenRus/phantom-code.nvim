local api = vim.api
local utils = require 'phantom-code.utils'
local expand_parse = require 'phantom-code.expand_parse'
local expand_inline_diff = require 'phantom-code.expand_inline_diff'
local expand_context_refs = require 'phantom-code.expand_context_refs'

local M = {}

local PREVIEW_KEYMAP_MODES = { 'n', 'i' }
local INVOKE_KEYMAP_MODES = { 'n', 'v' }

---@class phantom-code.ExpandSession
---@field id integer
---@field mode 'implement'|'ask'
---@field bufnr integer
---@field range { bufnr: integer, sr: integer, sc: integer, er: integer, ec: integer, text: string }
---@field state string
---@field proposed_text string|nil
---@field prompt_win integer|nil
---@field ask_win integer|nil
---@field ui_layout 'float'|nil
---@field ask_buf integer|nil
---@field ask_messages table|nil
---@field review_keymaps { buf: integer|nil, lhs: string, mode: string, global?: boolean }[]
---@field generating_keymaps { buf: integer, lhs: string, mode: string }[]
---@field implement_messages { role: string, content: string }[]|nil
---@field instruction_prompt_buf integer|nil
---@field instruction_prompt_augroup integer|nil
---@field implement_prompt_title string|nil
---@field ask_footer_default string|nil
---@field ask_generating boolean|nil
---@field ask_hidden boolean|nil
---@field ask_resize_augroup integer|nil
---@field prompt_below_selection boolean|nil  -- instruction float opened below selection (narrow top margin)
---@field prompt_hidden boolean|nil  -- pinned implement prompt UI hidden via toggle (buffer kept)
---@field collapsed_extmark_id integer|nil  -- virt_text on source buffer when UI is collapsed

---@type table<integer, phantom-code.ExpandSession>
local sessions = {}
local next_session_id = 1

--- Snapshot of buffer text for range r; returns nil if positions are invalid.
---@param r { bufnr: integer, sr: integer, sc: integer, er: integer, ec: integer }
---@return string|nil
local function buf_get_range_text(r)
    if not r or not api.nvim_buf_is_valid(r.bufnr) then
        return nil
    end
    local ok, chunks = pcall(api.nvim_buf_get_text, r.bufnr, r.sr, r.sc, r.er, r.ec, {})
    if not ok or type(chunks) ~= 'table' then
        return nil
    end
    return table.concat(chunks, '\n')
end

---@param r { bufnr: integer, sr: integer, sc: integer, er: integer, ec: integer, text: string }
---@return boolean ok
---@return string|nil err_message
local function range_matches_buffer(r)
    local live = buf_get_range_text(r)
    if live == nil then
        return false, 'invalid range or buffer (selection may have moved or been edited)'
    end
    if live ~= r.text then
        return false, 'selection text changed since Expand ran; dismiss and try again'
    end
    return true, nil
end

local instruction_win = nil
local instruction_session_id = nil

local collapsed_ns = api.nvim_create_namespace 'phantom-code.expand_collapsed'

local function hl_expand()
    if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'PhantomCodeExpandPreview' })) then
        api.nvim_set_hl(0, 'PhantomCodeExpandPreview', { link = 'PhantomCodeVirtualText' })
    end
    if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'PhantomCodeExpandCollapsed' })) then
        api.nvim_set_hl(0, 'PhantomCodeExpandCollapsed', { default = true, link = 'NonText' })
    end
end

---@param sess phantom-code.ExpandSession|nil
local function clear_collapsed_marker(sess)
    if not sess or not sess.collapsed_extmark_id then
        return
    end
    local buf = sess.bufnr
    if buf and api.nvim_buf_is_valid(buf) then
        pcall(api.nvim_buf_del_extmark, buf, collapsed_ns, sess.collapsed_extmark_id)
    end
    sess.collapsed_extmark_id = nil
end

--- End-of-line hint on the expand selection row while float is collapsed.
---@param sess phantom-code.ExpandSession|nil
local function set_collapsed_marker(sess)
    if not sess or not sess.range then
        return
    end
    local cfg = require('phantom-code').config
    local text = (cfg.expand and cfg.expand.ui and cfg.expand.ui.collapsed_marker) or ' ⋯ expand'
    if type(text) ~= 'string' or text == '' then
        return
    end
    clear_collapsed_marker(sess)
    local buf = sess.range.bufnr
    if not buf or not api.nvim_buf_is_valid(buf) then
        return
    end
    local row = sess.range.sr
    local nlines = api.nvim_buf_line_count(buf)
    if row < 0 or row >= nlines then
        return
    end
    local id = api.nvim_buf_set_extmark(buf, collapsed_ns, row, 0, {
        virt_text = { { text, 'PhantomCodeExpandCollapsed' } },
        virt_text_pos = 'eol',
        hl_mode = 'combine',
        priority = 50,
    })
    if id and id > 0 then
        sess.collapsed_extmark_id = id
    end
end


---@param sess phantom-code.ExpandSession
local function unmap_review_keys(sess)
    if not sess.review_keymaps then
        return
    end
    for _, m in ipairs(sess.review_keymaps) do
        if m.global then
            pcall(vim.keymap.del, m.mode, m.lhs)
        elseif m.buf and api.nvim_buf_is_valid(m.buf) then
            pcall(vim.keymap.del, m.mode, m.lhs, { buffer = m.buf })
        end
    end
    sess.review_keymaps = {}
end

---@param sess phantom-code.ExpandSession
local function unmap_generating_keys(sess)
    if not sess.generating_keymaps then
        return
    end
    for _, m in ipairs(sess.generating_keymaps) do
        if api.nvim_buf_is_valid(m.buf) then
            pcall(vim.keymap.del, m.mode, m.lhs, { buffer = m.buf })
        end
    end
    sess.generating_keymaps = {}
end

---@param sess phantom-code.ExpandSession
---@param session_id integer
local function setup_generating_keymaps(sess, session_id)
    unmap_generating_keys(sess)
    local buf = sess.bufnr
    if not api.nvim_buf_is_valid(buf) then
        return
    end
    local km = require('phantom-code').config.expand.keymap or {}
    local lhs = km.dismiss
    if not lhs or lhs == '' then
        return
    end
    for _, mode in ipairs(PREVIEW_KEYMAP_MODES) do
        vim.keymap.set(mode, lhs, function()
            M.dismiss(session_id)
        end, {
            buffer = buf,
            silent = true,
            desc = '[phantom-code.expand] dismiss while generating',
        })
        sess.generating_keymaps[#sess.generating_keymaps + 1] = { buf = buf, lhs = lhs, mode = mode }
    end
end

---@param sess phantom-code.ExpandSession
local function close_prompt_win(sess)
    if sess.instruction_prompt_augroup then
        pcall(api.nvim_del_augroup_by_id, sess.instruction_prompt_augroup)
        sess.instruction_prompt_augroup = nil
    end
    local pbuf = sess.instruction_prompt_buf
    sess.instruction_prompt_buf = nil
    sess.implement_prompt_title = nil
    if sess.prompt_win and api.nvim_win_is_valid(sess.prompt_win) then
        pcall(api.nvim_win_close, sess.prompt_win, true)
    end
    sess.prompt_win = nil
    sess.prompt_below_selection = nil
    if pbuf and api.nvim_buf_is_valid(pbuf) then
        pcall(api.nvim_buf_delete, pbuf, { force = true })
    end
    if instruction_win and sess.id == instruction_session_id then
        instruction_win = nil
        instruction_session_id = nil
    end
end

---@param sess phantom-code.ExpandSession
---@param title string
---@param footer? string
local function update_implement_prompt_chrome(sess, title, footer)
    if not sess.prompt_win or not api.nvim_win_is_valid(sess.prompt_win) then
        return
    end
    local ok, cfg = pcall(api.nvim_win_get_config, sess.prompt_win)
    if not ok or type(cfg) ~= 'table' then
        return
    end
    cfg.title = title
    cfg.title_pos = 'center'
    if footer then
        cfg.footer = footer
        cfg.footer_pos = 'center'
    end
    pcall(api.nvim_win_set_config, sess.prompt_win, cfg)
end

--- Hide the ask window but keep the buffer alive for re-entry.
---@param sess phantom-code.ExpandSession
local function close_ask_ui(sess)
    if sess.ask_win and api.nvim_win_is_valid(sess.ask_win) then
        pcall(api.nvim_win_close, sess.ask_win, true)
    end
    sess.ask_win = nil
    sess.ui_layout = nil
    sess.ask_footer_default = nil
end

--- Fully destroy the ask UI (window + buffer).
---@param sess phantom-code.ExpandSession
local function destroy_ask_ui(sess)
    close_ask_ui(sess)
    if sess.ask_resize_augroup then
        pcall(api.nvim_del_augroup_by_id, sess.ask_resize_augroup)
        sess.ask_resize_augroup = nil
    end
    if sess.ask_buf and api.nvim_buf_is_valid(sess.ask_buf) then
        pcall(api.nvim_buf_delete, sess.ask_buf, { force = true })
    end
    sess.ask_buf = nil
end

---@param r { bufnr: integer, sr: integer, sc: integer, er: integer, ec: integer, text: string }
---@param mode 'implement'|'ask'
---@return integer, phantom-code.ExpandSession
local function create_session(r, mode)
    local id = next_session_id
    next_session_id = next_session_id + 1
    ---@type phantom-code.ExpandSession
    local sess = {
        id = id,
        mode = mode,
        bufnr = r.bufnr,
        range = r,
        state = 'prompt',
        proposed_text = nil,
        prompt_win = nil,
        ask_win = nil,
        ui_layout = nil,
        ask_buf = nil,
        ask_messages = mode == 'ask' and {} or nil,
        review_keymaps = {},
        generating_keymaps = {},
        implement_messages = nil,
        instruction_prompt_buf = nil,
        instruction_prompt_augroup = nil,
        implement_prompt_title = nil,
        ask_footer_default = nil,
        prompt_below_selection = nil,
    }
    sessions[id] = sess
    return id, sess
end

---@param id integer
local function destroy_session(id)
    local sess = sessions[id]
    if not sess then
        return
    end
    local common = require 'phantom-code.backends.common'
    common.terminate_expand_jobs_for_session(id)
    unmap_generating_keys(sess)
    unmap_review_keys(sess)
    clear_collapsed_marker(sess)
    close_prompt_win(sess)
    destroy_ask_ui(sess)
    if sess.bufnr and api.nvim_buf_is_valid(sess.bufnr) and require('phantom-code').config.expand.inline_diff.enable ~= false then
        expand_inline_diff.clear(sess.bufnr)
    end
    sessions[id] = nil
end

local function dismiss_all()
    local common = require 'phantom-code.backends.common'
    local ids = {}
    for sid in pairs(sessions) do
        ids[#ids + 1] = sid
    end
    for _, sid in ipairs(ids) do
        destroy_session(sid)
    end
    common.terminate_expand_jobs()
    if instruction_win and api.nvim_win_is_valid(instruction_win) then
        pcall(api.nvim_win_close, instruction_win, true)
    end
    instruction_win = nil
    instruction_session_id = nil
end

---@param bufnr integer
---@param sr integer 0-based
---@param sc integer
---@param width integer
---@param height integer
---@return table, integer|nil row_off (nil when editor-relative fallback)
local function anchored_win_config(bufnr, sr, sc, width, height)
    local winid = vim.fn.bufwinid(bufnr)
    if winid == -1 then
        return {
            relative = 'editor',
            width = width,
            height = height,
            row = math.max(0, math.floor((vim.o.lines - height) / 2)),
            col = math.max(0, math.floor((vim.o.columns - width) / 2)),
            style = 'minimal',
            border = 'rounded',
        }, nil
    end
    local w0 = vim.fn.line('w0', winid)
    local win_h = api.nvim_win_get_height(winid)
    local row_off = sr - (w0 - 1)
    if row_off < 0 or row_off >= win_h then
        return {
            relative = 'editor',
            width = width,
            height = height,
            row = math.max(0, math.floor((vim.o.lines - height) / 2)),
            col = math.max(0, math.floor((vim.o.columns - width) / 2)),
            style = 'minimal',
            border = 'rounded',
        }, nil
    end
    -- Place above selection; fall back to below if not enough room
    local place_row
    if row_off >= height + 1 then
        place_row = row_off - height - 1
    else
        place_row = math.min(row_off + 1, math.max(0, win_h - height - 1))
    end
    return {
        relative = 'win',
        win = winid,
        width = width,
        height = height,
        row = place_row,
        col = math.min(2, math.max(0, vim.fn.winwidth(winid) - width - 2)),
        anchor = 'NW',
        style = 'minimal',
        border = 'rounded',
    }, row_off
end

--- Insert a newline at the cursor (insert mode); `<CR>` is reserved for submit on expand prompts.
---@param buf integer
local function insert_newline_in_expand_prompt(buf)
    local row, col = unpack(api.nvim_win_get_cursor(0))
    local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ''
    local before = line:sub(1, col)
    local after = line:sub(col + 1)
    api.nvim_buf_set_text(buf, row - 1, 0, row - 1, #line, { before, after })
    api.nvim_win_set_cursor(0, { row + 1, 0 })
end

--- `<CR>` in normal and insert submits; `<C-J>` inserts a newline in insert mode.
---@param buf integer
---@param submit_fn fun()
---@param desc string
local function bind_prompt_submit_keys(buf, submit_fn, desc)
    local o = { buffer = buf, silent = true }
    vim.keymap.set({ 'n', 'i' }, '<CR>', submit_fn, vim.tbl_extend('force', o, { desc = desc .. ' (Enter)' }))
    vim.keymap.set('i', '<C-J>', function()
        insert_newline_in_expand_prompt(buf)
    end, vim.tbl_extend('force', o, { desc = desc .. ' (newline)' }))
end

---@param km table
---@return string
local function footer_focus_dismiss(km)
    return string.format('%s · %s', utils.keymap_footer_label(km.focus_window), utils.keymap_footer_label(km.dismiss))
end

---@param km table
---@return string
local function implement_instruction_footer(km)
    return string.format(' Enter submit · ^J newline · %s ', footer_focus_dismiss(km))
end

--- Dismiss / focus_window on expand UI buffers (ask, instruction).
---@param buf integer
---@param session_id integer
local function bind_expand_window_aux(buf, session_id)
    local km = require('phantom-code').config.expand.keymap or {}
    if km.dismiss and km.dismiss ~= '' then
        for _, mode in ipairs(PREVIEW_KEYMAP_MODES) do
            vim.keymap.set(mode, km.dismiss, function()
                M.dismiss(session_id)
            end, {
                buffer = buf,
                silent = true,
                desc = '[phantom-code.expand] dismiss from expand window',
            })
        end
    end
    if km.focus_window and km.focus_window ~= '' then
        vim.keymap.set('n', km.focus_window, function()
            if not M.unfocus_window() then
                M.focus_nearest_window()
            end
        end, {
            buffer = buf,
            silent = true,
            desc = '[phantom-code.expand] toggle expand window focus',
        })
    end
end

--- Nudge the instruction float down when inline diff adds `virt_lines_above` and the float sits below the selection.
---@param sess phantom-code.ExpandSession
local function reposition_prompt_after_diff(sess)
    if not sess.prompt_below_selection then
        return
    end
    if not sess.prompt_win or not api.nvim_win_is_valid(sess.prompt_win) then
        return
    end
    local r = sess.range
    if not r or not api.nvim_buf_is_valid(r.bufnr) then
        return
    end
    local add_lines = expand_inline_diff.count_virt_lines_above_in_range(r.bufnr, r.sr, r.er)
    if add_lines == 0 then
        return
    end
    local src_win = vim.fn.bufwinid(r.bufnr)
    if src_win == -1 or not api.nvim_win_is_valid(src_win) then
        return
    end
    local ok, cfg = pcall(api.nvim_win_get_config, sess.prompt_win)
    if not ok or type(cfg) ~= 'table' or cfg.relative ~= 'win' or cfg.win ~= src_win then
        return
    end
    local wh = api.nvim_win_get_height(src_win)
    local win_h = cfg.height or 1
    local max_row = math.max(0, wh - win_h - 1)
    cfg.row = math.min((cfg.row or 0) + add_lines, max_row)
    pcall(api.nvim_win_set_config, sess.prompt_win, cfg)
end

--- Multi-line instruction float UI. `<CR>` submits in normal and insert; `<C-J>` inserts a newline in insert mode.
---@param target_bufnr integer
---@param session_id integer
---@param title string
---@param initial_lines string[]|nil
---@param on_done fun(text: string|nil)
---@param prompt_opts? { footer?: string, keep_open_after_submit?: boolean }
local function show_multiline_prompt(target_bufnr, session_id, title, initial_lines, on_done, prompt_opts)
    local cfg = require('phantom-code').config
    local ui = cfg.expand.ui or {}
    local w = ui.prompt_width or 72
    local max_h = ui.prompt_height or 10
    local r = sessions[session_id].range
    local initial_line_count = initial_lines and #initial_lines or 1
    local h = math.max(1, math.min(initial_line_count, max_h))

    local buf = api.nvim_create_buf(false, false)
    api.nvim_buf_set_lines(buf, 0, -1, false, initial_lines or { '' })
    -- Use 'hide' (like ask): 'wipe' removes the buffer when the float closes, so toggle cannot reopen.
    api.nvim_buf_set_option(buf, 'bufhidden', 'hide')
    api.nvim_buf_set_option(buf, 'swapfile', false)
    local base_dir = vim.fn.fnamemodify(
        (api.nvim_buf_get_name(target_bufnr) ~= '' and api.nvim_buf_get_name(target_bufnr)) or vim.fn.getcwd(),
        ':p:h'
    )
    pcall(api.nvim_buf_set_name, buf, vim.fs.joinpath(base_dir, '.phantom-expand-prompt.' .. tostring(session_id)))
    api.nvim_buf_set_option(buf, 'buftype', '')
    api.nvim_buf_set_option(buf, 'buflisted', false)
    api.nvim_buf_set_option(buf, 'filetype', 'markdown')
    api.nvim_buf_set_var(buf, 'phantom_code_virtual_text_auto_trigger', false)
    api.nvim_buf_set_var(buf, 'phantom_code_expand_prompt', true)

    local done = false
    local sess = sessions[session_id]
    -- Track buffer + augroup on the session from the start so toggle_window can hide the prompt
    -- before submit (same as ask keeping ask_buf while the float is closed).
    sess.instruction_prompt_buf = buf
    local augroup = api.nvim_create_augroup('PhantomCodeExpandPrompt' .. tostring(session_id), { clear = true })
    sess.instruction_prompt_augroup = augroup
    local keep_open = prompt_opts and prompt_opts.keep_open_after_submit

    local function finish(value)
        if done then
            return
        end
        done = true
        pcall(api.nvim_del_augroup_by_id, augroup)
        sess.instruction_prompt_augroup = nil
        close_prompt_win(sess)
        if api.nvim_buf_is_valid(buf) then
            pcall(api.nvim_buf_delete, buf, { force = true })
        end
        vim.schedule(function()
            if target_bufnr and api.nvim_buf_is_valid(target_bufnr) then
                local win = vim.fn.bufwinid(target_bufnr)
                if win ~= -1 then
                    api.nvim_set_current_win(win)
                end
            end
            pcall(vim.cmd, 'stopinsert')
            on_done(value)
        end)
    end

    local km = cfg.expand.keymap or {}
    local win_cfg, anchor_row_off = anchored_win_config(r.bufnr, r.sr, r.sc, w, h)
    sess.prompt_below_selection = anchor_row_off ~= nil and anchor_row_off < h + 1
    win_cfg.title = title
    win_cfg.title_pos = 'center'
    win_cfg.footer = (prompt_opts and prompt_opts.footer) or implement_instruction_footer(km)
    win_cfg.footer_pos = 'center'
    local win = api.nvim_open_win(buf, true, win_cfg)
    sess.prompt_win = win
    sess.ui_layout = 'float'
    instruction_win = win
    instruction_session_id = session_id

    api.nvim_create_autocmd('WinClosed', {
        group = augroup,
        callback = function(args)
            if tonumber(args.match) == win and not done then
                finish(nil)
            end
        end,
    })

    api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
        group = augroup,
        buffer = buf,
        callback = function()
            if not sess.prompt_win or not api.nvim_win_is_valid(sess.prompt_win) then
                return
            end
            local line_count = api.nvim_buf_line_count(buf)
            local new_h = math.max(1, math.min(line_count, max_h))
            local ok, cur_cfg = pcall(api.nvim_win_get_config, sess.prompt_win)
            if ok and cur_cfg.height ~= new_h then
                cur_cfg.height = new_h
                if anchor_row_off then
                    if anchor_row_off >= new_h + 1 then
                        cur_cfg.row = anchor_row_off - new_h - 1
                    else
                        local src_win = vim.fn.bufwinid(r.bufnr)
                        if src_win == -1 or not api.nvim_win_is_valid(src_win) then
                            return
                        end
                        local wh = api.nvim_win_get_height(src_win)
                        cur_cfg.row = math.min(anchor_row_off + 1, math.max(0, wh - new_h - 1))
                    end
                end
                pcall(api.nvim_win_set_config, sess.prompt_win, cur_cfg)
            end
        end,
    })

    local function unmap_prompt_buffer_keys()
        for _, mode in ipairs { 'n', 'i' } do
            pcall(vim.keymap.del, mode, '<CR>', { buffer = buf })
        end
        pcall(vim.keymap.del, 'i', '<C-J>', { buffer = buf })
    end

    local function submit_prompt()
        local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
        local text = vim.trim(table.concat(lines, '\n'))
        if text == '' then
            finish(nil)
            return
        end
        if not keep_open then
            finish(text)
            return
        end
        done = true
        pcall(api.nvim_del_augroup_by_id, augroup)
        sess.instruction_prompt_augroup = nil
        unmap_prompt_buffer_keys()
        api.nvim_buf_set_option(buf, 'modifiable', false)
        sess.implement_prompt_title = vim.trim(title)

        local pin_au = api.nvim_create_augroup('PhantomCodeExpandPromptPin' .. tostring(session_id), { clear = true })
        sess.instruction_prompt_augroup = pin_au
        api.nvim_create_autocmd('WinClosed', {
            group = pin_au,
            callback = function(args)
                if tonumber(args.match) == win then
                    vim.schedule(function()
                        if sessions[session_id] and not api.nvim_win_is_valid(win) then
                            destroy_session(session_id)
                        end
                    end)
                end
            end,
        })

        local base = sess.implement_prompt_title
        local dismiss_l = utils.keymap_footer_label(km.dismiss)
        local focus_l = utils.keymap_footer_label(km.focus_window)
        update_implement_prompt_chrome(
            sess,
            ' ' .. base .. ' · generating… ',
            string.format(' waiting for model · %s cancel · %s focus ', dismiss_l, focus_l)
        )

        vim.schedule(function()
            if target_bufnr and api.nvim_buf_is_valid(target_bufnr) then
                local tw = vim.fn.bufwinid(target_bufnr)
                if tw ~= -1 then
                    api.nvim_set_current_win(tw)
                end
            end
            pcall(vim.cmd, 'stopinsert')
            on_done(text)
        end)
    end

    bind_prompt_submit_keys(buf, submit_prompt, '[phantom-code.expand] submit prompt')
    bind_expand_window_aux(buf, session_id)

    vim.schedule(function()
        if api.nvim_win_is_valid(win) then
            api.nvim_set_current_win(win)
            vim.cmd.startinsert()
        end
    end)
end

---@param cfg table
---@param tmpl string|function
---@param vars table
local function fill_user_template(cfg, tmpl, vars)
    if type(tmpl) == 'function' then
        return tmpl(vars, cfg)
    end
    local s = tmpl
    for k, v in pairs(vars) do
        local pat = vim.pesc('<' .. k .. '>')
        s = s:gsub(pat, function()
            return v
        end)
    end
    return s
end

---@param cfg table
---@return string
---@param cfg table
---@param is_generate boolean
local function expand_system_text(cfg, is_generate)
    if is_generate then
        local g = cfg.expand.system_generate
        if g then
            if type(g) == 'function' then
                return g(cfg) or ''
            end
            return g
        end
    end
    local sys = cfg.expand.system
    if type(sys) == 'function' then
        return sys(cfg) or ''
    end
    return sys or ''
end

---@param cfg table
---@return string
local function expand_system_ask_text(cfg)
    local sys = cfg.expand.system_ask
    if type(sys) == 'function' then
        return sys(cfg) or ''
    end
    return sys or ''
end


---@param sess phantom-code.ExpandSession
---@param session_id integer
local function setup_review_keymaps(sess, session_id)
    unmap_review_keys(sess)
    local cfg = require('phantom-code').config
    local km = cfg.expand.keymap or {}

    local function bind(lhs, fn, desc, buf)
        if not lhs or lhs == '' then
            return
        end
        if not buf or not api.nvim_buf_is_valid(buf) then
            return
        end
        for _, mode in ipairs(PREVIEW_KEYMAP_MODES) do
            vim.keymap.set(mode, lhs, fn, {
                buffer = buf,
                silent = true,
                desc = desc,
            })
            sess.review_keymaps[#sess.review_keymaps + 1] = { buf = buf, lhs = lhs, mode = mode }
        end
    end

    local code_buf = sess.bufnr
    bind(km.accept, function()
        M.accept(session_id)
    end, '[phantom-code.expand] accept', code_buf)
    bind(km.dismiss, function()
        M.dismiss(session_id)
    end, '[phantom-code.expand] dismiss', code_buf)
    bind(km.revise, function()
        M.revise(session_id)
    end, '[phantom-code.expand] revise', code_buf)

    -- Pinned prompt: same accept/dismiss/revise as the code buffer so keys work after toggle, focus, and
    -- sync (bind_expand_window_aux below restores focus_window in normal mode).
    local pb = sess.instruction_prompt_buf
    if pb and api.nvim_buf_is_valid(pb) then
        bind(km.accept, function()
            M.accept(session_id)
        end, '[phantom-code.expand] accept (expand prompt)', pb)
        bind(km.dismiss, function()
            M.dismiss(session_id)
        end, '[phantom-code.expand] dismiss (expand prompt)', pb)
        bind(km.revise, function()
            M.revise(session_id)
        end, '[phantom-code.expand] revise (expand prompt)', pb)
    end

    local g_accept = km.accept_global
    if g_accept and g_accept ~= '' then
        for _, mode in ipairs(PREVIEW_KEYMAP_MODES) do
            vim.keymap.set(mode, g_accept, function()
                M.accept(session_id)
            end, {
                silent = true,
                desc = '[phantom-code.expand] accept (global)',
            })
            sess.review_keymaps[#sess.review_keymaps + 1] = { buf = nil, lhs = g_accept, mode = mode, global = true }
        end
    end
end

--- Re-apply buffer-local generating/review maps and expand-window aux keys (dismiss/focus) on the prompt.
---@param session_id integer
local function sync_implement_code_buffer_keymaps(session_id)
    local sess = sessions[session_id]
    if not sess or sess.mode ~= 'implement' then
        return
    end
    if sess.state == 'generating' then
        setup_generating_keymaps(sess, session_id)
    elseif sess.state == 'review' then
        setup_review_keymaps(sess, session_id)
    end
    local pb = sess.instruction_prompt_buf
    if pb and api.nvim_buf_is_valid(pb) then
        bind_expand_window_aux(pb, session_id)
    end
end

--- Drop oldest entries so implement revise history stays bounded (pairs: user, assistant, …).
---@param sess phantom-code.ExpandSession
---@param cfg table
local function trim_implement_messages(sess, cfg)
    local max_m = cfg.expand.max_conversation_messages
    if not max_m or max_m < 1 then
        return
    end
    local m = sess.implement_messages
    if not m or #m <= max_m then
        return
    end
    -- Remove oldest user+assistant pairs so message roles stay well-formed for the API.
    while #m > max_m do
        table.remove(m, 1)
        if #m > 0 then
            table.remove(m, 1)
        end
    end
end

---@param sess phantom-code.ExpandSession
---@param session_id integer
---@param instruction string
local function run_implement_request(sess, session_id, instruction)
    local cfg = require('phantom-code').config
    local r = sess.range
    if not api.nvim_buf_is_valid(r.bufnr) then
        destroy_session(session_id)
        return
    end

    local function start_request(clean_instr, ref_xml)

        sess.state = 'generating'
        if cfg.expand.inline_diff.enable ~= false then
            expand_inline_diff.clear(r.bufnr)
        end
        unmap_generating_keys(sess)
        setup_generating_keymaps(sess, session_id)

        local resolved = utils.resolve_provider_config 'expand'
        local ctx_win = cfg.expand.context_window or cfg.context_window
        local ctx_ratio = cfg.expand.context_ratio or cfg.context_ratio
        local surround = utils.get_expand_file_surround(r.bufnr, r.sr, r.sc, r.er, r.ec, ctx_win, ctx_ratio)
        local diag_cfg = vim.tbl_deep_extend('force', {}, cfg.diagnostics or {}, cfg.expand.diagnostics or {})
        local diag_str = utils.build_diagnostics_context(r.bufnr, r.sr + 1, diag_cfg)
        local diag_block = ''
        if diag_str ~= '' then
            diag_block = '\n\nNearby buffer diagnostics:\n' .. diag_str .. '\n'
        end
        local path = vim.fn.fnamemodify(api.nvim_buf_get_name(r.bufnr) or '', ':.')
        if path == '' then
            path = '[No Name]'
        end
        local ft = api.nvim_buf_get_option(r.bufnr, 'filetype') or ''

        local vars = {
            instruction = clean_instr,
            referencedContextBlock = ref_xml ~= '' and (ref_xml .. '\n') or '',
            selectedCode = r.text,
            filePath = path,
            fileType = ft,
            fileContextBefore = surround.lines_before,
            fileContextAfter = surround.lines_after,
            diagnosticsBlock = diag_block,
        }

        local user_msg = fill_user_template(cfg, cfg.expand.user_template, vars)
        local system_text = expand_system_text(cfg, r.text == '')
        local opts = vim.deepcopy(resolved.options)
        if cfg.expand.max_tokens ~= nil then
            if resolved.provider == 'claude' then
                opts.max_tokens = cfg.expand.max_tokens
            else
                opts.optional =
                    vim.tbl_deep_extend('force', vim.deepcopy(opts.optional or {}), { max_tokens = cfg.expand.max_tokens })
            end
        end

        local few = utils.get_or_eval_value(cfg.expand.few_shots)
        if few then
            few = vim.deepcopy(few)
        end

        local cancel_inflight = cfg.expand.cancel_inflight ~= false
        local request_opts = {
            max_time = cfg.expand.request_timeout,
            cancel_existing_expand_jobs = cancel_inflight,
            expand_session_id = session_id,
        }

        local function on_done(raw)
            vim.schedule(function()
                if sessions[session_id] ~= sess then
                    return
                end
                if not raw or raw == '' then
                    vim.notify('phantom-code Expand: empty response', vim.log.levels.WARN)
                    destroy_session(session_id)
                    return
                end

                local proposed, _kind = expand_parse.parse_response(raw, r.text)
                if cfg.expand.merge ~= false then
                    if type(cfg.expand.merge_fn) == 'function' then
                        local merged = cfg.expand.merge_fn(r.text, proposed, { bufnr = r.bufnr, start_row = r.sr })
                        if type(merged) == 'string' then
                            proposed = merged
                        end
                    else
                        proposed = utils.merge_expand_replacement(r.text, proposed, { bufnr = r.bufnr, start_row = r.sr })
                    end
                end

                sess.proposed_text = proposed
                sess.state = 'review'

                sess.implement_messages = sess.implement_messages or {}
                table.insert(sess.implement_messages, { role = 'user', content = user_msg })
                table.insert(sess.implement_messages, { role = 'assistant', content = proposed })
                trim_implement_messages(sess, cfg)

                if cfg.expand.inline_diff.enable ~= false then
                    local old_for_diff = r.text
                    local live = buf_get_range_text(r)
                    if live ~= nil and live ~= r.text then
                        vim.notify(
                            'phantom-code Expand: buffer changed during generation; diff is aligned to current buffer text.',
                            vim.log.levels.WARN
                        )
                        old_for_diff = live
                        r.text = live
                    end
                    expand_inline_diff.render(r.bufnr, r.sr, r.er, old_for_diff, proposed)
                    reposition_prompt_after_diff(sess)
                    local src_w = vim.fn.bufwinid(r.bufnr)
                    if src_w ~= -1 then
                        api.nvim_win_call(src_w, function()
                            pcall(vim.cmd, 'normal! zz')
                        end)
                    end
                end

                if sessions[session_id] ~= sess then
                    return
                end

                unmap_generating_keys(sess)
                sync_implement_code_buffer_keymaps(session_id)
                local km = cfg.expand.keymap or {}
                if sess.prompt_win and api.nvim_win_is_valid(sess.prompt_win) and sess.instruction_prompt_buf then
                    local base = sess.implement_prompt_title or 'Expand'
                    update_implement_prompt_chrome(
                        sess,
                        ' ' .. base .. ' · review ',
                        string.format(
                            ' use keys on code buffer · %s accept · %s dismiss · %s revise ',
                            utils.keymap_footer_label(km.accept),
                            utils.keymap_footer_label(km.dismiss),
                            utils.keymap_footer_label(km.revise)
                        )
                    )
                end
                vim.notify('phantom-code Expand: review inline diff — accept / dismiss / revise', vim.log.levels.INFO)
            end)
        end

        local mod = require('phantom-code.backends.' .. resolved.provider)
        if not mod.expand_chat then
            vim.notify('phantom-code Expand: backend has no expand_chat()', vim.log.levels.ERROR)
            destroy_session(session_id)
            return
        end

        sess.implement_messages = sess.implement_messages or {}
        local hist = sess.implement_messages

        if resolved.provider == 'claude' then
            local messages = {}
            if few then
                vim.list_extend(messages, few)
            end
            for _, m in ipairs(hist) do
                table.insert(messages, vim.deepcopy(m))
            end
            table.insert(messages, { role = 'user', content = user_msg })
            mod.expand_chat(opts, system_text, messages, on_done, request_opts)
        else
            local messages = {
                { role = 'system', content = system_text },
            }
            if few then
                vim.list_extend(messages, few)
            end
            for _, m in ipairs(hist) do
                table.insert(messages, vim.deepcopy(m))
            end
            table.insert(messages, { role = 'user', content = user_msg })
            mod.expand_chat(opts, messages, on_done, request_opts)
        end
    end

    expand_context_refs.resolve_instruction(instruction, r.bufnr, cfg.expand.max_reference_chars or 8000, function(clean_instr, ref_xml)
        if sessions[session_id] ~= sess then
            return
        end
        if not api.nvim_buf_is_valid(r.bufnr) then
            destroy_session(session_id)
            return
        end
        start_request(clean_instr, ref_xml)
    end)
end

--- Build ask context vars. Last entry in `ask_messages` must be the current user question.
---@param sess phantom-code.ExpandSession
---@return table|nil
local function ask_vars(sess)
    local cfg = require('phantom-code').config
    local r = sess.range
    local last = sess.ask_messages and sess.ask_messages[#sess.ask_messages]
    if not last or last.role ~= 'user' then
        return nil
    end
    local question = last.content
    local ctx_win = cfg.expand.context_window or cfg.context_window
    local ctx_ratio = cfg.expand.context_ratio or cfg.context_ratio
    local surround = utils.get_expand_file_surround(r.bufnr, r.sr, r.sc, r.er, r.ec, ctx_win, ctx_ratio)
    local diag_cfg = vim.tbl_deep_extend('force', {}, cfg.diagnostics or {}, cfg.expand.diagnostics or {})
    local diag_str = utils.build_diagnostics_context(r.bufnr, r.sr + 1, diag_cfg)
    local diag_block = ''
    if diag_str ~= '' then
        diag_block = '\n\nNearby buffer diagnostics:\n' .. diag_str .. '\n'
    end
    local path = vim.fn.fnamemodify(api.nvim_buf_get_name(r.bufnr) or '', ':.')
    if path == '' then
        path = '[No Name]'
    end
    local ft = api.nvim_buf_get_option(r.bufnr, 'filetype') or ''

    local conv = ''
    if sess.ask_messages and #sess.ask_messages > 1 then
        local parts = {}
        for i = 1, #sess.ask_messages - 1 do
            local m = sess.ask_messages[i]
            if m.role == 'user' then
                parts[#parts + 1] = 'User: ' .. m.content
            else
                parts[#parts + 1] = 'Assistant: ' .. m.content
            end
        end
        conv = table.concat(parts, '\n\n')
    end

    return {
        question = question,
        selectedCode = r.text,
        filePath = path,
        fileType = ft,
        fileContextBefore = surround.lines_before,
        fileContextAfter = surround.lines_after,
        diagnosticsBlock = diag_block,
        conversationBlock = conv == '' and '(none)' or conv,
    }
end

---@param sess phantom-code.ExpandSession
---@param generating boolean
local function set_ask_float_chrome(sess, generating)
    if not sess.ask_win or not api.nvim_win_is_valid(sess.ask_win) then
        return
    end
    local km = require('phantom-code').config.expand.keymap or {}
    local ok, cfg = pcall(api.nvim_win_get_config, sess.ask_win)
    if not ok or type(cfg) ~= 'table' then
        return
    end
    cfg.title_pos = 'center'
    cfg.footer_pos = 'center'
    if generating then
        cfg.title = ' Expand ask · waiting… '
        cfg.footer = string.format(' generating… · %s ', footer_focus_dismiss(km))
    else
        cfg.title = ' Expand ask '
        cfg.footer = sess.ask_footer_default or cfg.footer
    end
    pcall(api.nvim_win_set_config, sess.ask_win, cfg)
end

--- Shown while the model request is in flight (submit rejects this text).
local ASK_WAITING_BUFFER_TEXT = 'Waiting for reply…'

--- Ask buffer shows a single “latest” view: waiting line, else last message body only (assistant or user), else one empty line.
---@param sess phantom-code.ExpandSession
---@param awaiting_reply boolean
local function ask_render_transcript(sess, awaiting_reply)
    local buf = sess.ask_buf
    if not buf or not api.nvim_buf_is_valid(buf) then
        return
    end
    local lines
    if awaiting_reply then
        lines = { ASK_WAITING_BUFFER_TEXT }
    else
        local msgs = sess.ask_messages or {}
        local last = msgs[#msgs]
        if not last then
            lines = { '' }
        elseif last.role == 'assistant' or last.role == 'user' then
            lines = vim.split(last.content, '\n', { plain = true })
        else
            lines = { '' }
        end
        if #lines == 0 then
            lines = { '' }
        end
    end
    api.nvim_buf_set_option(buf, 'modifiable', true)
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

---@param sess phantom-code.ExpandSession
---@param session_id integer
local function run_ask_request(sess, session_id)
    local cfg = require('phantom-code').config
    local resolved = utils.resolve_provider_config 'expand'

    local vars = ask_vars(sess)
    if not vars then
        if sess.ask_buf and api.nvim_buf_is_valid(sess.ask_buf) then
            api.nvim_buf_set_option(sess.ask_buf, 'modifiable', true)
            set_ask_float_chrome(sess, false)
            ask_render_transcript(sess, false)
        end
        return
    end
    local user_msg = fill_user_template(cfg, cfg.expand.user_template_ask, vars)
    local system_text = expand_system_ask_text(cfg)

    local opts = vim.deepcopy(resolved.options)
    if cfg.expand.max_tokens ~= nil then
        if resolved.provider == 'claude' then
            opts.max_tokens = cfg.expand.max_tokens
        else
            opts.optional =
                vim.tbl_deep_extend('force', vim.deepcopy(opts.optional or {}), { max_tokens = cfg.expand.max_tokens })
        end
    end

    local cancel_inflight = cfg.expand.cancel_inflight ~= false
    local request_opts = {
        max_time = cfg.expand.request_timeout,
        cancel_existing_expand_jobs = cancel_inflight,
        expand_session_id = session_id,
    }

    sess.ask_generating = true

    local function on_done(raw)
        vim.schedule(function()
            if sessions[session_id] ~= sess then
                return
            end
            sess.ask_generating = false
            local text = vim.trim(raw or '')
            if text == '' then
                vim.notify('phantom-code Expand ask: empty response', vim.log.levels.WARN)
            else
                table.insert(sess.ask_messages, { role = 'assistant', content = text })
            end
            ask_render_transcript(sess, false)
            if sess.ask_buf and api.nvim_buf_is_valid(sess.ask_buf) then
                api.nvim_buf_set_option(sess.ask_buf, 'modifiable', true)
            end
            set_ask_float_chrome(sess, false)
            if text ~= '' then
                vim.notify('phantom-code: ask response ready', vim.log.levels.INFO)
            end
        end)
    end

    local mod = require('phantom-code.backends.' .. resolved.provider)
    if not mod.expand_chat then
        if sess.ask_buf and api.nvim_buf_is_valid(sess.ask_buf) then
            api.nvim_buf_set_option(sess.ask_buf, 'modifiable', true)
            set_ask_float_chrome(sess, false)
            ask_render_transcript(sess, false)
        end
        vim.notify('phantom-code Expand ask: backend has no expand_chat()', vim.log.levels.ERROR)
        return
    end

    -- Single user turn per request; prior Q&A lives in <conversationBlock> in the template.
    local messages = {
        { role = 'user', content = user_msg },
    }

    if resolved.provider == 'claude' then
        mod.expand_chat(opts, system_text, messages, on_done, request_opts)
    else
        local openai_msgs = {
            { role = 'system', content = system_text },
            { role = 'user', content = user_msg },
        }
        mod.expand_chat(opts, openai_msgs, on_done, request_opts)
    end
end

--- Reopen the ask float when the buffer exists but the window was closed (hidden).
---@param session_id integer
---@return boolean
local function reopen_ask_float(session_id)
    local sess = sessions[session_id]
    if not sess or sess.mode ~= 'ask' or not (sess.ask_buf and api.nvim_buf_is_valid(sess.ask_buf)) then
        return false
    end
    if sess.ask_win then
        if api.nvim_win_is_valid(sess.ask_win) then
            return false
        end
        sess.ask_win = nil
    end
    local cfg_mod = require('phantom-code').config
    local ui = cfg_mod.expand.ui or {}
    local w = ui.ask_width or 80
    local line_count = api.nvim_buf_line_count(sess.ask_buf)
    local max_ask_h = ui.ask_height or 16
    local h = math.max(1, math.min(line_count, max_ask_h))
    local r = sess.range
    local km = cfg_mod.expand.keymap or {}
    local footer_text = ' ' .. vim.trim(implement_instruction_footer(km)) .. ' '
    sess.ask_footer_default = footer_text

    local win_cfg = anchored_win_config(r.bufnr, r.sr, r.sc, w, h)
    win_cfg.title = sess.ask_generating and ' Expand ask · waiting… ' or ' Expand ask '
    win_cfg.title_pos = 'center'
    win_cfg.footer = footer_text
    win_cfg.footer_pos = 'center'
    local ok, opened = pcall(api.nvim_open_win, sess.ask_buf, true, win_cfg)
    local win
    if ok and opened then
        win = opened
        sess.ask_win = win
        sess.ui_layout = 'float'
    end

    if not win or not api.nvim_win_is_valid(win) then
        return false
    end

    sess.ask_hidden = false
    set_ask_float_chrome(sess, sess.ask_generating or false)
    clear_collapsed_marker(sess)

    vim.schedule(function()
        if win and api.nvim_win_is_valid(win) then
            api.nvim_set_current_win(win)
            local last = api.nvim_buf_line_count(sess.ask_buf)
            api.nvim_win_set_cursor(win, { last, 0 })
            if not sess.ask_generating then
                vim.cmd.startinsert()
            end
        end
    end)
    return true
end

--- Hide pinned implement prompt UI without ending the session (WinClosed pin handler cleared first).
---@param sess phantom-code.ExpandSession
---@param session_id integer
---@return boolean
local function hide_implement_prompt_ui(sess, session_id)
    if not sess.instruction_prompt_buf or not api.nvim_buf_is_valid(sess.instruction_prompt_buf) then
        return false
    end
    if not sess.prompt_win or not api.nvim_win_is_valid(sess.prompt_win) then
        return false
    end
    if sess.instruction_prompt_augroup then
        pcall(api.nvim_del_augroup_by_id, sess.instruction_prompt_augroup)
        sess.instruction_prompt_augroup = nil
    end
    pcall(api.nvim_win_close, sess.prompt_win, true)
    sess.prompt_win = nil
    sess.ui_layout = nil
    sess.prompt_below_selection = nil
    if instruction_win and session_id == instruction_session_id then
        instruction_win = nil
        instruction_session_id = nil
    end
    set_collapsed_marker(sess)
    return true
end

--- Reopen pinned implement prompt after hide_implement_prompt_ui().
---@param session_id integer
---@return boolean
local function reopen_implement_prompt_win(session_id)
    local sess = sessions[session_id]
    if not sess or sess.mode ~= 'implement' then
        return false
    end
    if not sess.instruction_prompt_buf or not api.nvim_buf_is_valid(sess.instruction_prompt_buf) then
        return false
    end
    if sess.prompt_win then
        if api.nvim_win_is_valid(sess.prompt_win) then
            return false
        end
        sess.prompt_win = nil
    end
    local cfg_mod = require('phantom-code').config
    local ui = cfg_mod.expand.ui or {}
    local w = ui.prompt_width or 72
    local buf = sess.instruction_prompt_buf
    local line_count = api.nvim_buf_line_count(buf)
    local max_h = ui.prompt_height or 10
    local h = math.max(1, math.min(line_count, max_h))
    local r = sess.range
    local km = cfg_mod.expand.keymap or {}
    local base = sess.implement_prompt_title or 'Expand'
    local title, footer
    if sess.state == 'generating' then
        title = ' ' .. base .. ' · generating… '
        local dismiss_l = utils.keymap_footer_label(km.dismiss)
        local focus_l = utils.keymap_footer_label(km.focus_window)
        footer = string.format(' waiting for model · %s cancel · %s focus ', dismiss_l, focus_l)
    elseif sess.state == 'review' then
        title = ' ' .. base .. ' · review '
        footer = string.format(
            ' use keys on code buffer · %s accept · %s dismiss · %s revise ',
            utils.keymap_footer_label(km.accept),
            utils.keymap_footer_label(km.dismiss),
            utils.keymap_footer_label(km.revise)
        )
    else
        title = ' ' .. base .. ' '
        footer = implement_instruction_footer(km)
    end

    local win_cfg, anchor_row_off = anchored_win_config(r.bufnr, r.sr, r.sc, w, h)
    sess.prompt_below_selection = anchor_row_off ~= nil and anchor_row_off < h + 1
    local ok, opened = pcall(api.nvim_open_win, buf, true, win_cfg)
    local win
    if ok and opened then
        win = opened
        sess.prompt_win = win
        sess.ui_layout = 'float'
        update_implement_prompt_chrome(sess, title, footer)
    end

    if not win or not api.nvim_win_is_valid(win) then
        return false
    end

    instruction_win = win
    instruction_session_id = session_id
    local pin_au = api.nvim_create_augroup('PhantomCodeExpandPromptPin' .. tostring(session_id), { clear = true })
    sess.instruction_prompt_augroup = pin_au
    api.nvim_create_autocmd('WinClosed', {
        group = pin_au,
        callback = function(args)
            if tonumber(args.match) == win then
                vim.schedule(function()
                    if sessions[session_id] and not api.nvim_win_is_valid(win) then
                        destroy_session(session_id)
                    end
                end)
            end
        end,
    })
    if sess.state == 'review' and cfg_mod.expand.inline_diff.enable ~= false and sess.proposed_text and r then
        reposition_prompt_after_diff(sess)
    end
    clear_collapsed_marker(sess)
    sync_implement_code_buffer_keymaps(session_id)

    return true
end

--- Leave ask / instruction float and return to the source code window.
---@return boolean true if the current window was an expand UI window
function M.unfocus_window()
    local w = api.nvim_get_current_win()
    local function jump_to_source(bufnr)
        if not bufnr or not api.nvim_buf_is_valid(bufnr) then
            return
        end
        local tw = vim.fn.bufwinid(bufnr)
        if tw ~= -1 then
            api.nvim_set_current_win(tw)
        else
            pcall(api.nvim_set_current_buf, bufnr)
        end
    end
    for _, sess in pairs(sessions) do
        if sess.ask_win and sess.ask_win == w and api.nvim_win_is_valid(w) then
            jump_to_source(sess.bufnr)
            pcall(vim.cmd, 'stopinsert')
            return true
        end
        if sess.prompt_win and sess.prompt_win == w and api.nvim_win_is_valid(w) then
            jump_to_source(sess.bufnr)
            pcall(vim.cmd, 'stopinsert')
            sync_implement_code_buffer_keymaps(sess.id)
            return true
        end
    end
    return false
end

--- Focus the nearest expand UI (ask or instruction). Reopens a hidden ask float if needed.
function M.focus_nearest_window()
    local cfg = require('phantom-code').config
    if not cfg.expand or cfg.expand.enable == false then
        return
    end
    local curbuf = api.nvim_get_current_buf()
    local ordered = {}
    for id, s in pairs(sessions) do
        ordered[#ordered + 1] = { id, s }
    end
    table.sort(ordered, function(a, b)
        return a[1] < b[1]
    end)

    ---@return boolean
    local function focus_ask(sess, win)
        if not sess.ask_buf or not api.nvim_buf_is_valid(sess.ask_buf) then
            return false
        end
        api.nvim_set_current_win(win)
        local last = api.nvim_buf_line_count(sess.ask_buf)
        api.nvim_win_set_cursor(win, { last, 0 })
        if not sess.ask_generating then
            vim.cmd.startinsert()
        end
        return true
    end

    ---@param id integer
    ---@param sess phantom-code.ExpandSession
    ---@return boolean
    local function try_session(id, sess)
        if sess.mode == 'ask' then
            if sess.ask_win and api.nvim_win_is_valid(sess.ask_win) then
                return focus_ask(sess, sess.ask_win)
            end
            return reopen_ask_float(id)
        end
        if sess.mode == 'implement' then
            if sess.prompt_win and api.nvim_win_is_valid(sess.prompt_win) then
                sync_implement_code_buffer_keymaps(id)
                api.nvim_set_current_win(sess.prompt_win)
                local pb = sess.instruction_prompt_buf
                if pb and api.nvim_buf_is_valid(pb) then
                    local lc = api.nvim_buf_line_count(pb)
                    api.nvim_win_set_cursor(sess.prompt_win, { math.max(1, lc), 0 })
                end
                vim.cmd.startinsert()
                return true
            end
            if sess.instruction_prompt_buf and api.nvim_buf_is_valid(sess.instruction_prompt_buf) then
                if reopen_implement_prompt_win(id) then
                    sess.prompt_hidden = false
                    api.nvim_set_current_win(sess.prompt_win)
                    local pb = sess.instruction_prompt_buf
                    if pb and api.nvim_buf_is_valid(pb) then
                        local lc = api.nvim_buf_line_count(pb)
                        api.nvim_win_set_cursor(sess.prompt_win, { math.max(1, lc), 0 })
                    end
                    if sess.state ~= 'generating' then
                        vim.cmd.startinsert()
                    end
                    return true
                end
            end
        end
        return false
    end

    for _, e in ipairs(ordered) do
        local id, sess = e[1], e[2]
        if sess.bufnr == curbuf and try_session(id, sess) then
            return
        end
    end
    for _, e in ipairs(ordered) do
        local id, sess = e[1], e[2]
        if try_session(id, sess) then
            return
        end
    end
    vim.notify('phantom-code Expand: no expand window to focus', vim.log.levels.INFO)
end

--- Open ask UI float; buffer holds transcript + editable draft tail.
---@param session_id integer
local function open_ask_float(session_id)
    local cfg = require('phantom-code').config
    local ui = cfg.expand.ui or {}
    local w = ui.ask_width or 80
    local max_ask_h = ui.ask_height or 16
    local sess = sessions[session_id]
    local r = sess.range

    local buf = api.nvim_create_buf(false, false)
    sess.ask_buf = buf
    ask_render_transcript(sess, false)
    local line_count = api.nvim_buf_line_count(buf)
    local h = math.max(1, math.min(line_count, max_ask_h))
    api.nvim_buf_set_option(buf, 'bufhidden', 'hide')
    api.nvim_buf_set_option(buf, 'swapfile', false)
    local base_dir = vim.fn.fnamemodify(
        (api.nvim_buf_get_name(r.bufnr) ~= '' and api.nvim_buf_get_name(r.bufnr)) or vim.fn.getcwd(),
        ':p:h'
    )
    pcall(api.nvim_buf_set_name, buf, vim.fs.joinpath(base_dir, '.phantom-expand-ask.' .. tostring(session_id)))
    api.nvim_buf_set_option(buf, 'buftype', '')
    api.nvim_buf_set_option(buf, 'buflisted', false)
    api.nvim_buf_set_option(buf, 'filetype', 'markdown')
    api.nvim_buf_set_var(buf, 'phantom_code_virtual_text_auto_trigger', false)
    api.nvim_buf_set_var(buf, 'phantom_code_expand_prompt', true)

    local km = cfg.expand.keymap or {}
    local footer_text = ' ' .. vim.trim(implement_instruction_footer(km)) .. ' '
    sess.ask_footer_default = footer_text

    local win_cfg, ask_anchor_row_off = anchored_win_config(r.bufnr, r.sr, r.sc, w, h)
    win_cfg.title = ' Expand ask '
    win_cfg.title_pos = 'center'
    win_cfg.footer = footer_text
    win_cfg.footer_pos = 'center'
    local win = api.nvim_open_win(buf, true, win_cfg)
    sess.ask_win = win
    sess.ui_layout = 'float'

    set_ask_float_chrome(sess, false)

    local ask_augroup = api.nvim_create_augroup('PhantomCodeAskResize' .. tostring(session_id), { clear = true })
    sess.ask_resize_augroup = ask_augroup

    api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
        group = ask_augroup,
        buffer = buf,
        callback = function()
            if not sess.ask_win or not api.nvim_win_is_valid(sess.ask_win) then
                return
            end
            local lc = api.nvim_buf_line_count(buf)
            local new_h = math.max(1, math.min(lc, max_ask_h))
            local ok, cur_cfg = pcall(api.nvim_win_get_config, sess.ask_win)
            if ok and cur_cfg.height ~= new_h then
                cur_cfg.height = new_h
                if ask_anchor_row_off then
                    if ask_anchor_row_off >= new_h + 1 then
                        cur_cfg.row = ask_anchor_row_off - new_h - 1
                    else
                        local src_win = vim.fn.bufwinid(r.bufnr)
                        if src_win == -1 or not api.nvim_win_is_valid(src_win) then
                            return
                        end
                        local wh = api.nvim_win_get_height(src_win)
                        cur_cfg.row = math.min(ask_anchor_row_off + 1, math.max(0, wh - new_h - 1))
                    end
                end
                pcall(api.nvim_win_set_config, sess.ask_win, cur_cfg)
            end
        end,
    })

    local function submit_ask_question()
        local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
        local q = vim.trim(table.concat(lines, '\n'))
        if q == '' or q == ASK_WAITING_BUFFER_TEXT then
            return
        end
        table.insert(sess.ask_messages, { role = 'user', content = q })
        ask_render_transcript(sess, true)
        api.nvim_buf_set_option(buf, 'modifiable', false)
        set_ask_float_chrome(sess, true)
        vim.notify('phantom-code Expand ask: question sent — waiting for the assistant', vim.log.levels.INFO)
        run_ask_request(sess, session_id)
        pcall(vim.cmd, 'stopinsert')
        if sess.bufnr and api.nvim_buf_is_valid(sess.bufnr) then
            local tw = vim.fn.bufwinid(sess.bufnr)
            if tw ~= -1 then
                api.nvim_set_current_win(tw)
            end
        end
    end

    bind_prompt_submit_keys(buf, submit_ask_question, '[phantom-code.expand] ask submit')
    bind_expand_window_aux(buf, session_id)

    vim.schedule(function()
        if win and api.nvim_win_is_valid(win) then
            api.nvim_set_current_win(win)
            local last = api.nvim_buf_line_count(buf)
            api.nvim_win_set_cursor(win, { last, 0 })
            vim.cmd.startinsert()
        end
    end)
end

---@param cfg table
---@return 'float'|'input'
local function resolve_expand_prompt_ui(cfg)
    local v = cfg.expand.prompt_ui
    if v == 'input' or v == 'float' then
        return v
    end
    if v ~= nil then
        vim.notify('phantom-code Expand: unknown expand.prompt_ui, using float', vim.log.levels.WARN)
    end
    return 'float'
end

local function order_visual_endpoints(s, e, region_type)
    if region_type == 'V' then
        if s[2] > e[2] then
            return e, s
        end
        return s, e
    end
    if s[2] > e[2] or (s[2] == e[2] and s[3] > e[3]) then
        return e, s
    end
    return s, e
end

--- Normal mode: empty selection at cursor (generate-at-cursor).
---@return { bufnr: integer, sr: integer, sc: integer, er: integer, ec: integer, text: string }|nil
local function get_empty_selection_at_cursor()
    if vim.fn.mode() ~= 'n' then
        return nil
    end
    local bufnr = api.nvim_get_current_buf()
    local cur = api.nvim_win_get_cursor(0)
    local row1, col0 = cur[1], cur[2]
    local row0 = row1 - 1
    return { bufnr = bufnr, sr = row0, sc = col0, er = row0, ec = col0, text = '' }
end

---@return { bufnr: integer, sr: integer, sc: integer, er: integer, ec: integer, text: string }|nil
local function get_visual_range()
    local bufnr = api.nvim_get_current_buf()
    local m = vim.fn.mode(1)
    local s, e
    local region_type

    if m == 'v' or m == 'V' or m == '\022' then
        if m == '\022' then
            vim.notify('phantom-code Expand does not support blockwise visual yet', vim.log.levels.WARN)
            return nil
        end
        s = vim.fn.getpos 'v'
        e = vim.fn.getpos '.'
        region_type = m
    elseif m == 's' or m == 'S' then
        s = vim.fn.getpos 'v'
        e = vim.fn.getpos '.'
        region_type = (m == 'S') and 'V' or 'v'
    else
        s = vim.fn.getpos "'<"
        e = vim.fn.getpos "'>"
        if s[2] == 0 or e[2] == 0 then
            return nil
        end
        region_type = vim.fn.visualmode()
        if region_type == '' then
            region_type = 'v'
        end
        if region_type == '\022' then
            vim.notify('phantom-code Expand does not support blockwise visual yet', vim.log.levels.WARN)
            return nil
        end
    end

    if s[2] == 0 or e[2] == 0 then
        return nil
    end

    local ok, reg = pcall(vim.fn.getregion, s, e, { type = region_type })
    local text
    if ok and reg and #reg > 0 then
        text = table.concat(reg, '\n')
    end
    if not text or text == '' then
        return nil
    end

    s, e = order_visual_endpoints(s, e, region_type)

    local sr, er = s[2] - 1, e[2] - 1
    local sc, ec = s[3] - 1, e[3]
    if region_type == 'V' then
        sc = 0
        local last_line = api.nvim_buf_get_lines(bufnr, er, er + 1, false)[1] or ''
        ec = #last_line
    end

    return { bufnr = bufnr, sr = sr, sc = sc, er = er, ec = ec, text = text }
end

---@param opts? { mode?: 'implement'|'ask' }
function M.invoke(opts)
    opts = opts or {}
    local mode = opts.mode or 'implement'
    local cfg = require('phantom-code').config
    if not cfg.expand.enable then
        vim.notify('phantom-code Expand is disabled (expand.enable = false)', vim.log.levels.INFO)
        return
    end

    if instruction_win and api.nvim_win_is_valid(instruction_win) then
        vim.notify('phantom-code Expand: finish or cancel the open float first', vim.log.levels.WARN)
        return
    end

    local r = get_visual_range()
    if not r then
        r = get_empty_selection_at_cursor()
    end
    if not r then
        vim.notify(
            'phantom-code Expand: select in visual mode, or use normal mode at the cursor to generate',
            vim.log.levels.WARN
        )
        return
    end

    local resolved = utils.resolve_provider_config 'expand'
    if not utils.provider_supports_expand_chat(resolved.provider) then
        vim.notify(
            'phantom-code Expand needs a chat provider (e.g. openai_compatible, claude, openai). Set expand.provider.',
            vim.log.levels.ERROR
        )
        return
    end

    if not utils.get_api_key(resolved.options.api_key) then
        vim.notify('phantom-code Expand: API key not set for provider ' .. resolved.provider, vim.log.levels.ERROR)
        return
    end

    local cancel_inflight = cfg.expand.cancel_inflight ~= false
    if cancel_inflight then
        dismiss_all()
    end

    local session_id, sess = create_session(r, mode)

    if mode == 'ask' then
        vim.schedule(function()
            open_ask_float(session_id)
        end)
        return
    end

    local disp = vim.fn.fnamemodify(api.nvim_buf_get_name(r.bufnr) or '', ':.')
    if disp == '' then
        disp = '[No Name]'
    end
    local title = r.text == '' and (' Expand (cursor, ' .. disp .. ') ')
        or string.format(' Expand (%d lines, %s) ', #vim.split(r.text, '\n', { plain = true }), disp)

    vim.schedule(function()
        if resolve_expand_prompt_ui(cfg) == 'input' then
            vim.ui.input({ prompt = 'Expand instruction: ' }, function(instruction)
                if not instruction or instruction == '' then
                    destroy_session(session_id)
                    return
                end
                run_implement_request(sess, session_id, instruction)
            end)
        else
            show_multiline_prompt(r.bufnr, session_id, title, nil, function(instruction)
                if not instruction or instruction == '' then
                    destroy_session(session_id)
                    return
                end
                run_implement_request(sess, session_id, instruction)
            end, { keep_open_after_submit = true })
        end
    end)
end

function M.invoke_ask()
    M.invoke { mode = 'ask' }
end

---@param ask_sid integer
---@param ask_sess phantom-code.ExpandSession
---@return boolean
local function toggle_ask_session(ask_sid, ask_sess)
    if not ask_sess then
        return false
    end
    if ask_sess.ask_win and api.nvim_win_is_valid(ask_sess.ask_win) then
        pcall(vim.cmd, 'stopinsert')
        close_ask_ui(ask_sess)
        ask_sess.ask_hidden = true
        set_collapsed_marker(ask_sess)
        if ask_sess.bufnr and api.nvim_buf_is_valid(ask_sess.bufnr) then
            local tw = vim.fn.bufwinid(ask_sess.bufnr)
            if tw ~= -1 then
                api.nvim_set_current_win(tw)
            end
        end
        return true
    end
    if reopen_ask_float(ask_sid) then
        return true
    end
    if ask_sess.ask_buf and api.nvim_buf_is_valid(ask_sess.ask_buf) then
        return false
    end
    destroy_session(ask_sid)
    return false
end

--- Toggle the ask float: if visible hide it, if hidden reopen it, if none exists do nothing.
function M.ask_toggle()
    for id, s in pairs(sessions) do
        if s.mode == 'ask' then
            return toggle_ask_session(id, s)
        end
    end
    return false
end

--- Hide or show expand UI: pinned implement prompt (after submit), or ask float. Prefers session for the current buffer.
function M.toggle_expand_window_view()
    local cfg = require('phantom-code').config
    if not cfg.expand or cfg.expand.enable == false then
        return
    end
    local curbuf = api.nvim_get_current_buf()
    local ordered = {}
    for id, s in pairs(sessions) do
        ordered[#ordered + 1] = { id, s }
    end
    table.sort(ordered, function(a, b)
        return a[1] < b[1]
    end)

    ---@param id integer
    ---@param sess phantom-code.ExpandSession
    ---@return boolean
    local function try_implement(id, sess)
        if sess.mode ~= 'implement' then
            return false
        end
        if not sess.instruction_prompt_buf or not api.nvim_buf_is_valid(sess.instruction_prompt_buf) then
            return false
        end
        if sess.prompt_win and api.nvim_win_is_valid(sess.prompt_win) then
            if not hide_implement_prompt_ui(sess, id) then
                return false
            end
            sess.prompt_hidden = true
            pcall(vim.cmd, 'stopinsert')
            if sess.bufnr and api.nvim_buf_is_valid(sess.bufnr) then
                local tw = vim.fn.bufwinid(sess.bufnr)
                if tw ~= -1 then
                    api.nvim_set_current_win(tw)
                end
            end
            sync_implement_code_buffer_keymaps(id)
            return true
        end
        if reopen_implement_prompt_win(id) then
            sess.prompt_hidden = false
            return true
        end
        return false
    end

    for _, e in ipairs(ordered) do
        local id, sess = e[1], e[2]
        if sess.bufnr == curbuf and try_implement(id, sess) then
            return
        end
    end
    for _, e in ipairs(ordered) do
        local id, sess = e[1], e[2]
        if sess.bufnr == curbuf and sess.mode == 'ask' and toggle_ask_session(id, sess) then
            return
        end
    end
    for _, e in ipairs(ordered) do
        if try_implement(e[1], e[2]) then
            return
        end
    end
    for _, e in ipairs(ordered) do
        if e[2].mode == 'ask' and toggle_ask_session(e[1], e[2]) then
            return
        end
    end
    vim.notify('phantom-code Expand: no expand window to toggle', vim.log.levels.INFO)
end

--- Dismiss any active ask session.
function M.ask_dismiss()
    for id, s in pairs(sessions) do
        if s.mode == 'ask' then
            destroy_session(id)
            return
        end
    end
end

---@param session_id? integer
function M.dismiss(session_id)
    if session_id ~= nil then
        destroy_session(session_id)
        return
    end
    dismiss_all()
end

---@param session_id? integer
function M.accept(session_id)
    if session_id == nil then
        local candidates = {}
        for id, s in pairs(sessions) do
            if s.mode == 'implement' and s.state == 'review' and s.proposed_text and s.range then
                candidates[#candidates + 1] = id
            end
        end
        if #candidates == 0 then
            return
        end
        if #candidates > 1 then
            table.sort(candidates)
            session_id = candidates[#candidates]
        else
            session_id = candidates[1]
        end
    end

    local sess = sessions[session_id]
    if not sess or sess.mode ~= 'implement' or sess.state ~= 'review' then
        return
    end
    local r = sess.range
    local text = sess.proposed_text
    if not r or not text or not api.nvim_buf_is_valid(r.bufnr) then
        return
    end

    local ok_rng, rng_err = range_matches_buffer(r)
    if not ok_rng then
        vim.notify('phantom-code Expand: accept aborted — ' .. (rng_err or 'range mismatch'), vim.log.levels.WARN)
        return
    end

    local lines = vim.split(text, '\n', { plain = true })
    -- Single undo step: rely on nvim_buf_set_text’s own undo block; avoid undojoin
    -- (it can merge this edit with an unrelated prior change).
    local ok_set, set_err = pcall(api.nvim_buf_set_text, r.bufnr, r.sr, r.sc, r.er, r.ec, lines)
    if not ok_set then
        vim.notify(
            'phantom-code Expand: could not apply edit (' .. tostring(set_err) .. ')',
            vim.log.levels.ERROR
        )
        return
    end

    unmap_review_keys(sess)
    clear_collapsed_marker(sess)
    expand_inline_diff.clear(r.bufnr)
    close_prompt_win(sess)
    sessions[session_id] = nil
    vim.notify('phantom-code Expand: applied', vim.log.levels.INFO)
end

---@param session_id? integer
function M.revise(session_id)
    if session_id == nil then
        local candidates = {}
        for id, s in pairs(sessions) do
            if s.mode == 'implement' and s.state == 'review' and s.proposed_text and s.range then
                candidates[#candidates + 1] = id
            end
        end
        if #candidates == 0 then
            return
        end
        if #candidates > 1 then
            table.sort(candidates)
            session_id = candidates[#candidates]
        else
            session_id = candidates[1]
        end
    end

    local sess = sessions[session_id]
    if not sess or sess.mode ~= 'implement' then
        return
    end
    if sess.state ~= 'review' then
        return
    end
    close_prompt_win(sess)
    unmap_review_keys(sess)
    local prev_proposed = sess.proposed_text
    sess.proposed_text = nil
    sess.state = 'prompt'

    local cfg = require('phantom-code').config
    local r = sess.range
    vim.schedule(function()
        if resolve_expand_prompt_ui(cfg) == 'input' then
            vim.ui.input({ prompt = 'Expand (revise): ' }, function(instruction)
                if not instruction or instruction == '' then
                    sess.state = 'review'
                    sess.proposed_text = prev_proposed
                    if sess.proposed_text and cfg.expand.inline_diff.enable ~= false then
                        expand_inline_diff.render(r.bufnr, r.sr, r.er, r.text, sess.proposed_text)
                    end
                    sync_implement_code_buffer_keymaps(session_id)
                    return
                end
                run_implement_request(sess, session_id, instruction)
            end)
        else
            show_multiline_prompt(r.bufnr, session_id, ' Expand (revise) ', nil, function(instruction)
                if not instruction or instruction == '' then
                    sess.state = 'review'
                    sess.proposed_text = prev_proposed
                    if sess.proposed_text and cfg.expand.inline_diff.enable ~= false then
                        expand_inline_diff.render(r.bufnr, r.sr, r.er, r.text, sess.proposed_text)
                    end
                    sync_implement_code_buffer_keymaps(session_id)
                    return
                end
                run_implement_request(sess, session_id, instruction)
            end, { keep_open_after_submit = true })
        end
    end)
end

function M.setup()
    local cfg = require('phantom-code').config
    if not cfg.expand.enable then
        return
    end
    hl_expand()
    local km = cfg.expand.keymap or {}
    if km.invoke then
        vim.keymap.set(INVOKE_KEYMAP_MODES, km.invoke, function()
            M.invoke { mode = 'implement' }
        end, {
            desc = '[phantom-code.expand] invoke',
            silent = true,
        })
    end
    if km.ask then
        vim.keymap.set(INVOKE_KEYMAP_MODES, km.ask, function()
            if not M.ask_toggle() then
                M.invoke_ask()
            end
        end, {
            desc = '[phantom-code.expand] ask / toggle',
            silent = true,
        })
    end
    if km.focus_window then
        vim.keymap.set('n', km.focus_window, function()
            if not M.unfocus_window() then
                M.focus_nearest_window()
            end
        end, {
            desc = '[phantom-code.expand] toggle focus expand window',
            silent = true,
        })
    end
    if km.toggle_window and km.toggle_window ~= '' then
        vim.keymap.set('n', km.toggle_window, function()
            M.toggle_expand_window_view()
        end, {
            desc = '[phantom-code.expand] toggle expand window visibility',
            silent = true,
        })
    end
end

return M
