local M = {}

function M.setup(config)
    local cfg = config or {}
    local default_config = require 'phantom-code.config'

    if cfg.enabled then
        vim.deprecate('phantom-code.config.enabled', 'phantom-code.config.inline.enable_predicates', 'next release', 'phantom-code', false)
        cfg.inline = vim.tbl_deep_extend('force', cfg.inline or {}, {
            enable_predicates = (cfg.inline and cfg.inline.enable_predicates) or cfg.enabled,
        })
    end

    M.config = vim.tbl_deep_extend('force', default_config, cfg)

    require('phantom-code.virtualtext').setup()
    require('phantom-code.expand').setup()
    require 'phantom-code.deprecate'
end

function M.make_blink_map()
    return {
        function(cmp)
            cmp.show { providers = { 'phantom-code' } }
        end,
    }
end

local function complete_change_model_options()
    local modelcard = require 'phantom-code.modelcard'
    local choices = {}

    -- Build the list of available models
    for provider, models in pairs(modelcard.models) do
        if provider == 'openai_compatible' or provider == 'openai_fim_compatible' then
            -- Handle subproviders for compatible APIs
            local subprovider = M.config.provider_options[provider]
                and string.lower(M.config.provider_options[provider].name)
            if subprovider and models[subprovider] then
                for _, model in ipairs(models[subprovider]) do
                    table.insert(choices, provider .. ':' .. model)
                end
            end
        elseif type(models) == 'table' then
            -- Handle regular providers
            for _, model in ipairs(models) do
                table.insert(choices, provider .. ':' .. model)
            end
        end
    end

    return choices
end

function M.change_model(provider_model)
    if not M.config then
        vim.notify 'PhantomCode config is not set up yet, please call the setup function firstly.'
        return
    end

    -- If no provider_model is provided, use vim.ui.select to choose one
    if not provider_model then
        local choices = complete_change_model_options()

        vim.ui.select(choices, {
            prompt = 'Select a model:',
            format_item = function(item)
                return item
            end,
        }, function(choice)
            if choice then
                M.change_model(choice)
            end
        end)
        return
    end

    local provider, model = provider_model:match '([^:]+):(.+)'
    if not provider or not model then
        vim.notify('Invalid format. Use format provider:model (e.g., openai:gpt-4o)', vim.log.levels.ERROR)
        return
    end

    if not M.config.provider_options[provider] then
        vim.notify(
            'The provider is not supported, please refer to phantom-code.nvim document for more information.',
            vim.log.levels.ERROR
        )
        return
    end

    M.config.provider = provider
    M.config.provider_options[provider].model = model
    vim.notify(string.format('PhantomCode model changed to: %s (%s)', model, provider), vim.log.levels.INFO)
end

function M.change_provider(provider)
    if not M.config then
        vim.notify 'PhantomCode config is not set up yet, please call the setup function firstly.'
        return
    end

    if not M.config.provider_options[provider] then
        vim.notify(
            'The provider is not supported, please refer to phantom-code.nvim document for more information.',
            vim.log.levels.ERROR
        )
        return
    end

    M.config.provider = provider
    vim.notify('PhantomCode Provider changed to: ' .. provider, vim.log.levels.INFO)
end

local function phantom_code_complete(arglead, cmdline, _)
    if not M.config then
        vim.notify 'PhantomCode config is not set up yet, please call the setup function firstly.'
        return
    end

    local completions = {
        expand = {
            ask = true,
            accept = true,
            dismiss = true,
            revise = true,
        },
        blink = { enable = true, disable = true, toggle = true },
        virtualtext = { enable = true, disable = true, toggle = true },
        change_model = complete_change_model_options,
        change_provider = function()
            local providers = {}
            for k, _ in pairs(M.config.provider_options) do
                table.insert(providers, k)
            end
            return providers
        end,
    }

    cmdline = cmdline or ''
    local parts = vim.split(vim.trim(cmdline), '%s+')

    ---@type table|function
    local node = completions

    -- The current part may be partial, so keep `node` at the parent level
    -- and filter by prefix.
    local n_fully_typed_parts = #parts
    if arglead ~= '' and #parts > 0 then
        n_fully_typed_parts = n_fully_typed_parts - 1
    end

    for i = 2, n_fully_typed_parts do
        local part = parts[i]
        if type(node) ~= 'table' or node[part] == nil then
            return {}
        end
        node = node[part]
    end

    if type(node) == 'function' then
        return vim.tbl_filter(function(item)
            return vim.startswith(item, arglead)
        end, node())
    elseif type(node) == 'table' then
        return vim.tbl_filter(function(item)
            return vim.startswith(item, arglead)
        end, vim.tbl_keys(node))
    end

    return {}
end

pcall(vim.api.nvim_del_user_command, 'PhantomCode')
vim.api.nvim_create_user_command('PhantomCode', function(args)
    if not M.config then
        vim.notify 'PhantomCode config is not set up yet, please call the setup function firstly.'
        return
    end

    local fargs = args.fargs

    local actions = {}

    actions.blink = {
        enable = function()
            M.config.inline.blink.enable_auto_complete = true
            vim.notify('PhantomCode blink enabled', vim.log.levels.INFO)
        end,
        disable = function()
            M.config.inline.blink.enable_auto_complete = false
            vim.notify('PhantomCode blink disabled', vim.log.levels.INFO)
        end,
        toggle = function()
            M.config.inline.blink.enable_auto_complete = not M.config.inline.blink.enable_auto_complete
            vim.notify('PhantomCode blink toggled', vim.log.levels.INFO)
        end,
    }

    actions.virtualtext = {
        enable = require('phantom-code.virtualtext').action.enable_auto_trigger,
        disable = require('phantom-code.virtualtext').action.disable_auto_trigger,
        toggle = require('phantom-code.virtualtext').action.toggle_auto_trigger,
    }

    actions.change_provider = setmetatable({}, {
        __index = function(_, key)
            return function()
                M.change_provider(key)
            end
        end,
    })

    local command = fargs[1]

    if command == 'change_model' then
        M.change_model(fargs[2])
    elseif command == 'expand' then
        local sub = fargs[2]
        local ex = require 'phantom-code.expand'
        if sub == 'ask' then
            ex.invoke_ask()
        elseif sub == 'accept' then
            ex.accept()
        elseif sub == 'dismiss' then
            ex.dismiss()
        elseif sub == 'revise' then
            ex.revise()
        elseif sub == nil or sub == '' then
            ex.invoke()
        else
            vim.notify('PhantomCode expand: unknown subcommand ' .. tostring(sub), vim.log.levels.ERROR)
        end
    else
        local action_group = actions[command]
        if not action_group then
            vim.notify('Invalid PhantomCode command: ' .. tostring(command), vim.log.levels.ERROR)
            return
        end

        -- For commands like `lsp`, the action_group may contain nested
        -- sub-groups (e.g. `lsp completion enable_auto_trigger`).
        -- Walk one level deeper when fargs[2] resolves to a table.
        local action_name = fargs[2]
        if type(action_group[action_name]) == 'table' then
            action_group = action_group[action_name]
            action_name = fargs[3]
        end

        local action_fn = action_group[action_name]
        if not action_fn then
            vim.notify('PhantomCode ' .. command .. ' requires a valid action', vim.log.levels.ERROR)
            return
        end

        action_fn()
    end
end, {
    nargs = '+',
    complete = phantom_code_complete,
})

return M
