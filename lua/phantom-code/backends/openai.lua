local base = require 'phantom-code.backends.openai_base'
local utils = require 'phantom-code.utils'

local M = {}

M.is_available = function()
    local config = require('phantom-code').config
    return utils.get_api_key(config.provider_options.openai.api_key) and true or false
end

if not M.is_available() then
    utils.notify('OpenAI API key is not set', 'error', vim.log.levels.ERROR)
end

M.complete = function(context, callback, inline_opts)
    inline_opts = inline_opts or {}
    local config = require('phantom-code').config
    local options = vim.deepcopy(inline_opts.provider_options or config.provider_options.openai)
    options.name = options.name or 'OpenAI'

    base.complete_openai_base(options, context, callback, inline_opts)
end

M.expand_chat = function(options, messages, callback, request_opts)
    base.expand_openai_chat(options, messages, callback, request_opts)
end

return M
