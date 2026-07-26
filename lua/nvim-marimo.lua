-- luacheck: globals vim
local M = {}

local MARIMO_SOCKET = vim.env.MARIMO_SOCKET

-- Buffer-local states
local buffer_states = {}

local function urlencode(str)
    return string.gsub(str, "([^%w%-%_%.])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
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

local function check_session_exists(sid, file_path, callback)
    vim.system({"curl", "--unix-socket", MARIMO_SOCKET, "-s", "--fail-with-body", "http://host/api/sessions"}, function(out)
        if out.code ~= 0 then
            return callback(false)
        end
        local ok, sessions = pcall(vim.json.decode, out.stdout)
        callback(ok and sessions and sessions[sid] and sessions[sid].path == file_path)
    end)
end

local function get_session_id(bufnr, callback)
    local state = get_state(bufnr)
    if not state then
        callback()
        return
    end
    if state.session_id then
        callback(state.session_id)
        return
    end

    local file_path = vim.api.nvim_buf_get_name(0)
    if file_path == "" then
        callback()
        return
    end

    vim.system({"curl", "--unix-socket", MARIMO_SOCKET, "-s", "--fail", "http://host/api/sessions"}, function(out)
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
        vim.system({
            "curl", "--unix-socket", MARIMO_SOCKET, "-s", "--fail", "-m0.5",
            "ws://host/ws?file=" .. urlencode(file_path) .. "&session_id=" .. urlencode(session_id)
        }, function(_)
            check_session_exists(session_id, file_path, function(exists)
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

local function kernel_execute(bufnr, code, out_callback, done_callback)
    get_session_id(bufnr, function(sid)
        if not sid then
            return
        end

        local payload = vim.json.encode({code = code})
        vim.system({
            "curl", "--unix-socket", MARIMO_SOCKET, "-s", "--fail", "-N", "http://host/api/kernel/execute",
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
                        print_error(vim.trim(decoded.data))
                    end
                end

                for line in vim.gsplit(data, '\n') do
                    process(line)
                end

            end
        }, done_callback)
    end)
end

local function get_render_backend()
    return require('nvim-marimo.split')
end

local function render(bufnr)
    local state = get_state(bufnr)
    if state then
        get_render_backend().render(bufnr, state)
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
async with cm.get_context() as ctx:
    res = []
    # Build a lookup for cell status directly from ctx.cells
    for c in ctx.cells:
        res.append({
            "status": c.status,
            "console_outputs": [o.asdict() for o in c.console_outputs]
        })
    print(json.dumps(res))
]]
    local cell_data = nil
    kernel_execute(bufnr, code, function(data, type)
        if type == 'stdout' then
            local ok, cd = pcall(vim.json.decode, data.data)
            if ok then
                cell_data = cd
            end
        elseif data.data then
            print_error(vim.trim(data.data))
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
    local idx = get_current_cell_index(bufnr)
    if not idx then
        if callback then
            callback()
        end
        return
    end

    local code = string.format(--[[python--]] [[
import marimo._code_mode as cm
import json
async with cm.get_context() as ctx:
    target_id = ctx.cells[%d].id
    to_run = []
    visited = set()
    # Map for easy lookup of cell objects by ID
    cell_lookup = {c.id: c for c in ctx.cells}
    def collect(cid):
        if cid in visited:
            return
        visited.add(cid)
        parents = ctx.graph.parents.get(cid, [])
        for pid in parents:
            # Check staleness via ctx.cells status
            p_cell = cell_lookup.get(pid)
            if p_cell and p_cell.status == "stale":
                collect(pid)
        if cid not in to_run:
            to_run.append(cid)
    collect(target_id)
    print(json.dumps(to_run))
]], idx)
    local to_run = {}
    kernel_execute(bufnr, code, function(data, type)
        if type == 'stdout' then
            local ok, jsondata = pcall(vim.json.decode, data.data)
            if ok then
                to_run = jsondata
            end
        end
    end, function()
        local code_template = --[[python--]] [[
import marimo._code_mode as cm
import json
async with cm.get_context() as ctx:
    cell_lookup = {c.id: c for c in ctx.cells}
    cid = %q
    cell = cell_lookup.get(cid)
    name = cell.name if cell else cid
    print(f"RUNNING:{name}")
    ctx.run_cell(cid)
]]
        local failed = false
        local function line_callback(data, type)
            if type == 'done' then
                failed = data.success
                return
            end

            for line in vim.gsplit(data.data, "\n") do
                local running = line:match("^RUNNING:(.*)")
                if running then
                    print("Executing " .. vim.trim(running))
                end
            end
        end
        local done_callback
        function done_callback(i)
            vim.schedule(function()
                if failed or i > #to_run then
                    M.refresh(bufnr, callback)
                else
                    kernel_execute(bufnr, string.format(code_template, to_run[i]), line_callback, function() done_callback(i + 1) end)
                end
            end)
        end
        done_callback(1)
    end)

end

function M.reformat(bufnr, callback)
    local idx = get_current_cell_index(bufnr)
    if not idx then
        return
    end
    get_session_id(bufnr, function(sid)
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
        kernel_execute(bufnr, code, nil, function()
            vim.cmd("checktime")
            if callback then
                callback()
            end
        end)
    end)
end

function M.enable(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local state = get_state(bufnr)
    if not state then
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
    get_render_backend().enable(bufnr, state)
    render(bufnr)

    M.refresh(bufnr, function()
        print()
    end)
end

function M.disable(bufnr)
    local state = buffer_states[bufnr]
    if state then
        vim.api.nvim_del_augroup_by_id(state.augroup)
        get_render_backend().disable(bufnr, state)
        buffer_states[bufnr] = nil
    end
end

return M
