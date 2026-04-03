local utils = require 'phantom-code.utils'
local common = require 'phantom-code.backends.common'
local Job = require 'plenary.job'

local M = {}

M.is_available = function()
    local config = require('phantom-code').config
    return utils.get_api_key(config.provider_options.claude.api_key) and true or false
end

---@param merged_options table|nil If set, merged inline provider options; else global Claude options.
local function make_request_data(merged_options)
    local config = require('phantom-code').config
    local options = vim.deepcopy(merged_options or config.provider_options.claude)
    local system = utils.make_system_prompt(options.system, utils.INLINE_N_COMPLETIONS)

    local request_data = {
        system = system,
        max_tokens = options.max_tokens,
        model = options.model,
        stream = options.stream,
    }

    request_data = vim.tbl_deep_extend('force', request_data, options.optional or {})

    return options, request_data
end

function M.get_text_fn_no_stream(json)
    return json.content[1].text
end

function M.get_text_fn_stream(json)
    return json.delta.text
end

---@param options table
---@param system_text string
---@param messages { role: string, content: string }[]
---@param callback fun(text: string?)
---@param request_opts? { max_time?: number }
M.expand_chat = function(options, system_text, messages, callback, request_opts)
    request_opts = request_opts or {}
    local config = require('phantom-code').config
    if request_opts.cancel_existing_expand_jobs ~= false then
        common.terminate_expand_jobs()
    end

    local data = {
        system = system_text,
        max_tokens = options.max_tokens,
        model = options.model,
        stream = options.stream,
        messages = messages,
    }

    data = vim.tbl_deep_extend('force', data, options.optional or {})

    local headers = {
        ['Content-Type'] = 'application/json',
        ['x-api-key'] = utils.get_api_key(options.api_key),
        ['anthropic-version'] = '2023-06-01',
    }
    local transformed_data = common.apply_transforms(options.transform, options.end_point, headers, data)

    local data_file = utils.make_tmp_file(transformed_data.body)

    if data_file == nil then
        callback()
        return
    end

    local args =
        utils.make_curl_args(transformed_data.end_point, transformed_data.headers, data_file, request_opts.max_time)

    local provider_name = 'Claude'
    local timestamp = os.time()

    utils.run_event('PhantomCodeRequestStartedPre', {
        provider = provider_name,
        name = provider_name,
        model = options.model,
        n_requests = 1,
        timestamp = timestamp,
    })

    local new_job = Job:new {
        command = config.curl_cmd,
        args = args,
        on_exit = vim.schedule_wrap(function(job, exit_code)
            common.remove_job(job)

            utils.run_event('PhantomCodeRequestFinished', {
                provider = provider_name,
                name = provider_name,
                model = options.model,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })

            local items_raw

            if options.stream then
                items_raw = utils.stream_decode(job, exit_code, data_file, provider_name, M.get_text_fn_stream)
            else
                items_raw = utils.no_stream_decode(job, exit_code, data_file, provider_name, M.get_text_fn_no_stream)
            end

            if not items_raw then
                callback()
                return
            end

            callback(items_raw)
        end),
    }

    common.register_job(new_job, 'expand', request_opts.expand_session_id)
    new_job:start()

    utils.run_event('PhantomCodeRequestStarted', {
        provider = provider_name,
        name = options.name or provider_name,
        model = options.model,
        n_requests = 1,
        request_idx = 1,
        timestamp = timestamp,
    })
end

---@param inline_opts? phantom-code.InlineCompleteOpts
M.complete = function(context, callback, inline_opts)
    inline_opts = inline_opts or {}
    local config = require('phantom-code').config
    if inline_opts.cancel_existing ~= false then
        common.terminate_all_jobs()
    end

    local options, data = make_request_data(inline_opts.provider_options)
    local ctx = utils.make_chat_llm_shot(context, options.chat_input)
    ctx = common.create_chat_messages_from_list(ctx)

    local few_shots = utils.get_or_eval_value(options.few_shots)
    if type(few_shots) ~= 'table' then
        few_shots = {}
    else
        few_shots = vim.deepcopy(few_shots)
    end

    vim.list_extend(few_shots, ctx)

    data.messages = few_shots

    local headers = {
        ['Content-Type'] = 'application/json',
        ['x-api-key'] = utils.get_api_key(options.api_key),
        ['anthropic-version'] = '2023-06-01',
    }
    local transformed_data = common.apply_transforms(options.transform, options.end_point, headers, data)

    local data_file = utils.make_tmp_file(transformed_data.body)

    if data_file == nil then
        callback()
        return
    end

    local args = utils.make_curl_args(transformed_data.end_point, transformed_data.headers, data_file)

    local provider_name = 'Claude'
    local timestamp = os.time()

    utils.run_event('PhantomCodeRequestStartedPre', {
        provider = provider_name,
        name = provider_name,
        model = options.model,
        n_requests = 1,
        timestamp = timestamp,
    })

    local new_job = Job:new {
        command = config.curl_cmd,
        args = args,
        on_exit = vim.schedule_wrap(function(job, exit_code)
            common.remove_job(job)

            utils.run_event('PhantomCodeRequestFinished', {
                provider = provider_name,
                name = provider_name,
                model = options.model,
                n_requests = 1,
                request_idx = 1,
                timestamp = timestamp,
            })

            local items_raw

            if options.stream then
                items_raw = utils.stream_decode(job, exit_code, data_file, provider_name, M.get_text_fn_stream)
            else
                items_raw = utils.no_stream_decode(job, exit_code, data_file, provider_name, M.get_text_fn_no_stream)
            end

            if not items_raw then
                callback()
                return
            end

            local items = common.parse_completion_items(items_raw, provider_name)

            items = common.filter_context_sequences_in_items(items, context)

            items = utils.remove_spaces(items)
            items = utils.limit_inline_completion_items(items)

            callback(items)
        end),
    }

    common.register_job(new_job, inline_opts.job_pool)
    new_job:start()

    utils.run_event('PhantomCodeRequestStarted', {
        provider = provider_name,
        name = options.name,
        model = options.model,
        n_requests = 1,
        request_idx = 1,
        timestamp = timestamp,
    })
end

return M
