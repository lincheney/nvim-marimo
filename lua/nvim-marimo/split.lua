local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("nvim-marimo.split")
local SEP = string.rep('─', 9999)

local function setup_output_buffer(bufnr, state)
    if state.split_output_buf and vim.api.nvim_buf_is_valid(state.split_output_buf) then
        return state.split_output_buf
    end

    local output_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(output_buf, "marimo-output-" .. bufnr)
    vim.api.nvim_buf_set_option(output_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(output_buf, "swapfile", false)
    vim.api.nvim_buf_set_option(output_buf, "bufhidden", "hide")
    state.split_output_buf = output_buf
    return output_buf
end

local function measure_screen_height(window, start_row, end_row)
    local height = 1
    vim.api.nvim_win_call(window, function()
        -- start at the bottom and move up
        vim.cmd('normal! ' .. end_row .. 'gg$g^')

        local prev = nil
        while true do
            local cursor = vim.api.nvim_win_get_cursor(window)
            if cursor[1] == start_row and cursor[2] == 0 then
                break
            end
            if prev and cursor[1] == prev[1] and cursor[2] == prev[2] then
                -- fail!
                break
            end
            prev = cursor

            -- there are at least cursor[1] - start_row lines so do them all in one go
            -- do at least one row
            local step = math.max(1, cursor[1] - start_row)
            vim.cmd('normal! ' .. step .. 'gk')
            height = height + step
        end
    end)

    return height
end

local function sync_scroll(bufnr, state)
    if state.split_scrolling > 0 then
        return
    end
    local cells = state.get_cells_ts(bufnr)
    if not cells then
        return
    end

    local main_win = state.split_main_win
    local output_win = state.split_output_win
    if not main_win or not output_win or not vim.api.nvim_win_is_valid(main_win) or not vim.api.nvim_win_is_valid(output_win) then
        return
    end
    local active_win = vim.api.nvim_get_current_win()
    if active_win ~= main_win and active_win ~= output_win then
        return
    end
    if vim.api.nvim_win_get_buf(main_win) ~= bufnr or vim.api.nvim_win_get_buf(output_win) ~= state.split_output_buf then
        return
    end

    state.split_scrolling = state.split_scrolling + 1
    local wininfo = vim.fn.getwininfo(active_win)[1]

    local active = (active_win == main_win) and cells or state.split_out_offsets
    local inactive = (active_win ~= main_win) and cells or state.split_out_offsets

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

    state.split_scrolling = state.split_scrolling - 1
end

function M.render(bufnr, state)
    if not state.cell_data then
        M.disable(bufnr, state)
        return
    end
    local cells = state.get_cells_ts(bufnr)
    if not cells then
        M.disable(bufnr, state)
        return
    end

    local output_buf = setup_output_buffer(bufnr, state)
    local extmarks = {}
    local out_offsets = {}
    local line_offset = 0
    local numlines = 0
    local view = vim.api.nvim_win_call(state.split_main_win, vim.fn.winsaveview)

    vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
    vim.api.nvim_buf_clear_namespace(output_buf, NAMESPACE, 0, -1)
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, {})

    state.split_scrolling = state.split_scrolling + 1

    for i, cell_info in ipairs(cells) do

        vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, cell_info.start_row, 0, {virt_text = {{SEP, 'MarimoBorder'}}})

        local lines = {}
        while numlines + #lines + line_offset < cell_info.start_row do
            table.insert(lines, '')
        end
        vim.api.nvim_buf_set_lines(output_buf, -1, -1, false, lines)
        numlines = numlines + #lines

        local data = state.cell_data[i] or {status = "unknown"}
        local nextnonblank = vim.fn.nextnonblank(cell_info.end_row + 2)
        local cell_height = nextnonblank - cell_info.start_row - 1
        local cell_screen_height = measure_screen_height(state.split_main_win, cell_info.start_row + 1, nextnonblank - 1)

        lines = {}
        local status = data.status
        if status == 'idle' then
            status = 'success'
        end
        table.insert(extmarks, {output_buf, NAMESPACE, numlines + #lines, 0, {hl_group = 'MarimoStatus_' .. data.status:gsub('%-', '_'), end_row = numlines + #lines + 1, virt_text = {{SEP, 'MarimoBorder'}}}})
        table.insert(lines, '(' .. status .. ')')

        if data.console_outputs then
            for _, out in ipairs(data.console_outputs) do
                local before = #lines
                local trimmed = (out.data or ''):gsub('\n$', '')
                if trimmed ~= '' then
                    local hl = (out.channel == "stderr" or out.channel == 'marimo-error') and "MarimoStderr" or "MarimoStdout"
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
        vim.api.nvim_buf_set_lines(output_buf, -1, -1, false, lines)
        local output_height = measure_screen_height(
            state.split_output_win,
            vim.api.nvim_buf_line_count(output_buf) - #lines + 1,
            vim.api.nvim_buf_line_count(output_buf)
        )
        line_offset = line_offset + (output_height - #lines) - (cell_screen_height - cell_height)
        -- pad left with virt lines
        local virt_lines = {}
        for _ = 1, output_height - cell_screen_height do
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
    state.split_out_offsets = out_offsets
    vim.api.nvim_buf_set_lines(output_buf, 0, 1, false, {})
    for _, extmark in ipairs(extmarks) do
        vim.api.nvim_buf_set_extmark(unpack(extmark))
    end
    vim.api.nvim_win_call(state.split_main_win, function()
        vim.fn.winrestview(view)
    end)

    state.split_scrolling = state.split_scrolling - 1
    sync_scroll(bufnr, state)
end

function M.enable(bufnr, state)
    state.split_main_win = vim.api.nvim_get_current_win()
    local output_buf = setup_output_buffer(bufnr, state)
    local output_win = vim.api.nvim_open_win(output_buf, false, {split = 'right'})
    vim.api.nvim_win_set_option(output_win, "scrolloff", 0)
    vim.api.nvim_win_set_option(output_win, "smoothscroll", true)
    state.split_output_win = output_win
    state.split_scrolling = 0

    state.split_augroup = vim.api.nvim_create_augroup('nvim-marimo.split.'..bufnr, {clear = true})

    vim.api.nvim_create_autocmd("WinScrolled", {group = state.split_augroup, callback = function()
        for win, _ in pairs(vim.v.event) do
            win = tonumber(win)
            local buf = win and vim.api.nvim_win_get_buf(win)
            if (buf == output_buf or buf == bufnr) and (win == state.split_main_win or win == output_win) then
                sync_scroll(bufnr, state)
                break
            end
        end
    end})
    vim.api.nvim_create_autocmd("WinResized", {group = state.split_augroup, callback = function()
        for _, win in ipairs(vim.v.event.windows) do
            local buf = vim.api.nvim_win_get_buf(win)
            if (buf == output_buf or buf == bufnr) and (win == state.split_main_win or win == output_win) then
                M.render(bufnr, state)
                break
            end
        end
    end})
end

function M.disable(bufnr, state)
    vim.api.nvim_del_augroup_by_id(state.split_augroup)
    vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
    if state.split_output_win then
        vim.api.nvim_win_close(state.split_output_win, true)
    end
    if state.split_output_buf then
        vim.api.nvim_buf_delete(state.split_output_buf, {force = true})
    end
end

return M
