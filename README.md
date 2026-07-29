# nvim-marimo

Neovim plugin to run marimo notebooks and show output inside neovim.

<img width="300" src="https://github.com/user-attachments/assets/5b489b2c-6138-4c65-bd16-1afbd95281a1" />


> NOTE: This codebase was developed with AI assistance

> NOTE: This plugin makes use of the experimental [marimo-pair](https://github.com/marimo-team/marimo-pair) API

## Installation

This is a normal Neovim plugin, plonk it somewhere in your `runtimepath` using your preferred plugin manager.

However you also need to have:
* `marimo` (for obvious reasons)
* `curl` with websocket support

## Usage

This plugin must be enabled *per-buffer*, it will not automatically enable itself
(nor is there any `filetype` or `ftdetect` support).

Enable this plugin by running: `require("nvim-marimo").enable(bufnr, opts)`.

`bufnr` may be `0` to indicate the current buffer.

`opts` is a table which takes the following keys:
* `url` - url to the marimo server. A lot of the time this may be `http://127.0.0.1:2718`
* `curl_args` - additional args for `curl` when connecting to the marimo server.
* `render_style` - one of `virt_lines` (default), `split` or `nothing`. This controls the way cell output is rendered.

If *no* `opts.url` is given, then `marimo edit ...` will be started on a random port.
Use `opts.url` to connect to an existing `marimo edit ...` server.
It is recommended to run with `marimo edit --watch ...` otherwise it might not work great.

Note that since this must be called *for each* marimo buffer you want it on,
it allows you to have different options per buffer.

Once the plugin is enabled, the following commands will be defined:
* `MarimoRefresh` - refreshes/re-renders the cell output
* `MarimoRun` - run the cell the cursor is currently on (and any stale ancestors it requires)
* `MarimoRunAllStale` - run all stale cells
* `MarimoInterrupt` - interrupt any running cell
* `MarimoReformat` - ask marimo to reformat the current cell;
    this is probably not that useful since `marimo edit --watch` should already do it for you.
* `MarimoOpenFloat` - open the cell output in buffer in a floating window.
    If you are using the `virt_lines` rendering, it truncates after 10 lines, so this allows you to see more
    and also select the text.

No keybinds are defined.

### Auto-enabling

You can try something like:
```lua
vim.api.nvim_create_autocmd('FileType', {pattern = 'python', callback = function(args)
    if table.concat(vim.api.nvim_buf_get_lines(args.buf, 0, 100, false), '\n'):find('\nimport marimo\n') then
        require('nvim-marimo').enable(args.buf, {})
    end
})
```

This plugin also supports markdown based marimo notebooks, so you may also want to something there.

## Highlights

There are some highlights defined in [./plugin/nvim-marimo.lua](./plugin/nvim-marimo.lua)
that you can customise, they should be pretty self explanatory.

## Split rendering

Using `opts.render_style = 'split'` shows the cell output in a split on the right.
This plugin tries to keep them in sync with scrolling etc, but expect it to be janky.

<img width="500" src="https://github.com/user-attachments/assets/76d5bb48-cf40-4661-afdc-3dd6439f48bf" />
