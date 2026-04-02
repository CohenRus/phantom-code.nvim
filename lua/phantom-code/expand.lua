local api = vim.api
local utils = require 'phantom-code.utils'

local M = {}

local ns = api.nvim_create_namespace 'phantom-code.expand'
--- Preview accept/dismiss on source buffer (inline preview only): normal + insert.
local PREVIEW_KEYMAP_MODES = { 'n', 'i' }
--- Invoke: normal (last visual marks) + visual.
local INVOKE_KEYMAP_MODES = { 'n', 'v' }

---@class phantom-code.ExpandSession
---@field id integer
---@field bufnr integer
---@field range { bufnr: integer, sr: integer, sc: integer, er: integer, ec: integer, text: string }
---@field pulse_timer userdata|nil
---@field pulse_extmark_id integer|nil
---@field generating_instruction string|nil
---@field preview_extmark_id integer|nil
---@field response string|nil
---@field float_win integer|nil
---@field float_buf integer|nil
---@field preview_keymap_buf integer|nil
---@field source_preview_keymap_buf integer|nil
---@field keymap_accept string|nil
---@field keymap_dismiss string|nil
---@field awaiting_instruction boolean|nil

---@type table<integer, phantom-code.ExpandSession>
local sessions = {}
local next_session_id = 1

--- Instruction float (only one at a time).
local instruction_win = nil
--- Session id for the open instruction float, if any.
local instruction_session_id = nil

local function hl_expand()
    if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'PhantomCodeExpandPulse1' })) then
        api.nvim_set_hl(0, 'PhantomCodeExpandPulse1', { link = 'Comment' })
    end
    if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'PhantomCodeExpandPulse2' })) then
        api.nvim_set_hl(0, 'PhantomCodeExpandPulse2', { link = 'Special' })
    end
    if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'PhantomCodeExpandPreview' })) then
        api.nvim_set_hl(0, 'PhantomCodeExpandPreview', { link = 'PhantomCodeVirtualText' })
    end
    if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'PhantomCodeExpandGenBar' })) then
        api.nvim_set_hl(0, 'PhantomCodeExpandGenBar', { default = true, link = 'Pmenu' })
    end
    if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'PhantomCodeExpandGenLabel' })) then
        api.nvim_set_hl(0, 'PhantomCodeExpandGenLabel', { default = true, link = 'Title' })
    end
    if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'PhantomCodeExpandGenPrompt' })) then
        api.nvim_set_hl(0, 'PhantomCodeExpandGenPrompt', { default = true, link = 'Special' })
    end
    if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'PhantomCodeExpandGenAccent' })) then
        api.nvim_set_hl(0, 'PhantomCodeExpandGenAccent', { default = true, link = 'DiagnosticInfo' })
    end
end

---@param sess phantom-code.ExpandSession
local function stop_pulse(sess)
    if sess.pulse_timer and not sess.pulse_timer:is_closing() then
        sess.pulse_timer:stop()
        sess.pulse_timer:close()
    end
    sess.pulse_timer = nil
    sess.generating_instruction = nil
end

---@param sess phantom-code.ExpandSession
local function clear_expand_extmarks(sess)
    local bufnr = sess.bufnr
    if not bufnr or not api.nvim_buf_is_valid(bufnr) then
        return
    end
    if sess.pulse_extmark_id then
        pcall(api.nvim_buf_del_extmark, bufnr, ns, sess.pulse_extmark_id)
        sess.pulse_extmark_id = nil
    end
    if sess.preview_extmark_id then
        pcall(api.nvim_buf_del_extmark, bufnr, ns, sess.preview_extmark_id)
        sess.preview_extmark_id = nil
    end
end

