local base = require 'phantom-code.backends.openai_base'
local utils = require 'phantom-code.utils'

local M = {}

local notified_on_using_chat_endpoint = false

M.is_available = function()
    local config = require('phantom-code').config
    local options = config.provider_options.openai_fim_compatible
    if options.end_point == '' or options.api_key == '' or options.name == '' then
        return false
    end

    if not notified_on_using_chat_endpoint and options.end_point:find 'chat' then
        utils.notify(
            'You are using the `/chat/completions` endpoint, which is likely not designed for FIM code completion. Please use the `/completions` endpoint instead.',
            'warn',
            vim.log.levels.WARN
        )
        notified_on_using_chat_endpoint = true
    end

    return utils.get_api_key(options.api_key) and true or false
end

if not M.is_available() then
    utils.notify(
        [[The API key has not been provided as an environment variable, or the specified API key environment variable does not exist.
Or the api-key function doesn't return the value.
If you are using Ollama, you can simply set it to 'TERM'.]],
        'error',
        vim.log.levels.ERROR
    )
end

function M.get_text_fn(json)
    return json.choices[1].text
end

M.complete = function(context, callback, inline_opts)
    inline_opts = inline_opts or {}
    local config = require('phantom-code').config
    local options = vim.deepcopy(inline_opts.provider_options or config.provider_options.openai_fim_compatible)

    local get_text_fn = M.get_text_fn

    if options.get_text_fn.stream and options.stream then
        get_text_fn = options.get_text_fn.stream
    elseif options.get_text_fn.no_stream and not options.stream then
        get_text_fn = options.get_text_fn.no_stream
    end

    base.complete_openai_fim_base(options, get_text_fn, context, callback, inline_opts)
end

return M
