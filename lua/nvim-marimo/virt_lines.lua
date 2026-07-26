local M = {}

local NAMESPACE = vim.api.nvim_create_namespace("nvim-marimo.virt_lines")
local SEP = string.rep('-', 9999)

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

        local data = state.cell_data[i] or {status = "unknown"}
        local virt_lines = {}
        table.insert(virt_lines, {{'[' .. data.status:upper() .. ']', 'WarningMsg'}, {' '}, {SEP, 'Comment'}})
        if data.console_outputs then
            for _, out in ipairs(data.console_outputs) do
                local hl = (out.channel == "stderr") and "ErrorMsg" or ""
                local trimmed = (out.data or ''):gsub('\n$', '')
                if trimmed ~= '' then
                    for line in vim.gsplit(trimmed, "\n") do
                        table.insert(virt_lines, {{line, hl}})
                    end
                end
            end
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
