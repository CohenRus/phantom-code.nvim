local M = {}
local utils = require 'phantom-code.utils'
local uv = vim.uv or vim.loop
---@diagnostic disable-next-line: unused-local
local Job = require 'plenary.job'

-- Inline Tab completion jobs (virtualtext / blink / FIM); separate from Expand so flows do not cancel each other.
M.current_jobs = {}
M.expand_jobs = {}

---@param job Job
---@param pool? 'inline'|'expand' Where to track the job (default: inline).
---@param expand_session_id? integer When pool is expand, stored on the job for scoped termination.
function M.register_job(job, pool, expand_session_id)
    if pool == 'expand' and expand_session_id ~= nil then
        job._phantom_code_expand_session = expand_session_id
    end
    local list = pool == 'expand' and M.expand_jobs or M.current_jobs
    table.insert(list, job)
    utils.notify('Registered completion job (' .. (pool or 'inline') .. ')', 'debug')
end

---@param job Job
function M.remove_job(job)
    for _, list in ipairs { M.current_jobs, M.expand_jobs } do
        for i, j in ipairs(list) do
            if j.pid == job.pid then
                table.remove(list, i)
                utils.notify('Completion job ' .. job.pid .. ' finished and removed', 'debug')
                return
            end
        end
    end
end

---@param pid number
local function terminate_job(pid)
    if not uv.kill(pid, 'sigterm') then
        utils.notify('Failed to terminate completion job ' .. pid, 'warn', vim.log.levels.WARN)
        return false
    end

    utils.notify('Terminate completion job ' .. pid, 'debug')

    return true
end

function M.terminate_all_jobs()
    for _, job in ipairs(M.current_jobs) do
        terminate_job(job.pid)
    end

    M.current_jobs = {}
end

function M.terminate_expand_jobs()
    for _, job in ipairs(M.expand_jobs) do
        terminate_job(job.pid)
    end

    M.expand_jobs = {}
end

--- Terminate expand HTTP jobs tagged with the given Expand session id.
---@param session_id integer
function M.terminate_expand_jobs_for_session(session_id)
    local kept = {}
    for _, job in ipairs(M.expand_jobs) do
        if job._phantom_code_expand_session == session_id then
            terminate_job(job.pid)
        else
            table.insert(kept, job)
        end
    end
    M.expand_jobs = kept
end

---@param items_raw string?
---@param provider string
---@return table<string>
function M.parse_completion_items(items_raw, provider)
    local success, items_table = pcall(vim.split, items_raw, '<endCompletion>')
    if not success then
        utils.notify('Failed to parse ' .. provider .. "'s content text", 'error', vim.log.levels.INFO)
        return {}
    end

    return items_table
end

function M.filter_context_sequences_in_items(items, context)
    local filtered = {}
    for _, x in ipairs(items) do
        local result = utils.filter_text(x, context)
        if result then
            table.insert(filtered, result)
        end
    end

    return filtered
end

---@param str_list string[]
---@return table
function M.create_chat_messages_from_list(str_list)
    local result = {}
    local roles = { 'user', 'assistant' }
    for i, content in ipairs(str_list) do
        table.insert(result, { role = roles[(i - 1) % 2 + 1], content = content })
    end
    return result
end

---@param transform fun(data: { end_point: string, headers: table, body: table })[]?
---@param end_point string
---@param headers table
---@param body table
---@return { end_point: string, headers: table, body: table }
function M.apply_transforms(transform, end_point, headers, body)
    local transformed_data = {
        end_point = end_point,
        headers = headers,
        body = body,
    }

    for _, fun in ipairs(transform or {}) do
        transformed_data = fun(transformed_data)
    end

    return transformed_data
end

return M
