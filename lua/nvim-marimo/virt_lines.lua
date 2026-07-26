local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("nvim-marimo.virt_lines")
local SEP = string.rep('─', 9999)

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

    vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)

    for i, cell_info in ipairs(cells) do
        -- vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, cell_info.start_row, 0, {virt_text = {{SEP, 'Comment'}}})

        local virt_lines = {}
        local data = state.cell_data[i] or {status = "unknown"}

        local status = data.status
        if status == 'idle' then
            status = 'success'
        end
        table.insert(virt_lines, {{'('..status..')', 'MarimoStatus_' .. data.status:gsub('%-', '_')}, {SEP, 'MarimoBorder'}})

        if data.console_outputs then
            for _, out in ipairs(data.console_outputs) do
                local hl = (out.channel == "stderr") and "MarimoStderr" or "MarimoStdout"
                local trimmed = (out.data or ''):gsub('\n$', '')
                if trimmed ~= '' then
                    for line in vim.gsplit(trimmed, "\n") do
                        table.insert(virt_lines, {{line, hl}})
                    end
                end
            end
        end
        if #virt_lines > 1 then
            table.insert(virt_lines[1], 1, {'╭─', 'MarimoBorder'})
            for j = 2, #virt_lines do
                table.insert(virt_lines[j], 1, {'│ ', 'MarimoBorder'})
            end
            table.insert(virt_lines, {{'╰─'..SEP, 'MarimoBorder'}})
        else
            table.insert(virt_lines[1], 1, {'──', 'MarimoBorder'})
        end
        vim.api.nvim_buf_set_extmark(bufnr, NAMESPACE, cell_info.end_row, 0, {virt_lines = virt_lines})
    end
end

function M.enable(bufnr, state)
    -- nothing
end

function M.disable(bufnr, state)
    vim.api.nvim_buf_clear_namespace(bufnr, NAMESPACE, 0, -1)
end

return M
