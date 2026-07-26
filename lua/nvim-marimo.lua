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
    if not vim.api.nvim_buf_is_valid(bufnr) then
        buffer_states[bufnr] = nil
        return nil
    end

    if not buffer_states[bufnr] then
        buffer_states[bufnr] = {
            session_id = nil,
            cell_data = {},
            output_buf = nil,
            output_win = nil,
            scrolling = false,
            out_offsets = {},
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
    local ok, sessions = pcall(vim.json.decode, obj.stdout)
    return ok and sessions and sessions[sid] and sessions[sid].path == file_path
end

local function get_session_id(bufnr)
    local state = get_state(bufnr)
    if not state then
        return
    end
    if state.session_id then
        return state.session_id
    end

    local file_path = vim.api.nvim_buf_get_name(0)
    if file_path == "" then
        return
    end

    local obj = subprocess({"curl", "--unix-socket", MARIMO_SOCKET, "-s", "--fail", "http://host/api/sessions"})
    if obj.code == 0 then
        local ok, sessions = pcall(vim.json.decode, obj.stdout)
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

local function kernel_execute(bufnr, code, callback)
    local sid = get_session_id(bufnr)
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

                local ok, decoded = pcall(vim.json.decode, sse_data)
                if not ok or not decoded or not decoded.data then
                    return
                end

                if callback then
                    callback(decoded.data, is_stdout)
                elseif not is_stdout then
                    print_error(vim.trim(decoded.data))
                end
            end)

            for line in vim.gsplit(data, '\n') do
                process(line)
            end

        end
    })
end

