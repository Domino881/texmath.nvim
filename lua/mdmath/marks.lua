-- TODO: This code needs to be basically rewritten. It's a mess.

local vim = vim
local util = require'mdmath.util'
local hl = require'mdmath.highlight-colors'
local tracker = require'mdmath.tracker'
local nvim = require'mdmath.nvim'
local config = require'mdmath.config'.opts

local ns = nvim.create_namespace('mdmath-marks')

local Mark = util.class 'Mark'
local buffers = {}
local num_buffers = 0

function Mark:_init(bufnr, row, col, opts)
    self.bufnr = bufnr
    self.opts = opts
    self.visible = false
    self.extmark_ids = {}
    self.render_visible = false

    -- FIX: Currently, lines that are smaller than the current line doesn't override the
    --      text below it. Although this is not intended, I don't think it's worth fixing it now.
    if opts.lines then
        self.total_lines = #opts.lines

        self.lengths = {}
        for _, line in ipairs(opts.lines) do
            local length = line[2]
            if length >= 0 then
                table.insert(self.lengths, length)
            end
        end
        self.num_lines = #self.lengths
    else
        self.num_lines = 1
        self.lengths = { opts.text[2] }
    end

    local row_end, col_end 
    if self.num_lines > 1 then
        row_end = row + self.num_lines - 1
        col_end = self.lengths[self.num_lines]
    else
        row_end = row
        col_end = col + self.lengths[1]
    end

    self.pos = tracker.add(bufnr, row, col, row_end, col_end)
    self.pos.on_finish = function()
        self:remove()
    end
end

function Mark:remove()
    buffers[self.bufnr]:remove(self.id)
end

function Mark:contains(row, col)
    local srow, scol = unpack(self.pos)
    if self.num_lines == 1 then
        return srow == row and scol <= col and col < scol + self.lengths[1]
    end

    if row < srow or row >= srow + self.num_lines then
        return false
    end

    if row == srow then
        return col >= scol
    end

    if row == srow + self.num_lines - 1 then
        return col < self.lengths[self.num_lines]
    end

    return true
end

function Mark:set_visible(visible)
    if self.visible == visible then
        return
    end

    self.visible = visible
end

local Buffer = util.class 'Buffer'

function Buffer:_init(bufnr)
    self.bufnr = bufnr
    self.marks = {}
    self._show = true
end

function Buffer:redraw()
    nvim._redraw({
        buf = self.bufnr,
        valid = false,
    })
end

function Buffer:add(mark)
    assert(mark.bufnr == self.bufnr)

    local id = #self.marks + 1
    mark.id = id
    self.marks[id] = mark

    mark:set_visible(true)
    return id
end

function Buffer:remove(id)
    local mark = self.marks[id]
    if mark then
        for _, id in ipairs(mark.extmark_ids) do
            nvim.buf_del_extmark(self.bufnr, ns, id)
        end
        mark.extmark_ids = {}

        mark.visible = false
        mark.render_visible = false

        mark.pos:cancel()
        self.marks[id] = nil
    end
end

function Buffer:show(show)
    if self._show == show then
        return
    end

    assert(type(show) == 'boolean')
    self._show = show
    self:redraw()

    -- local bufnr = self.bufnr
    -- if not show then
    --     -- forcefully hide all marks without modifying visibility
    --     nvim.buf_clear_namespace(bufnr, ns, 0, -1)
    --     for _, mark in pairs(self.marks) do
    --         mark.id = nil -- do not change visibility, only forcefully hide
    --     end
    -- else
    --     for _, mark in pairs(self.marks) do
    --         mark:flush() -- flush visibility
    --     end
    -- end 
end

function Buffer:clear()
    self.marks = {}
    self:redraw()
end

do
    local function on_delete(opts)
        local bufnr = opts.buf
        if rawget(buffers, bufnr) ~= nil then
            buffers[bufnr] = nil
            num_buffers = num_buffers - 1
        end
    end

    local function on_cursor(opts)
        if not config.anticonceal then
            return
        end
        local buffer = buffers[opts.buf]
        local row, col = util.get_cursor()

        for _, mark in pairs(buffer.marks) do
            local visible = not mark:contains(row, col)
            mark:set_visible(visible)
        end
    end

    local function on_mode_change(opts)
        local buffer = buffers[opts.buf]
        local old_mode = vim.v.event.old_mode:sub(1, 1)
        local mode = vim.v.event.new_mode:sub(1, 1)
        if old_mode == mode then
            return
        end

        if mode == 'n' then
            on_cursor(opts)
        end

        local hide = config.hide_on_insert and (mode == 'i' or mode == 'R')
        buffer:show(not hide)
    end

    setmetatable(buffers, {
        __index = function(_, bufnr)
            if bufnr == 0 then
                return buffers[nvim.get_current_buf()]
            end

            nvim.create_autocmd({'BufWipeout'}, {
                buffer = bufnr,
                callback = on_delete,
            })

            nvim.create_autocmd({'ModeChanged'}, {
                buffer = bufnr,
                callback = on_mode_change,
            })

            nvim.create_autocmd({'CursorMoved'}, {
                buffer = bufnr,
                callback = on_cursor,
            })

            local buf = Buffer.new(bufnr)
            buffers[bufnr] = buf
            num_buffers = num_buffers + 1
            return buf
        end,
    })
