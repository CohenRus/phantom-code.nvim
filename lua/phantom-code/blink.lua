local M = {}
local utils = require 'phantom-code.utils'

if vim.tbl_isempty(vim.api.nvim_get_hl(0, { name = 'BlinkCmpItemKindPhantomCode' })) then
    vim.api.nvim_set_hl(0, 'BlinkCmpItemKindPhantomCode', { link = 'BlinkCmpItemKind' })
end

function M.get_trigger_characters()
    return { '@', '.', '(', '[', ':', '{' }
end

function M:enabled()
    local config = require('phantom-code').config
    local resolved = utils.resolve_provider_config 'inline'
    if not utils.get_api_key(resolved.options.api_key) then
        return false
    end
    local ok, provider = pcall(require, 'phantom-code.backends.' .. resolved.provider)
    return ok and provider.is_available and provider.is_available() or false
end

function M.new()
    local source = setmetatable({}, { __index = M })
    source.is_in_throttle = nil
    source.debounce_timer = nil
    return source
end

function M:get_completions(ctx, callback)
    local config = require('phantom-code').config
    local not_manual_completion = ctx.trigger.kind ~= 'manual'

    -- we want to always invoke completion when invoked manually
    if not config.inline.blink.enable_auto_complete and not_manual_completion then
        callback()
        return
    end

    local function _complete()
        -- NOTE: Since the enable predicates are evaluated at runtime, this condition
        -- must be checked within the deferred function body, right before
        -- sending the request.
        if not_manual_completion and (not utils.run_hooks_until_failure(config.inline.enable_predicates)) then
            callback()
            return
        end

        -- NOTE: blink will accumulate completion items during multiple
        -- callbacks, So for each back we must ensure we only deliver new
        -- arrived completion items to avoid duplicated completion items.
        local delivered_completion_items = {}

        if config.inline.throttle > 0 then
            self.is_in_throttle = true
            vim.defer_fn(function()
                self.is_in_throttle = nil
            end, config.inline.throttle)
        end

        local cmp_ctx = utils.make_cmp_context(ctx)
        local context = utils.enrich_llm_context(utils.get_context(cmp_ctx), cmp_ctx)
        utils.notify('PhantomCode completion started', 'verbose')

        local resolved = utils.resolve_provider_config 'inline'
        local provider = require('phantom-code.backends.' .. resolved.provider)

        provider.complete(context, function(data)
            if not data then
                callback()
                return
            end

            -- HACK: workaround to address an undesired behavior: When using
            -- completion with the cursor positioned mid-word, the partial word
            -- under the cursor is erased.
            -- Example: Current cursor position:
            -- he|
            -- (| represents the cursor)
            -- If the completion item is "llo" and selected, "he" will be
            -- removed from the buffer. To resolve this, we will determine
            -- whether to prepend the last word to the completion items,
            -- avoiding the overwriting issue.

            data = vim.tbl_map(function(item)
                return utils.prepend_to_complete_word(item, context.lines_before)
            end, data)

            if config.inline.add_single_line_entry then
                data = utils.add_single_line_entry(data)
            end

            data = utils.list_dedup(data)

            local new_data = {}

            for _, item in ipairs(data) do
                if not delivered_completion_items[item] then
                    table.insert(new_data, item)
                    delivered_completion_items[item] = true
                end
            end

            local success, max_label_width = pcall(function()
                return require('blink.cmp.config').completion.menu.draw.components.label.width.max
            end)
            if not success then
                max_label_width = 60
            end

            local multi_lines_indicators = ' ⏎'

            local row_line = cmp_ctx.cursor_line
            local col_byte = cmp_ctx.cursor.col - 1
            if col_byte < 0 then
                col_byte = 0
            end
            local before_part = string.sub(row_line, 1, col_byte)
            local after_part = string.sub(row_line, col_byte + 1)

            local items = {}
            for _, result in ipairs(new_data) do
                local normalized = result
                if config.inline.normalize_on_accept ~= false then
                    normalized = utils.normalize_inline_accept_suggestion(before_part, after_part, result, {
                        bufnr = cmp_ctx.bufnr,
                        row0 = cmp_ctx.cursor.line,
                        col0_byte = col_byte,
                    })
                end

                local item_lines = vim.split(normalized, '\n')
                local item_label

                if #item_lines == 1 then
                    item_label = normalized
                else
                    item_label = vim.fn.strcharpart(item_lines[1], 0, max_label_width - #multi_lines_indicators)
                        .. multi_lines_indicators
                end

                table.insert(items, {
                    label = item_label,
                    insertText = normalized,
                    kind_name = resolved.options.name or resolved.provider,
                    kind_hl = 'BlinkCmpItemKindPhantomCode',
                    documentation = {
                        kind = 'markdown',
                        value = '```' .. (vim.bo.ft or '') .. '\n' .. result .. '\n```',
                    },
                })
            end
            callback {
                is_incomplete_forward = false,
                is_incomplete_backward = false,
                items = items,
            }
        end, { provider_options = resolved.options })
    end

    if ctx.trigger.kind == 'manual' then
        _complete()
        return
    end

    if config.inline.throttle > 0 and self.is_in_throttle then
        callback()
        return
    end

    if config.inline.debounce > 0 then
        if self.debounce_timer and not self.debounce_timer:is_closing() then
            self.debounce_timer:stop()
            self.debounce_timer:close()
        end
        self.debounce_timer = vim.defer_fn(_complete, config.inline.debounce)
    else
        _complete()
    end
end

return M
