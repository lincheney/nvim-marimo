-- luacheck: globals vim
local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("nvim-marimo")

-- Buffer-local states
local buffer_states = {}

local function print_error(str)
    vim.api.nvim_echo({{str}}, true, {err = true})
end

local function urlencode(str)
    return string.gsub(str, "([^%w%-%_%.])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function clean_output(out)
    if not out or not out.data then
        return nil
    end
    local data = out.data
    if out.channel == 'marimo-error' and type(data) == 'table' then
        data = table.concat(vim.tbl_map(function(x) return x.msg end, data), ' ')
    elseif out.mimetype == "text/html" or (out.mimetype ~= 'text/plain' and data:find('^<')) then
        data = data:gsub("<[^>]+>", "")
    end
    return data
end

local function get_free_port()
    local tcp = vim.uv.new_tcp()
    tcp:bind('127.0.0.1', 0)
    local port = tcp:getsockname().port
    tcp:close()
    return port
end

local function get_cells_ts(bufnr)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "python")
    if not ok then
        return
    end
    local tree = parser:parse()[1]
    local root = tree:root()

    local query = vim.treesitter.query.parse("python", [[
        (decorated_definition
          (decorator
            (attribute
              object: (identifier) @obj (#eq? @obj "app")
              attribute: (identifier) @attr (#eq? @attr "cell")))
          definition: (function_definition
            name: (identifier) @name) ) @cell

        (decorated_definition
          (decorator
            (call function: (attribute
              object: (identifier) @obj (#eq? @obj "app")
              attribute: (identifier) @attr (#eq? @attr "cell"))))
          definition: (function_definition
            name: (identifier) @name) ) @cell
    ]])

    local cells = {}
    for id, node, _ in query:iter_captures(root, bufnr) do
        if query.captures[id] == "cell" then
            local start_row, _, end_row, _ = node:range()
            table.insert(cells, {start_row = start_row, end_row = end_row})
        end
    end
    table.sort(cells, function(a, b) return a.start_row < b.start_row end)
    return cells
end

local function get_state(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not vim.api.nvim_buf_is_valid(bufnr) then
        buffer_states[bufnr] = nil
        return nil
    end

    if not buffer_states[bufnr] then
        buffer_states[bufnr] = {
            url = nil,
            curl_args = {},
            server_process = nil,
            render_backend = nil,
            session_id = nil,
            cell_data = nil,
            output_buf = nil,
            output_win = nil,
            scrolling = false,
            out_offsets = {},
            get_cells_ts = get_cells_ts,
        }
    end
    return buffer_states[bufnr]
end

local function curl(state, path, args, options, done_callback)
    local url = state.url:gsub('/+$', '') .. path
    if options and options.websocket then
        url = url:gsub('^http://', 'ws://'):gsub('^https://', 'wss://')
        options.websocket = nil
    end
    local cmd = vim.list_extend({"curl", "-s", "--fail-with-body", url}, state.curl_args or {})
    cmd = vim.list_extend(cmd, args or {})
    return vim.system(cmd, options, done_callback)
end

local function check_session_exists(state, sid, file_path, callback)
    curl(state, "/api/sessions", {}, {}, function(out)
        if out.code ~= 0 then
            return callback(false)
        end
        local ok, sessions = pcall(vim.json.decode, out.stdout)
        callback(ok and sessions and sessions[sid] and sessions[sid].path == file_path)
    end)
end

local function get_session_id(state, bufnr, callback)
    if state.session_id then
        callback(state.session_id)
        return
    end

    local file_path = vim.api.nvim_buf_get_name(0)
    if file_path == "" then
        callback()
        return
    end

    curl(state, "/api/sessions", {}, {}, function(out)
        if out.code == 0 then
            local ok, sessions = pcall(vim.json.decode, out.stdout)
            if ok and sessions then
                for id, info in pairs(sessions) do
                    if info.path == file_path then
                        state.session_id = id
                        callback(state.session_id)
                        return
                    end
                end
            end
        end

        local session_id = "s_" .. math.random()
        curl(state, "/ws?file=" .. urlencode(file_path) .. "&session_id=" .. urlencode(session_id), {"-m0.5"}, {websocket = true}, function(_)
            check_session_exists(state, session_id, file_path, function(exists)
                if exists then
                    state.session_id = session_id
                else
                    vim.schedule(function()
                        print_error('failed to start marimo session for ' .. file_path)
                    end)
                end
                callback(state.session_id)
            end)

        end)
    end)

end

local function get_current_cell_index(bufnr)
    local winid = vim.fn.bufwinid(bufnr)
    local cursor_line = vim.api.nvim_win_get_cursor(winid)[1] - 1
    local cells = get_cells_ts(bufnr)
    for i = 1, #cells do
        if cells[i].start_row <= cursor_line and cursor_line <= cells[i].end_row then
            return i - 1
        end
    end
end

local function kernel_execute(state, bufnr, code, out_callback, done_callback)
    get_session_id(state, bufnr, function(sid)
        if not sid then
            return
        end

        local payload = vim.json.encode({code = code})
        curl(state, "/api/kernel/execute", {
            "-N",
            "-H", "Content-Type: application/json",
            "-H", "Marimo-Session-Id: " .. sid,
            "-d", payload
        }, {
            stdout = function(_, data)
                if not data then
                    return
                end

                local type = nil

                local process = function(line)
                    local sse_event = line:match("^event: (.*)")
                    if sse_event then
                        type = sse_event
                        return
                    end

                    local sse_data = line:match("^data: (.*)")
                    if not sse_data then
                        return
                    end

                    local ok, decoded = pcall(vim.json.decode, sse_data)
                    if not ok or not decoded or not decoded.data then
                        return
                    end

                    if out_callback then
                        out_callback(decoded, type)
                    elseif type == 'stderr' then
                        vim.schedule(function()
                            print_error(vim.trim(decoded.data))
                        end)
                    end
                end

                for line in vim.gsplit(data, '\n') do
                    process(line)
                end

            end
        }, done_callback)
    end)
end

local function render(bufnr)
    local state = get_state(bufnr)
    if state then
        state.render_backend.render(bufnr, state)
    end
end

function M.refresh(bufnr, callback)
    local state = get_state(bufnr)
    if not state then
        callback()
        return
    end

    local code = --[[python--]] [[
import marimo._code_mode as cm
import json
import html
import re

def clean(val):
    if val.get('data'):
        if val['channel'] == 'marimo-error' and isinstance(val['data'], list):
            val['data'] = ' '.join(x['msg'] for x in val['data'])
        elif val['mimetype'] == "text/html" or (val['mimetype'] != 'text/plain' and val['data'].startswith('<')):
            val['data'] = html.unescape(re.sub('<[^>]+>', '', val['data']))
    return val

async with cm.get_context() as ctx:
    res = []
    # Build a lookup for cell status directly from ctx.cells
    for c in ctx.cells:
        res.append({
            "status": c.status,
            "output": clean(c.output.asdict()) if c.output else None,
            "console_outputs": [clean(o.asdict()) for o in c.console_outputs],
            "errors": [o.msg for o in c.errors],
        })
    print(json.dumps(res))
]]
    local cell_data = nil
    kernel_execute(state, bufnr, code, function(data, type)
        if type == 'stdout' then
            local ok, cd = pcall(vim.json.decode, data.data, {luanil = {object = true}})
            if ok then
                for _, cell in ipairs(cd) do
                    local outputs = {}
                    for _, o in ipairs(cell.console_outputs) do
                        if o.data then
                            table.insert(outputs, o)
                        end
                    end
                    if cell.output and (cell.output.channel ~= 'marimo-error' or #cell.errors == 0) and cell.output.data then
                        table.insert(outputs, cell.output)
                    end
                    for _, e in ipairs(cell.errors) do
                        table.insert(outputs, {channel = "marimo-error", data = e})
                    end
                    cell.console_outputs = outputs
                end
                cell_data = cd
            end
        elseif data.data then
            vim.schedule(function()
                print_error(vim.trim(data.data))
            end)
        end
    end, function()
        vim.schedule(function()
            state.cell_data = cell_data
            render(bufnr)
            if callback then
                callback()
            end
        end)
    end)
end

function M.run(bufnr, callback)
    local state = get_state(bufnr)
    if not state then
        return
    end

    local idx = get_current_cell_index(bufnr)
    if not idx then
        if callback then
            callback()
        end
        return
    end

    local code = string.format(--[[python--]] [[
import marimo._code_mode as cm
from marimo._runtime.commands import ExecuteCellCommand
import json

async with cm.get_context() as ctx:
    i = %d
    to_run = []
    visited = set()
    # Map for easy lookup of cell objects by ID
    cell_lookup = {c.id: (i, c) for (i, c) in enumerate(ctx.cells)}

    cmds = [ExecuteCellCommand(cell_id=cell.id, code=cell.code) for cell in ctx.cells]
    ctx._kernel.mutate_graph(cmds, ())

    def collect(cell, idx):
        if cell.id in visited:
            return
        visited.add(cell.id)
        parents = ctx.graph.parents.get(cell.id, ())
        for pid in parents:
            # Check staleness via ctx.cells status
            i, p_cell = cell_lookup.get(pid)
            if p_cell and p_cell.status == "stale":
                collect(p_cell, i)
        if cell.id not in to_run:
            to_run.append([cell.id, cell.name, idx])
    collect(ctx.cells[i], i)
    print(json.dumps(to_run))
]], idx, idx)

    local to_run = {}
    kernel_execute(state, bufnr, code, function(data, type)
        if type == 'stdout' then
            local ok, jsondata = pcall(vim.json.decode, data.data)
            if ok then
                to_run = jsondata
            end
        elseif type == 'stderr' then
            vim.schedule(function()
                print_error(vim.trim(data.data))
            end)
        end
    end, function()
        local marker = tostring(math.random()) .. ':'
        local code_template = --[[python--]] [[
import marimo._code_mode as cm
import json
async with cm.get_context() as ctx:
    id = %q
    cell_lookup = {c.id: c for c in ctx.cells}
    ctx.run_cell(id)
    ctx._print_summary = lambda *a, **kw: None
print(%q + cell_lookup[id].status)
]]
        local failed = false
        local function line_callback(i, data, type)
            if type == 'done' then
                failed = data.success
                return
            end

            if data.data:find(marker, 1, true) == 1 then
                state.cell_data[i].status = data.data:sub(#marker + 1):gsub('\n', '')
            else
                local cleaned = clean_output(data)
                if cleaned then
                    table.insert(state.cell_data[i].console_outputs, {channel = data.channel or type, data = cleaned})
                end
            end
            vim.schedule(function()
                render(bufnr)
            end)
        end
        local done_callback
        function done_callback(i)
            vim.schedule(function()
                if failed or i > #to_run then
                    M.refresh(bufnr, callback)
                else
                    print("Executing " .. to_run[i][2])
                    state.cell_data[to_run[i][3] + 1] = {status = 'running', console_outputs = {}}
                    render(bufnr)
                    kernel_execute(
                        state,
                        bufnr,
                        string.format(code_template, to_run[i][1], marker),
                        function(...) line_callback(to_run[i][3] + 1, ...) end,
                        function() done_callback(i + 1) end
                    )
                end
            end)
        end
        done_callback(1)
    end)

end

function M.reformat(bufnr, callback)
    local state = get_state(bufnr)
    if not state then
        return
    end
    local idx = get_current_cell_index(bufnr)
    if not idx then
        return
    end
    get_session_id(state, bufnr, function(sid)
        if not sid then
            if callback then
                callback()
            end
            return
        end
        local code = string.format(--[[python--]] [[
import marimo._code_mode as cm
async with cm.get_context() as ctx:
    ctx.edit_cell(ctx.cells[%d].id, ctx.cells[%d].code)
]], idx, idx)
        kernel_execute(state, bufnr, code, nil, function()
            vim.schedule(function()
                vim.cmd("checktime")
                if callback then
                    callback()
                end
            end)
        end)
    end)
end

function M.open_float(bufnr)
    local state = get_state(bufnr)
    if not state then
        return
    end

    local idx = get_current_cell_index(bufnr)
    if not idx then
        return
    end

    local data = state.cell_data[idx + 1]
    if not data then
        return
    end

    local floatbuf = vim.api.nvim_create_buf(false, true)

    if data.console_outputs then
        for _, out in ipairs(data.console_outputs) do
            local trimmed = (out.data or ''):gsub('\n$', '')
            if trimmed ~= '' then
                local hl = (out.channel == "stderr") and "MarimoStderr" or "MarimoStdout"
                local start = vim.api.nvim_buf_line_count(floatbuf)
                local lines = vim.split(trimmed, '\n')
                vim.api.nvim_buf_set_lines(floatbuf, -1, -1, true, lines)
                vim.hl.range(floatbuf, NAMESPACE, hl, {start, 0}, {start + #lines + 1, #lines[#lines]})
            end
        end
    end
    -- delete first blank line
    vim.api.nvim_buf_set_lines(floatbuf, 0, 1, true, {})

    local status = data.status
    if status == 'idle' then
        status = 'success'
    end

    vim.api.nvim_open_win(floatbuf, true, {
        relative = 'editor',
        width = math.ceil(vim.o.columns * 2 / 3),
        height = math.ceil(vim.o.lines * 2 / 3),
        col = math.floor(vim.o.columns / 6),
        row = math.floor(vim.o.lines / 6),
        border = 'rounded',
        title = ' ' .. status .. ' ',
    })
end

local function start_server_sync(state)
    local port = get_free_port()
    print('Starting marimo server on port ' .. port)
    state.server_process = vim.system({
        'marimo',
        'edit',
        '--watch',
        '--headless',
        '--no-token',
        '--no-skew-protection',
        '--skip-update-check',
        '--host', '127.0.0.1',
        '--port', port,
    })
    state.url = 'http://127.0.0.1:' .. port .. '/'
    -- try 5 times
    for _ = 1, 5 do
        if curl(state, '/api/status'):wait().code == 0 then
            return true
        end
        vim.cmd[[sleep 1]]
    end
end

function M.enable(bufnr, opts)
    opts = opts or {}

    local render_backend
    if opts.render_style == 'virt_lines' or opts.render_style == nil then
        render_backend = require('nvim-marimo.virt_lines')
    elseif opts.render_style == 'split' then
        render_backend = require('nvim-marimo.split')
    else
        error(string.format('Unknown .render_style (%q), expected virt_lines, split', opts.render_style))
    end

    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local state = get_state(bufnr)
    if not state then
        return
    end

    state.render_backend = render_backend
    state.url = opts.url
    state.curl_args = opts.curl_args
    if not state.url and not start_server_sync(state) then
        error('Failed to start marimo server')
        M.disable(bufnr)
        return
    end

    vim.api.nvim_buf_create_user_command(bufnr, "MarimoRefresh", function()
        M.refresh(bufnr)
    end, {})
    vim.api.nvim_buf_create_user_command(bufnr, "MarimoRun", function()
        M.run(bufnr)
    end, {})
    vim.api.nvim_buf_create_user_command(bufnr, "MarimoReformat", function()
        M.reformat(bufnr)
    end, {})
    vim.api.nvim_buf_create_user_command(bufnr, "MarimoOpenFloat", function()
        M.open_float(bufnr)
    end, {})

    state.augroup = vim.api.nvim_create_augroup('nvim-marimo.'..bufnr, {clear = true})

    vim.api.nvim_create_autocmd("BufUnload", {
        buffer = bufnr,
        group = state.augroup,
        callback = function()
            M.disable(bufnr)
        end
    })

    local timer = nil
    vim.api.nvim_create_autocmd("BufWritePost", {
        buffer = bufnr,
        group = state.augroup,
        callback = function()
            if timer then
                timer:stop()
            end
            timer = vim.loop.new_timer()
            timer:start(1000, 0, function()
                vim.schedule(function()
                    M.refresh(bufnr)
                end)
            end)
        end
    })

    print('Loading cells ...')
    local cells = get_cells_ts(bufnr)
    local cell_data = {}
    for i = 1, #cells do
        cell_data[i] = {status = 'loading'}
    end
    state.cell_data = cell_data
    state.render_backend.enable(bufnr, state)
    render(bufnr)

    M.refresh(bufnr, function()
        print()
    end)
end

function M.disable(bufnr)
    local state = buffer_states[bufnr]
    if state then
        if state.augroup then
            vim.api.nvim_del_augroup_by_id(state.augroup)
        end
        if state.server_process then
            state.server_process:kill('term')
            state.server_process = nil
        end
        state.render_backend.disable(bufnr, state)
        buffer_states[bufnr] = nil
    end
end

return M