end

-- TODO: This can be done once instead of every redraw
local function opts2extmark(opts, row, col)
    if opts.lines then
        local extmarks = {}

        local is_last_virtual = false
        for _, line in ipairs(opts.lines) do
            local row_data = { { line[1], opts.color } }
            if line[2] < 0 then
                if not is_last_virtual then
                    local data = {
                        virt_lines = { row_data },
                        ephemeral = false,
                        undo_restore = false,
                    }
                    table.insert(extmarks, {
                        data = data,
                        row = row - 1,
                        col = col,
                    })
                else -- If the last line was virtual, just merge with it.
                    table.insert(extmarks[#extmarks].data.virt_lines, row_data)
                end
                is_last_virtual = true
            else
                local data = {
                    virt_text = row_data,
                    virt_text_pos = 'overlay',
                    virt_text_hide = true,
                    ephemeral = false,
                    undo_restore = false,
                }
                table.insert(extmarks, {
                    data = data,
                    row = row,
                    col = col,
                })
                row = row + 1
                is_last_virtual = false
            end
            col = 0 -- reset col for next line
        end
        return extmarks, true
    else
        local data = {
            virt_text = { { opts.text[1], opts.color } },
            virt_text_pos = opts.text_pos,
            virt_text_hide = true,
            ephemeral = false,
            undo_restore = false,
        }
        return { {
            data = data,
            row = row,
            col = col
        } }, false
    end
end

local function create_empty_virtual(opts, row)
    if not opts.lines then
        return nil
    end

    local virtual = 0
    for _, line in ipairs(opts.lines) do
        if line[2] >= 0 then
            row = row + 1
        else
            virtual = virtual + 1
        end
    end

    local lines = {}
    for i = 1, virtual do
        table.insert(lines, { { '', opts.color } })
    end

    local data = {
        virt_lines = lines,
        virt_lines_above = true,
        ephemeral = false,
        undo_restore = false,
    }

    return {
        row = row,
        data = data
    }
end

function Mark:_draw(visible)
    local row, col = unpack(self.pos)

    for _, id in ipairs(self.extmark_ids) do
        nvim.buf_del_extmark(self.bufnr, ns, id)
    end
    self.extmark_ids = {}

    if not visible then
        local virtual = create_empty_virtual(self.opts, row)
        if virtual then
            local id = nvim.buf_set_extmark(self.bufnr, ns, virtual.row, 0, virtual.data)
            table.insert(self.extmark_ids, id)
        end
        return
    end

    local extmarks, lines = opts2extmark(self.opts, row, col)

    for i, extmark in ipairs(extmarks) do
        local id = nvim.buf_set_extmark(self.bufnr, ns, extmark.row, extmark.col, extmark.data)
        table.insert(self.extmark_ids, id)
    end
end

function Mark:flush(hidden)
    local visible = not hidden and self.visible
    if visible ~= self.render_visible then
        local ok, err = pcall(self._draw, self, visible)
        if not ok then
            vim.schedule(function()
                self:remove()
                nvim.err_writeln('mdmath: failed to draw mark: ' .. err)
            end)
        end
        self.render_visible = visible
        return true
    end
    return false
end

local M = {}

function M.show(bufnr, show)
    show = show == nil and true or show
    buffers[bufnr]:show(show)
end

function M.add(bufnr, row, col, opts)
    bufnr = bufnr == 0 and nvim.get_current_buf() or bufnr

    if type(opts.color) == 'number' then
        opts.color = hl[opts.color]
    end
    opts.text_pos = opts.text_pos or 'overlay'

    local mark = Mark.new(bufnr, row, col, opts)
    return buffers[bufnr]:add(mark)
end

function M.remove(bufnr, id)
    buffers[bufnr]:remove(id)
end

function M.clear(bufnr)
    bufnr = bufnr or nvim.get_current_buf()
    buffers[bufnr]:clear()
end

do
    nvim.set_decoration_provider(ns, {
        on_start = function()
            if num_buffers == 0 then
                return false
            end
        end,
        on_win = function(_, _, bufnr, top, bot)
            buffer = rawget(buffers, bufnr)
            if not buffer then
                return false
            end
            top = top - 1

            for _, self in pairs(buffer.marks) do
                local frow = self.pos[1]
                local lrow = self.pos[1] + self.num_lines - 1

                if top <= lrow and frow <= bot then
                    self:flush(not buffer._show)
                end
            end
            return false
        end,
    })
end

return M
