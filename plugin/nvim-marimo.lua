vim.api.nvim_set_hl(0, 'MarimoStderr', {default = true, link = 'DiagnosticError'})
vim.api.nvim_set_hl(0, 'MarimoStdout', {default = true})
vim.api.nvim_set_hl(0, 'MarimoBorder', {default = true, fg = 'NvimDarkGrey4'})

for k, v in pairs{
    MarimoStatus_stale = 'DiagnosticWarn',
    MarimoStatus_idle = 'DiagnosticOk',
    MarimoStatus_exception = 'DiagnosticError',
    MarimoStatus_cancelled = 'DiagnosticError',
    MarimoStatus_interrupted = 'DiagnosticError',
    MarimoStatus_queued = 'DiagnosticWarn',
    MarimoStatus_loading = 'DiagnosticWarn',
    MarimoStatus_running = 'DiagnosticInfo',
    MarimoStatus_marimo_error = 'DiagnosticError',
    MarimoStatus_unknown = 'DiagnosticWarn',
} do
    vim.api.nvim_set_hl(0, k, vim.tbl_extend('keep', {default = true, bold = true, reverse = true}, vim.api.nvim_get_hl(0, {name = v, create = true})))
end
