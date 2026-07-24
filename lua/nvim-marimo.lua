-- luacheck: globals vim
local M = {}

local ASYNC = require('qianli.async')
local MARIMO_SOCKET = vim.env.MARIMO_SOCKET
local NAMESPACE = vim.api.nvim_create_namespace("marimo_output")

-- Buffer-local states
local buffer_states = {}

local function urlencode(str)
    return string.gsub(str, "([^%w%-%_%.])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
end

local function get_state(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    if not buffer_states[bufnr] then
        buffer_states[bufnr] = {
            session_id = nil,
        }
    end
    return buffer_states[bufnr]
end

local function subprocess(...)
    local result = ASYNC.promisify(vim.system, ...)
    ASYNC.promisify(vim.schedule)
    return result
end

local function check_session_exists(sid, file_path)
    local obj = subprocess({"curl", "--unix-socket", MARIMO_SOCKET, "-s", "--fail-with-body", "http://host/api/sessions"})
    if obj.code ~= 0 then
        return false
    end
    local ok, sessions = pcall(vim.fn.json_decode, obj.stdout)
    return ok and sessions and sessions[sid] and sessions[sid].path == file_path
end

local function get_session_id()
    local state = get_state()
    if state.session_id then
        return state.session_id
    end

    local file_path = vim.api.nvim_buf_get_name(0)
    if file_path == "" then
        return
    end

    local obj = subprocess({"curl", "--unix-socket", MARIMO_SOCKET, "-s", "--fail", "http://host/api/sessions"})
    if obj.code == 0 then
        local ok, sessions = pcall(vim.fn.json_decode, obj.stdout)
        if ok and sessions then
            for id, info in pairs(sessions) do
                if info.path == file_path then
                    state.session_id = id
                    return state.session_id
                end
            end
        end
    end

    local session_id = "s_" .. math.random()
    subprocess({
        "curl", "--unix-socket", MARIMO_SOCKET, "-s", "--fail", "-m0.5",
        "ws://host/ws?file=" .. urlencode(file_path) .. "&session_id=" .. urlencode(session_id)
    })

    if check_session_exists(session_id, file_path) then
        state.session_id = session_id
    else
        vim.schedule(function()
            print_error('failed to start marimo session for ' .. file_path)
        end)
    end

    return state.session_id
end

local function get_cells_ts()
    local parser = vim.treesitter.get_parser(0, "python")
    local tree = parser:parse()[1]
    local root = tree:root()

    local query = vim.treesitter.query.parse("python", [[
        (decorated_definition
          (decorator
            (attribute
              object: (identifier) @obj (#eq? @obj "app")
              attribute: (identifier) @attr (#eq? @attr "cell")))
          definition: (function_definition
            name: (identifier) @name) @cell)
    ]])

    local cells = {}
    for id, node, _ in query:iter_captures(root, 0) do
        local name = query.captures[id]
        if name == "cell" then
            local start_row, _, end_row, _ = node:range()
            local def_line = start_row
            for child in node:iter_children() do
                if child:type() == "function_definition" then
                    for grandchild in child:iter_children() do
                        if grandchild:type() == "identifier" then
                            local r, _, _, _ = grandchild:range()
                            def_line = r + 1
                            break
                        end
                    end
                end
            end
            table.insert(cells, {
                start_line = start_row + 1,
                end_line = end_row + 1,
                def_line = def_line
            })
        end
    end
    table.sort(cells, function(a, b) return a.start_line < b.start_line end)
    return cells
end

local function get_current_cell_index()
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
    local cells = get_cells_ts()
    for i = #cells, 1, -1 do
        if cursor_line >= cells[i].start_line then
            return i - 1
        end
    end
    return nil
end

local function kernel_execute(code, callback)
    local sid = get_session_id()
    if not sid then
        return
    end

    local payload = vim.fn.json_encode({code = code})
    return subprocess({
        "curl", "--unix-socket", MARIMO_SOCKET, "-s", "--fail", "-N", "http://host/api/kernel/execute",
        "-H", "Content-Type: application/json",
        "-H", "Marimo-Session-Id: " .. sid,
        "-d", payload
    }, {
        stdout = function(_, data)
            if not data then
                return
            end

            local is_stdout = false

            local process = ASYNC.wrap(function(line)
                local sse_event = line:match("^event: (.*)")
                if sse_event then
                    is_stdout = sse_event == 'stdout'
                    return
                end

                local sse_data = line:match("^data: (.*)")
                if not sse_data then
                    return
                end

                ASYNC.promisify(vim.schedule)
                local ok, decoded = pcall(vim.fn.json_decode, sse_data)
                if not ok or not decoded or not decoded.data then
                    return
                end

                if callback then
                    callback(decoded.data, is_stdout)
                elseif not is_stdout then
                    print_error(vim.trim(decoded.data))
                end
            end)

            for line in data:gmatch("[^\r\n]+") do
                process(line)
            end

        end
    })
end

M.refresh = ASYNC.wrap(function()
    ASYNC.promisify(vim.schedule)

    local code = --[[python--]] [[
import marimo._code_mode as cm
import json
async with cm.get_context() as ctx:
    res = []
    # Build a lookup for cell status directly from ctx.cells
    for c in ctx.cells:
        res.append({
            "status": c.status,
            "stale": c.status == "stale",
            "console_outputs": [o.asdict() for o in c.console_outputs]
        })
    print(json.dumps(res))
]]
    kernel_execute(code, function(data, is_stdout)
        if not is_stdout then
            print_error(vim.trim(data))
            return
        end

        local ok, cell_data = pcall(vim.fn.json_decode, data)
        if not ok then
            return
        end

        local cells = get_cells_ts()
        vim.api.nvim_buf_clear_namespace(0, NAMESPACE, 0, -1)
        for i, d in ipairs(cell_data) do
            local cell_info = cells[i]
            if cell_info and cell_info.end_line then
                local virt_lines = {}
                if d.stale then
                    table.insert(virt_lines, {{"[STALE]", "WarningMsg"}})
                end
                for _, out in ipairs(d.console_outputs) do
                    local out_lines = vim.split(out.data, "\n")
                    local hl = (out.channel == "stderr") and "ErrorMsg" or "Comment"
                    for _, l in ipairs(out_lines) do
                        if l ~= "" then
                            table.insert(virt_lines, {{l, hl}})
                        end
                    end
                end
                if #virt_lines > 0 then
                    vim.api.nvim_buf_set_extmark(0, NAMESPACE, cell_info.end_line - 1, 0, {
                        virt_lines = virt_lines,
                        virt_lines_above = false
                    })
                end
            end
        end
    end)
end)

M.run = ASYNC.wrap(function()
    ASYNC.promisify(vim.schedule)

    local idx = get_current_cell_index()
    if not idx then
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
    kernel_execute(code, function(data, is_stdout)
        if is_stdout then
            local ok, jsondata = pcall(vim.fn.json_decode, data)
            if ok then
                to_run = jsondata
            end
        end
    end)

    for _, id in ipairs(to_run) do
        code = string.format(--[[python--]] [[
import marimo._code_mode as cm
import json
async with cm.get_context() as ctx:
    cell_lookup = {c.id: c for c in ctx.cells}
    cid = %q
    cell = cell_lookup.get(cid)
    name = cell.name if cell else cid
    print(f"RUNNING:{name}")
    ctx.run_cell(cid)

    # Verify if cell still exists and has errors after run
    if cell and any(o.channel == "stderr" for o in cell.console_outputs):
        print(f"ERROR:{name}")
        ]], id)

        local failed = false
        kernel_execute(code, function(data, is_stdout)
            if data == '' then
                return
            end
            local running = data:match("^RUNNING:(.*)")
            if running then
                vim.print("Executing " .. vim.trim(running))
                return
            end
            failed = true
            local error = data:match("^ERROR:(.*)")
            if error then
                print_error("Error in cell: " .. vim.trim(error))
                return
            end
            -- Any other output is likely an error or unexpected diagnostic
            -- print_error(vim.trim(data))
        end)

        if failed then
            break
        end
    end

    M.refresh()
end)

M.reformat = ASYNC.wrap(function()
    ASYNC.promisify(vim.schedule)

    local idx = get_current_cell_index()
    if not idx then
        return
    end

    local sid = get_session_id()
    if not sid then
        return
    end

    local code = string.format(--[[python--]] [[
import marimo._code_mode as cm
async with cm.get_context() as ctx:
    ctx.edit_cell(ctx.cells[%d].id, ctx.cells[%d].code)
]], idx, idx)
    kernel_execute(code)
    vim.cmd("checktime")
end)

function M.enable()
    local bufnr = vim.api.nvim_get_current_buf()
    local state = get_state(bufnr)

    vim.api.nvim_buf_create_user_command(bufnr, "MarimoRefresh", function() M.refresh() end, {})
    vim.api.nvim_buf_create_user_command(bufnr, "MarimoRun", function() M.run() end, {})
    vim.api.nvim_buf_create_user_command(bufnr, "MarimoReformat", function() M.reformat() end, {})

    vim.api.nvim_create_autocmd("BufDelete", {
        buffer = bufnr,
        callback = function()
            if state.server_handle then
                state.server_handle:kill(15)
                state.server_handle = nil
            end
            buffer_states[bufnr] = nil
        end
    })

    local timer = nil
    vim.api.nvim_create_autocmd("BufWritePost", {
        buffer = bufnr,
        callback = function()
            if timer then
                timer:stop()
            end
            timer = vim.loop.new_timer()
            timer:start(1000, 0, M.refresh)
        end
    })

    ASYNC.run(function()
        while subprocess({'curl', '--fail', '-s', '--unix-socket', MARIMO_SOCKET, 'http://asd/api/status'}).code ~= 0 do
            ASYNC.sleep(0.1)
        end
        M.refresh()
    end)

end

return M
