local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("nvim-marimo.virt_lines")
local MAX_LINES = 10
local BORDER = {
    topleft = '╭',
    horizontal = '─',
    vertical = '│',
    bottomleft = '╰',
}
local SEP = string.rep(BORDER.horizontal, 9999)

local function hide_all_windows(windows)
    for i = 1, #windows do
        if windows[i].win then
            vim.api.nvim_win_hide(windows[i].win)
        end
    end
end

local function update_buf(bufnr, state, i, cells, redraw)
    local cell_info = cells[i]
    local cell_data = state.cell_data[i]

    state.inline_float_cells[i] = state.inline_float_cells[i] or {}
    local data = state.inline_float_cells[i]

    data.extmark = data.extmark or vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, cell_info.end_row, 0, {virt_lines = {}})
    local extmark = vim.api.nvim_buf_get_extmark_by_id(bufnr, NAMESPACE, data.extmark, {details = true})
    if not extmark or not extmark[3] or extmark[3].invalid then
        data.extmark = nil
        return
    end

    data.bufnr = data.bufnr or vim.api.nvim_create_buf(false, true)

    if redraw then
        vim.api.nvim_buf_clear_namespace(data.bufnr, NAMESPACE, 0, -1)
        vim.api.nvim_buf_set_lines(data.bufnr, 0, -1, true, {})
        if cell_data.console_outputs then
            for _, out in ipairs(cell_data.console_outputs) do
                local trimmed = (out.data or ''):gsub('\n$', '')
                if trimmed ~= '' then
                    local hl = (out.channel == "stderr") and "MarimoStderr" or "MarimoStdout"
                    local start = vim.api.nvim_buf_line_count(data.bufnr)
                    local lines = vim.split(trimmed, '\n')
                    vim.api.nvim_buf_set_lines(data.bufnr, -1, -1, true, lines)
                    vim.api.nvim_buf_set_extmark(data.bufnr, NAMESPACE, start, 0, {hl_group = hl, end_row = start + #lines - 1, end_col = #lines[#lines]})
                end
            end
        end
        data.height = math.min(vim.api.nvim_buf_line_count(data.bufnr) - 1, MAX_LINES)
        -- delete first blank line
        vim.api.nvim_buf_set_lines(data.bufnr, 0, 1, true, {})
    end

    local status = cell_data.status
    if status == 'idle' then
        status = 'success'
    end

    local height = data.height or 0

    local full_height = height < 1 and 1 or height + 2
    local virt_lines = extmark[3].virt_lines or {}
    if #virt_lines ~= full_height or virt_lines[1][2][1] ~= '('..status..')' then
        while #virt_lines < full_height do
            table.insert(virt_lines, {})
        end
        while #virt_lines > full_height do
            table.remove(virt_lines)
        end
        virt_lines[1] = {
            {BORDER.topleft .. BORDER.horizontal, 'MarimoBorder'},
            {'('..status..')', 'MarimoStatus_' .. cell_data.status:gsub('%-', '_')},
            {SEP, 'MarimoBorder'},
        }
        if #virt_lines > 1 then
            virt_lines[#virt_lines] = {
                {BORDER.bottomleft .. SEP, 'MarimoBorder'},
            }
        else
            virt_lines[1][1][1] = string.rep(BORDER.horizontal, 2)
        end
        for i = 2, #virt_lines - 1 do
            virt_lines[i][1] = {BORDER.vertical, 'MarimoBorder'}
        end

        extmark[3].id = data.extmark
        extmark[3].ns_id = nil
        extmark[3].virt_lines = virt_lines
        vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, extmark[1], extmark[2], extmark[3])
    end

end

local function update_win(parentwin, state, i, cells)
    local cell_info = cells[i]

    state.inline_float_wins[parentwin.winid][i] = state.inline_float_wins[parentwin.winid][i] or {}
    local data = state.inline_float_wins[parentwin.winid][i]

    if not state.inline_float_cells[i].extmark then
        -- delete
        if data.win then
            vim.api.nvim_win_hide(data.win)
            data.win = nil
        end
        return
    end

    local row = cell_info.end_row
    local config = {
        height = state.inline_float_cells[i].height or 0,
        width = parentwin.width - parentwin.textoff - 2,
        relative = 'win',
        win = parentwin.winid,
        bufpos = {row, 0},
        anchor = 'NW',
        fixed = true,
        row = 2,
        col = 1,
        zindex = 1,
    }

    local show = true
    if row < parentwin.topline - 2 or row > parentwin.botline - 1 then
        -- off screen
        show = false
    elseif row == parentwin.topline - 2 then
        -- show at top
        local space = vim.fn.screenpos(parentwin.winid, row + 2, 0).row - parentwin.winrow
        if space <= 1 then
            -- not enough space
            show = false
        elseif space <= config.height + 2 then
            config.bufpos[1] = row + 1 -- attach to the next line instead
            config.anchor = 'SW'
            config.row = -1
            config.height = math.min(config.height, space - 1)
        end
    elseif row == parentwin.botline - 1 then
        -- show at bottom
        local space = parentwin.height - vim.fn.screenpos(parentwin.winid, row + 1, 0).row + 1
        if space <= 1 then
            -- not enough space
            show = false
        elseif space <= config.height + 2 then
            config.height = math.min(config.height, space - 1)
        end
    end

    if not show or config.height < 1 then
        if data.win then
            vim.api.nvim_win_hide(data.win)
            data.win = nil
        end
    elseif not data.win then
        data.win = vim.api.nvim_open_win(state.inline_float_cells[i].bufnr, false, config)
        -- vim.api.nvim_win_set_option(data.win, 'winhighlight', 'NormalNC:Normal')
        vim.api.nvim_win_set_option(data.win, 'smoothscroll', true)
    else
        local old_config = vim.api.nvim_win_get_config(data.win)
        local reset_config = false
        for k, v in pairs(config) do
            reset_config = reset_config or not vim.deep_equal(v, old_config[k])
        end

        if reset_config then
            vim.api.nvim_win_set_config(data.win, config)
        end
    end

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

    for i = 1, #cells do
        update_buf(bufnr, state, i, cells, true)
    end

    for _, v in pairs(state.inline_float_wins) do
        v.valid = false
    end

    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
            state.inline_float_wins[winid] = state.inline_float_wins[winid] or {}
            state.inline_float_wins[winid].valid = true
            local parentwin = vim.fn.getwininfo(winid)[1]
            if parentwin then
                for i = 1, #cells do
                    update_win(parentwin, state, i, cells)
                end
            end
            local win = state.inline_float_wins[winid]
            for i = #cells + 1, #win do
                if win[i].win then
                    vim.api.nvim_win_hide(win[i].win)
                end
                if win[i].buf then
                    vim.api.nvim_buf_delete(win[i].buf, {force = true})
                end
            end
        end
    end

    for k, v in pairs(state.inline_float_wins) do
        if not v.valid then
            hide_all_windows(v)
            state.inline_float_wins[k] = nil
        end
    end

end

function M.enable(bufnr, state)
    state.inline_float_augroup = vim.api.nvim_create_augroup('nvim-marimo.inline_float.'..bufnr, {clear = true})
    vim.api.nvim_buf_set_keymap(bufnr, 'n', '<ScrollWheelDown>', '3<c-e>', {noremap = true})
    vim.api.nvim_buf_set_keymap(bufnr, 'n', '<ScrollWheelUp>', '3<c-y>', {noremap = true})

    state.inline_float_cells = {}
    state.inline_float_wins = {}

    local rendering = false
    local events = {'BufWinEnter', 'WinNew', 'WinClosed', 'WinScrolled', 'TextChanged', 'TextChangedI', 'TextChangedP'}
    vim.api.nvim_create_autocmd(events, {group = state.inline_float_augroup, callback = function(args)
        if not rendering then
            rendering = true
            vim.schedule(function()
                rendering = false
                M.render(bufnr, state)
            end)
        end
    end})

end

function M.disable(bufnr, state)
    for _, win in pairs(state.inline_float_wins) do
        hide_all_windows(win)
    end
    state.inline_float_wins = nil
    for _, cell in pairs(state.inline_float_cells) do
        if cell.buf then
            vim.api.nvim_buf_delete(cell.buf, {force = true})
        end
    end
    state.inline_float_cells = nil
    vim.api.nvim_del_augroup_by_id(state.inline_float_augroup)
    vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
end

return M