local function setup_output_buffer(bufnr)
    local state = get_state(bufnr)
    if not state then
        return
    end
    if state.output_buf and vim.api.nvim_buf_is_valid(state.output_buf) then
        return state.output_buf
    end

    local output_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(output_buf, "marimo-output-" .. bufnr)
    vim.api.nvim_buf_set_option(output_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(output_buf, "swapfile", false)
    vim.api.nvim_buf_set_option(output_buf, "bufhidden", "hide")
    state.output_buf = output_buf
    return output_buf
end

local function sync_scroll(bufnr)
    local state = get_state(bufnr)
    if not state or state.scrolling then
        return
    end
    local main_win = vim.fn.bufwinid(bufnr)
    local output_win = state.output_win
    if not main_win or not output_win or not vim.api.nvim_win_is_valid(output_win) then
        return
    end
    local active_win = vim.api.nvim_get_current_win()
    if active_win ~= main_win and active_win ~= output_win then
        return
    end

    state.scrolling = true
    local cells = get_cells_ts(bufnr)
    local wininfo = vim.fn.getwininfo(active_win)[1]

    local active = (active_win == main_win) and cells or state.out_offsets
    local inactive = (active_win ~= main_win) and cells or state.out_offsets

    for i, c in ipairs(active) do
        if wininfo.topline <= c.start_row + 1 or i == #cells then
            local off = inactive[i]
            if off then
                local target_line
                local screenrow

                if c.start_row + 1 < wininfo.topline or c.start_row + 1 > wininfo.botline then
                    -- its off the screen
                    screenrow = vim.fn.screenpos(active_win, wininfo.topline, 0).row - wininfo.winrow
                    target_line = off.start_row + wininfo.topline - c.start_row
                else
                    screenrow = vim.fn.screenpos(active_win, c.start_row + 1, 0).row - wininfo.winrow
                    target_line = off.start_row + 1
                end

                local dst_win = (active_win == main_win) and output_win or main_win

                local dst_row = vim.fn.screenpos(dst_win, target_line, 0).row - vim.fn.getwininfo(dst_win)[1].winrow
                if dst_row < 0 then
                    -- not on the screen at all
                    local dst_buf = vim.api.nvim_win_get_buf(dst_win)
                    local line_count = vim.api.nvim_buf_line_count(dst_buf)
                    vim.api.nvim_win_set_cursor(dst_win, {math.min(target_line, line_count), 0})
                    vim.api.nvim_win_call(dst_win, function()
                        if screenrow > 0 then
                            vim.cmd('normal! zt' .. screenrow .. vim_escape('<c-y>M'))
                        else
                            vim.cmd('normal! zt')
                        end
                    end)
                elseif dst_row ~= screenrow then
                    -- just scroll
                    vim.api.nvim_win_call(dst_win, function()
                        if dst_row > screenrow then
                            vim.cmd('normal! ' .. (dst_row - screenrow) .. vim_escape('<c-e>M'))
                        else
                            vim.cmd('normal! ' .. (screenrow - dst_row) .. vim_escape('<c-y>M'))
                        end
                    end)
                end
                break
            end
        end
    end

    state.scrolling = false
end

local function render_cell_output(bufnr)
    local state = get_state(bufnr)
    if not state then
        return
    end

    local cells = get_cells_ts(bufnr)
    if not cells then
        return
    end
    local output_buf = setup_output_buffer(bufnr)
    local extmarks = {}
    local out_offsets = {}
    local line_offset = 0
    local numlines = 0
    local sep = string.rep('-', 9999)

    vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
    vim.api.nvim_buf_clear_namespace(output_buf, NAMESPACE, 0, -1)
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, {})
    for i, cell_info in ipairs(cells) do

        vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, cell_info.start_row, 0, {virt_text = {{sep, 'Comment'}}})

        local lines = {}
        while numlines + #lines + line_offset < cell_info.start_row do
            table.insert(lines, '')
        end
        vim.api.nvim_buf_set_lines(output_buf, -1, -1, false, lines)
        numlines = numlines + #lines

        local data = state.cell_data[i] or {status = "unknown"}
        local nextnonblank = vim.fn.nextnonblank(cell_info.end_row + 2)
        local cell_height = nextnonblank - cell_info.start_row - 1

        lines = {}
        table.insert(extmarks, {output_buf, NAMESPACE, numlines + #lines, 0, {hl_group = 'WarningMsg', end_row = numlines + #lines + 1, virt_text = {{sep, 'Comment'}}}})
        table.insert(lines, '[' .. data.status:upper() .. ']')

        if data.console_outputs then
            for _, out in ipairs(data.console_outputs) do
                local hl = (out.channel == "stderr") and "ErrorMsg" or ""
                local before = #lines
                local trimmed = (out.data or ''):gsub('\n$', '')
                if trimmed ~= '' then
                    for line in vim.gsplit(trimmed, "\n") do
                        table.insert(lines, line)
                    end
                    table.insert(extmarks, {output_buf, NAMESPACE, numlines + before, 0, {hl_group = hl, end_row = numlines + #lines}})
                end
            end
        end

        table.insert(out_offsets, {
            start_row = numlines,
            -- finish = #lines,
            -- cell_height = cell_height,
        })
        vim.api.nvim_win_set_cursor(state.output_win, {vim.api.nvim_buf_line_count(output_buf), 0})
        vim.api.nvim_buf_set_lines(output_buf, -1, -1, false, lines)
        local output_height = #lines
        vim.api.nvim_win_call(state.output_win, function()
            -- keep moving down until no more to measure the height
            vim.cmd('normal! ' .. #lines .. 'gj')
            local prev = nil
            while true do
                local cursor = vim.api.nvim_win_get_cursor(state.output_win)
                if prev and cursor[1] == prev[1] and cursor[2] == prev[2] then
                    break
                end
                vim.cmd[[normal! gj]]
                if prev then
                    output_height = output_height + 1
                end
                prev = cursor
            end
        end)
        line_offset = line_offset + output_height - #lines
        -- pad left with virt lines
        local virt_lines = {}
        for _ = 1, output_height - cell_height do
            table.insert(virt_lines, {})
        end
        vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, cell_info.end_row, 0, {virt_lines = virt_lines})
        numlines = numlines + #lines

        lines = {}
        while numlines + #lines + line_offset <= cell_info.end_row do
            table.insert(lines, '')
        end
        vim.api.nvim_buf_set_lines(output_buf, -1, -1, false, lines)
        numlines = numlines + #lines

    end
    state.out_offsets = out_offsets
    vim.api.nvim_buf_set_lines(output_buf, 0, 1, false, {})
    for _, extmark in ipairs(extmarks) do
        vim.api.nvim_buf_set_extmark(unpack(extmark))
    end

    sync_scroll(bufnr)
end

local function refresh(bufnr)
    local state = get_state(bufnr)
    if not state then
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
    state.cell_data = nil
    kernel_execute(bufnr, code, function(data, is_stdout)
        if not is_stdout then
            print_error(vim.trim(data))
        else
            local ok, cell_data = pcall(vim.json.decode, data)
            if ok then
                state.cell_data = cell_data
            end
        end
    end)
    render_cell_output(bufnr)
end

local function run(bufnr)
    local idx = get_current_cell_index(bufnr)
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
    kernel_execute(bufnr, code, function(data, is_stdout)
        if is_stdout then
            local ok, jsondata = pcall(vim.json.decode, data)
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
        kernel_execute(bufnr, code, function(data)
            for line in vim.gsplit(data, "\n") do
                local running = line:match("^RUNNING:(.*)")
                if running then
                    print("Executing " .. vim.trim(running))
                else
                    failed = true
                    local error = line:match("^ERROR:(.*)")
                    if error then
                        vim.schedule(function()
                            print_error("Error in cell: " .. vim.trim(error))
                        end)
                        return
                    end
                end
            end
        end)
        if failed then
            break
        end
    end
    refresh(bufnr)
end

local function reformat(bufnr)
    local idx = get_current_cell_index(bufnr)
    if not idx then
        return
    end
    local sid = get_session_id(bufnr)
    if not sid then
        return
    end
    local code = string.format(--[[python--]] [[
import marimo._code_mode as cm
async with cm.get_context() as ctx:
    ctx.edit_cell(ctx.cells[%d].id, ctx.cells[%d].code)
]], idx, idx)
    kernel_execute(bufnr, code)
    vim.cmd("checktime")
end

M.refresh = function(bufnr)
    vim.schedule(function()
        ASYNC.run(refresh,bufnr)
    end)
end

M.run = function(bufnr)
    vim.schedule(function()
        ASYNC.run(run,bufnr)
    end)
end

M.reformat = function(bufnr)
    vim.schedule(function()
        ASYNC.run(reformat, bufnr)
    end)
end

function M.enable(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local state = get_state(bufnr)
    if not state then
        return
    end
    local output_buf = setup_output_buffer(bufnr)
    local output_win = vim.api.nvim_open_win(output_buf, false, {split = 'right'})
    vim.api.nvim_win_set_option(output_win, "scrolloff", 0)
    vim.api.nvim_win_set_option(output_win, "smoothscroll", true)
    state.output_win = output_win

    vim.api.nvim_buf_create_user_command(bufnr, "MarimoRefresh", function()
        M.refresh(bufnr)
    end, {})
    vim.api.nvim_buf_create_user_command(bufnr, "MarimoRun", function()
        M.run(bufnr)
    end, {})
    vim.api.nvim_buf_create_user_command(bufnr, "MarimoReformat", function()
        M.reformat(bufnr)
    end, {})
    vim.api.nvim_create_autocmd("WinScrolled", {callback = function()
        for win, _ in pairs(vim.v.event) do
            win = tonumber(win)
            local buf = win and vim.api.nvim_win_get_buf(win)
            if buf == output_buf or buf == bufnr then
                sync_scroll(bufnr)
                break
            end
        end
    end})
    vim.api.nvim_create_autocmd("WinResized", {callback = function()
        for _, win in ipairs(vim.v.event.windows) do
            local buf = vim.api.nvim_win_get_buf(win)
            if buf == output_buf or buf == bufnr then
                render_cell_output(bufnr)
                break
            end
        end
    end})
    vim.api.nvim_create_autocmd("BufUnload", {
        buffer = bufnr,
        callback = function()
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
            timer:start(1000, 0, function()
                M.refresh(bufnr)
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
    render_cell_output(bufnr)
    ASYNC.run(function()
        while subprocess({'curl', '--fail', '-s', '--unix-socket', MARIMO_SOCKET, 'http://host/api/status'}, {}).code ~= 0 do
            ASYNC.sleep(0.1)
        end
        refresh(bufnr)
        print()
    end)
end

return M