---@param sess phantom-code.ExpandSession
local function unmap_preview_keys(sess)
    local bufs = {}
    if sess.preview_keymap_buf then
        bufs[#bufs + 1] = sess.preview_keymap_buf
    end
    if sess.source_preview_keymap_buf then
        bufs[#bufs + 1] = sess.source_preview_keymap_buf
    end
    for _, buf in ipairs(bufs) do
        if api.nvim_buf_is_valid(buf) then
            for _, mode in ipairs(PREVIEW_KEYMAP_MODES) do
                if sess.keymap_accept then
                    pcall(vim.keymap.del, mode, sess.keymap_accept, { buffer = buf })
                end
                if sess.keymap_dismiss then
                    pcall(vim.keymap.del, mode, sess.keymap_dismiss, { buffer = buf })
                end
            end
        end
    end
    sess.preview_keymap_buf = nil
    sess.source_preview_keymap_buf = nil
    sess.keymap_accept = nil
    sess.keymap_dismiss = nil
end

---@param sess phantom-code.ExpandSession
local function close_session_preview_float(sess)
    if sess.float_win and api.nvim_win_is_valid(sess.float_win) then
        api.nvim_win_close(sess.float_win, true)
    end
    sess.float_win = nil
    sess.float_buf = nil
end

---@param r { bufnr: integer, sr: integer, sc: integer, er: integer, ec: integer, text: string }
---@return integer, phantom-code.ExpandSession
local function create_session(r)
    local id = next_session_id
    next_session_id = next_session_id + 1
    ---@type phantom-code.ExpandSession
    local sess = {
        id = id,
        bufnr = r.bufnr,
        range = r,
        pulse_timer = nil,
        pulse_extmark_id = nil,
        preview_extmark_id = nil,
        generating_instruction = nil,
        response = nil,
        float_win = nil,
        float_buf = nil,
        preview_keymap_buf = nil,
        source_preview_keymap_buf = nil,
        keymap_accept = nil,
        keymap_dismiss = nil,
        awaiting_instruction = true,
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
    stop_pulse(sess)
    if id == instruction_session_id and instruction_win and api.nvim_win_is_valid(instruction_win) then
        pcall(api.nvim_win_close, instruction_win, true)
        instruction_win = nil
        instruction_session_id = nil
    end
    close_session_preview_float(sess)
    unmap_preview_keys(sess)
    clear_expand_extmarks(sess)
    sessions[id] = nil
end

--- Truncate `s` so display width is at most `max_w` (adds … when trimmed).
---@param s string
---@param max_w integer
---@return string
local function truncate_display_width(s, max_w)
    if max_w < 2 then
        return ''
    end
    if vim.fn.strdisplaywidth(s) <= max_w then
        return s
    end
    local ellipsis = '…'
    local ell_w = vim.fn.strdisplaywidth(ellipsis)
    local budget = max_w - ell_w
    if budget < 1 then
        return ellipsis
    end
    local acc = ''
    local i = 0
    while true do
        local ch = vim.fn.strcharpart(s, i, 1)
        if ch == '' then
            break
        end
        local next_acc = acc .. ch
        if vim.fn.strdisplaywidth(next_acc) > budget then
            break
        end
        acc = next_acc
        i = i + 1
    end
    return acc .. ellipsis
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
end

---@param sess phantom-code.ExpandSession
---@param bufnr integer
---@param sr integer
---@param sc integer
---@param instruction string
local function start_pulse(sess, bufnr, sr, sc, instruction)
    hl_expand()
    instruction = vim.trim(instruction or ''):gsub('%s+', ' ')
    if instruction == '' then
        instruction = '(no instruction)'
    end
    sess.generating_instruction = instruction
    local sid = sess.id
    vim.schedule(function()
        if sessions[sid] ~= sess then
            return
        end
        if not api.nvim_buf_is_valid(bufnr) then
            return
        end
        local cols = math.max(32, vim.o.columns or 80) - 8
        local prompt_snip = truncate_display_width(sess.generating_instruction or instruction, cols)
        local virt_line = {
            { '▌', 'PhantomCodeExpandGenAccent' },
            { '  ', 'PhantomCodeExpandGenBar' },
            { 'phantom-code expand  ', 'PhantomCodeExpandGenLabel' },
            { prompt_snip, 'PhantomCodeExpandGenPrompt' },
            { '  generating…', 'PhantomCodeExpandGenBar' },
        }
        local mark_sr, mark_sc = sr, sc
        local opts = {
            virt_lines_above = true,
            virt_lines = { virt_line },
            priority = 250,
        }
        if vim.fn.has 'nvim-0.10' == 1 then
            opts.virt_lines_leftcol = true
        else
            mark_sc = 0
        end
        if sess.pulse_extmark_id then
            opts.id = sess.pulse_extmark_id
        end
        local eid = api.nvim_buf_set_extmark(bufnr, ns, mark_sr, mark_sc, opts)
        if eid and eid > 0 and not sess.pulse_extmark_id then
            sess.pulse_extmark_id = eid
        end
    end)
end

---@param sess phantom-code.ExpandSession
---@param bufnr integer
---@param er integer
---@param ec integer
---@param lines string[]
local function show_preview_inline(sess, bufnr, er, ec, lines)
    hl_expand()
    if #lines == 0 then
        return
    end
    local ext = {
        virt_text = { { lines[1], 'PhantomCodeExpandPreview' } },
        virt_text_pos = 'inline',
        priority = 150,
    }
    if #lines > 1 then
        ext.virt_lines = {}
        for i = 2, #lines do
            ext.virt_lines[i - 1] = { { lines[i], 'PhantomCodeExpandPreview' } }
        end
    end
    local eid = api.nvim_buf_set_extmark(bufnr, ns, er, ec, ext)
    if eid and eid > 0 then
        sess.preview_extmark_id = eid
    end
end

--- Centered editor float; same geometry/style as Expand preview.
---@param buf integer
---@param opts { title: string, width?: integer, height?: integer, enter?: boolean, footer?: string }
---@return integer
local function open_expand_float(buf, opts)
    local w = opts.width or math.min(80, vim.o.columns - 4)
    local h = opts.height or math.min(20, vim.o.lines - 4)
    local win_cfg = {
        relative = 'editor',
        width = w,
        height = h,
        row = math.floor((vim.o.lines - h) / 2),
        col = math.floor((vim.o.columns - w) / 2),
        style = 'minimal',
        border = 'rounded',
        title = opts.title,
        title_pos = 'center',
    }
    if opts.footer then
        win_cfg.footer = opts.footer
        win_cfg.footer_pos = 'center'
    end
    return api.nvim_open_win(buf, opts.enter == true, win_cfg)
end

---@param sess phantom-code.ExpandSession
---@param text string
---@param session_id integer
---@param cfg table
local function show_preview_float(sess, text, session_id, cfg)
    close_session_preview_float(sess)
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, '\n'))
    api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
    local km = cfg.expand.keymap or {}
    local function key_label(lhs)
        local ok, s = pcall(vim.fn.keytrans, lhs)
        return (ok and s and s ~= '') and s or lhs
    end
    local footer = ' preview '
    if km.accept then
        footer = footer .. key_label(km.accept) .. ' accept '
    end
    if km.dismiss then
        footer = footer .. '· ' .. key_label(km.dismiss) .. ' dismiss '
    end
    local win = open_expand_float(buf, { title = ' Expand preview ', enter = false, footer = footer })
    sess.float_win = win
    sess.float_buf = buf
    sess.preview_keymap_buf = buf
    if km.accept then
        sess.keymap_accept = km.accept
        vim.keymap.set(PREVIEW_KEYMAP_MODES, km.accept, function()
            M.accept(session_id)
        end, {
            buffer = buf,
            desc = '[phantom-code.expand] accept preview',
            silent = true,
        })
    end
    if km.dismiss then
        sess.keymap_dismiss = km.dismiss
        vim.keymap.set(PREVIEW_KEYMAP_MODES, km.dismiss, function()
            M.dismiss(session_id)
        end, {
            buffer = buf,
            desc = '[phantom-code.expand] dismiss preview',
            silent = true,
        })
    end
end

--- Duplicate float preview keys on the source buffer when only one expand runs at a time (default cancel_inflight).
---@param sess phantom-code.ExpandSession
---@param src_bufnr integer
---@param session_id integer
---@param km table
local function map_preview_keys_on_source(sess, src_bufnr, session_id, km)
    sess.source_preview_keymap_buf = src_bufnr
    if km.accept then
        vim.keymap.set(PREVIEW_KEYMAP_MODES, km.accept, function()
            M.accept(session_id)
        end, {
            buffer = src_bufnr,
            desc = '[phantom-code.expand] accept preview',
            silent = true,
        })
    end
    if km.dismiss then
        vim.keymap.set(PREVIEW_KEYMAP_MODES, km.dismiss, function()
            M.dismiss(session_id)
        end, {
            buffer = src_bufnr,
            desc = '[phantom-code.expand] dismiss preview',
            silent = true,
        })
    end
end

--- Single-line instruction in a float. Calls on_done(trimmed_line_or_nil).
---@param target_bufnr integer
---@param session_id integer
---@param on_done fun(instruction: string|nil)
local function show_instruction_float(target_bufnr, session_id, on_done)
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(buf, 0, -1, false, { '' })
    api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
    api.nvim_buf_set_option(buf, 'buftype', 'nofile')
    api.nvim_buf_set_option(buf, 'swapfile', false)

    local done = false
    local augroup = api.nvim_create_augroup('PhantomCodeExpandInstruction' .. tostring(session_id), { clear = true })

    local function finish(value)
        if done then
            return
        end
        done = true
        pcall(api.nvim_del_augroup_by_id, augroup)
        if instruction_win and api.nvim_win_is_valid(instruction_win) then
            pcall(api.nvim_win_close, instruction_win, true)
        end
        instruction_win = nil
        instruction_session_id = nil
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

    local win = open_expand_float(buf, {
        title = ' Expand instruction ',
        width = math.min(80, vim.o.columns - 4),
        height = 1,
        enter = true,
        footer = ' <CR> confirm · <Esc> cancel ',
    })
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

    vim.keymap.set({ 'i', 'n' }, '<CR>', function()
        local lines = api.nvim_buf_get_lines(buf, 0, 1, false)
        local text = vim.trim(lines[1] or '')
        finish(text)
    end, { buffer = buf, silent = true, desc = '[phantom-code.expand] submit instruction' })

    vim.keymap.set({ 'i', 'n' }, '<Esc>', function()
        finish(nil)
    end, { buffer = buf, silent = true, desc = '[phantom-code.expand] cancel instruction' })

    vim.keymap.set('i', '<C-c>', function()
        finish(nil)
    end, { buffer = buf, silent = true, desc = '[phantom-code.expand] cancel instruction' })

    vim.schedule(function()
        if api.nvim_win_is_valid(win) then
            api.nvim_set_current_win(win)
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

--- Normalize visual endpoints so `s` is before `e` in buffer order (for set_text range).
---@param s number[] getpos() vector
---@param e number[]
---@param region_type string
---@return number[] s
---@return number[] e
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
local function expand_system_text(cfg)
    local sys = cfg.expand.system
    if type(sys) == 'function' then
        return sys(cfg) or ''
    end
    return sys or ''
end

function M.invoke()
    local cfg = require('phantom-code').config
    if not cfg.expand.enable then
        vim.notify('phantom-code Expand is disabled (expand.enable = false)', vim.log.levels.INFO)
        return
    end

    if instruction_win and api.nvim_win_is_valid(instruction_win) then
        vim.notify('phantom-code Expand: finish or cancel the instruction prompt first', vim.log.levels.WARN)
        return
    end

    local r = get_visual_range()
    if not r then
        vim.notify('phantom-code Expand: select text in visual mode first', vim.log.levels.WARN)
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

    local session_id, sess = create_session(r)

    local function after_expand_instruction(instruction)
        sess.awaiting_instruction = false
        if not instruction or instruction == '' then
            destroy_session(session_id)
            return
        end

        if not api.nvim_buf_is_valid(r.bufnr) then
            destroy_session(session_id)
            return
        end

        start_pulse(sess, r.bufnr, r.sr, r.sc, instruction)

        local ctx_win = cfg.expand.context_window or cfg.context_window
        local ctx_ratio = cfg.expand.context_ratio or cfg.context_ratio
        local surround =
            utils.get_expand_file_surround(r.bufnr, r.sr, r.sc, r.er, r.ec, ctx_win, ctx_ratio)

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
            instruction = instruction,
            selectedCode = r.text,
            filePath = path,
            fileType = ft,
            fileContextBefore = surround.lines_before,
            fileContextAfter = surround.lines_after,
            diagnosticsBlock = diag_block,
        }

        local user_msg = fill_user_template(cfg, cfg.expand.user_template, vars)
        local system_text = expand_system_text(cfg)

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

        local request_timeout = cfg.expand.request_timeout
        local request_opts = {
            max_time = request_timeout,
            cancel_existing_expand_jobs = cancel_inflight,
            expand_session_id = session_id,
        }

        local function on_done(raw)
            vim.schedule(function()
                if sessions[session_id] ~= sess then
                    return
                end
                stop_pulse(sess)
                clear_expand_extmarks(sess)
                if not raw or raw == '' then
                    vim.notify('phantom-code Expand: empty response', vim.log.levels.WARN)
                    destroy_session(session_id)
                    return
                end
                local out = utils.strip_optional_code_fences(raw) or ''
                if cfg.expand.merge ~= false then
                    if type(cfg.expand.merge_fn) == 'function' then
                        local merged = cfg.expand.merge_fn(r.text, out, { bufnr = r.bufnr, start_row = r.sr })
                        if type(merged) == 'string' then
                            out = merged
                        end
                    else
                        out = utils.merge_expand_replacement(r.text, out, { bufnr = r.bufnr, start_row = r.sr })
                    end
                end
                sess.response = out
                vim.notify('phantom-code Expand: preview ready — accept or dismiss', vim.log.levels.INFO)

                if cfg.expand.preview == 'float' then
                    show_preview_float(sess, out, session_id, cfg)
                    if cancel_inflight then
                        map_preview_keys_on_source(sess, r.bufnr, session_id, cfg.expand.keymap or {})
                    end
                else
                    local preview_lines = vim.split(out, '\n', { plain = true })
                    show_preview_inline(sess, r.bufnr, r.er, r.ec, preview_lines)
                    if not cancel_inflight then
                        local others = 0
                        for _, s in pairs(sessions) do
                            if s.bufnr == r.bufnr and s.response and s.id ~= session_id then
                                others = others + 1
                            end
                        end
                        if others >= 1 then
                            vim.notify(
                                'phantom-code Expand: concurrent inline previews on the same buffer share accept/dismiss (last binding wins). Prefer expand.preview = "float".',
                                vim.log.levels.WARN
                            )
                        end
                    end
                    local km = cfg.expand.keymap or {}
                    if km.accept then
                        sess.keymap_accept = km.accept
                        sess.preview_keymap_buf = r.bufnr
                        vim.keymap.set(PREVIEW_KEYMAP_MODES, km.accept, function()
                            M.accept(session_id)
                        end, {
                            buffer = r.bufnr,
                            desc = '[phantom-code.expand] accept preview',
                            silent = true,
                        })
                    end
                    if km.dismiss then
                        sess.keymap_dismiss = km.dismiss
                        sess.preview_keymap_buf = r.bufnr
                        vim.keymap.set(PREVIEW_KEYMAP_MODES, km.dismiss, function()
                            M.dismiss(session_id)
                        end, {
                            buffer = r.bufnr,
                            desc = '[phantom-code.expand] dismiss preview',
                            silent = true,
                        })
                    end
                end
            end)
        end

        local mod = require('phantom-code.backends.' .. resolved.provider)
        if not mod.expand_chat then
            stop_pulse(sess)
            vim.notify('phantom-code Expand: backend has no expand_chat()', vim.log.levels.ERROR)
            destroy_session(session_id)
            return
        end

        if resolved.provider == 'claude' then
            local messages = {}
            if few then
                vim.list_extend(messages, few)
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
            table.insert(messages, { role = 'user', content = user_msg })
            mod.expand_chat(opts, messages, on_done, request_opts)
        end
    end

    vim.schedule(function()
        if resolve_expand_prompt_ui(cfg) == 'input' then
            vim.ui.input({ prompt = 'Expand instruction: ' }, function(instruction)
                sess.awaiting_instruction = false
                if not instruction or instruction == '' then
                    destroy_session(session_id)
                    return
                end
                after_expand_instruction(instruction)
            end)
        else
            show_instruction_float(r.bufnr, session_id, after_expand_instruction)
        end
    end)
end

---@param session_id? integer When nil, dismiss all expand state. Otherwise dismiss one session.
function M.dismiss(session_id)
    if session_id ~= nil then
        destroy_session(session_id)
        return
    end
    dismiss_all()
end

---@param session_id? integer When nil and multiple previews exist, accepts the most recently created session.
function M.accept(session_id)
    if session_id == nil then
        local candidates = {}
        for id, s in pairs(sessions) do
            if s.response and s.range then
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
    if not sess then
        return
    end
    local r = sess.range
    local text = sess.response
    if not r or not text or not api.nvim_buf_is_valid(r.bufnr) then
        return
    end

    local lines = vim.split(text, '\n', { plain = true })
    api.nvim_buf_set_text(r.bufnr, r.sr, r.sc, r.er, r.ec, lines)

    close_session_preview_float(sess)
    unmap_preview_keys(sess)
    clear_expand_extmarks(sess)
    stop_pulse(sess)
    sessions[session_id] = nil
    vim.notify('phantom-code Expand: applied', vim.log.levels.INFO)
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
            M.invoke()
        end, {
            desc = '[phantom-code.expand] invoke',
            silent = true,
        })
    end
end

return M
