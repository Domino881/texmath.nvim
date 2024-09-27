local nvim = require'md-math.nvim'
local util = require'md-math.util'
local ts = vim.treesitter
local uv = vim.uv
local Equation = require'md-math.Equation'

local M = {}
local buffers = {}

local Buffer = util.new_class('Buffer')
local INTERVAL = 1000

-- FIX: Temporary workaround before NeoVim 0.12
local function get_parser(bufnr, lang)
    local parser = ts.get_parser(bufnr, lang)
    if not parser then
        error('Parser not found for ' .. lang, 2)
    end
    
    return parser
end

function Buffer:_init(bufnr)
    self.bufnr = bufnr
    self.equations = {}
    self.parser = get_parser(bufnr, 'markdown')
    self.active = true
    self.timer = uv.new_timer()
    assert(self.timer, 'failed to create a timer')

    self:attach()

    -- nvim.create_autocmd({'BufUnload'}, {
    --     buffer = bufnr,
    --     group = id,
    --     callback = function()
    --         self:free()
    --     end
    -- })

    local id = nvim.create_augroup('MdMathManager', {
        clear = false
    })

    nvim.create_autocmd({'InsertLeave'}, {
        buffer = bufnr,
        group = id,
        callback = function()
            self:parse_view()
        end
    })

    self:parse_view()
end

function Buffer:free()
    if not self.active then
        return
    end
    self.active = false
    buffers[self.bufnr] = nil

    self.timer:stop()
    self.timer:close()
    
    for _, eq in ipairs(self.equations) do
        eq:invalidate()
    end

    nvim.clear_autocmds {
        group = 'MdMathManager',
        buffer = self.bufnr
    }
end

function Buffer:reset_timer()
    self.timer:start(INTERVAL, 0, vim.schedule_wrap(function()
        return self:parse_view()
    end))
end

function Buffer:attach()
    nvim.buf_attach(self.bufnr, false, {
        on_lines = function()
            if not self.active then
                return true
            end
            self:reset_timer()
        end,
        on_detach = function()
            self:free()
        end
    })
end

function Buffer:parse_view()
    local start_row, end_row = util.get_current_view()
    self:parse(start_row, end_row)
end

function Buffer:parse(start_row, end_row)
    assert(type(start_row) == 'number', 'start_row must be a number')
    assert(type(end_row) == 'number', 'end_row must be a number')

    local bufnr = self.bufnr
    local parser = self.parser
    parser:parse({start_row, end_row})

    -- FIX: Almost sure we can move this block to initialization
    local inline_lang = 'markdown_inline'
    local inlines = parser:children()[inline_lang]
    if not inlines then
        return nil
    end
    local query = vim.treesitter.query.parse(inline_lang, '(latex_block) @block')

    local old_equations = self.equations
    local equations = {}

    local function process_equation(sr, sc, er, ec, text)
        -- if sr ~= er then
        --     return
        -- end

        -- FIXME: Iterating over all equations is not efficient, we can use a hash table
        local equation = nil
        for key, eq in ipairs(old_equations) do
            if eq ~= 0 and eq.valid and eq.pos[1] == sr and eq.pos[2] == sc and eq.text == text then
                equation = eq
                old_equations[key] = 0
                break
            end
        end

        equation = equation or Equation.new(bufnr, sr, sc, text)
        if equation then
            table.insert(equations, equation)
        end
    end

    local function get_queries(tree)
        local root = tree:root()

        for _, node in query:iter_captures(root, 0, start_row, end_row) do
            local sr, sc, er, ec = node:range()
            local value = ts.get_node_text(node, 0)

            process_equation(sr, sc, er, ec, value)
        end
    end
    inlines:for_each_tree(get_queries)

    for _, eq in ipairs(old_equations) do
        if eq ~= 0 and eq.valid then
            if (not eq.pos[1] or (start_row <= eq.pos[1] and eq.pos[1] < end_row)) then
                eq:invalidate()
            else
                -- add equations out of the range
                table.insert(equations, eq)
            end
        end
    end

    self.equations = equations
end

local function create_buffer(bufnr)
    if not nvim.buf_is_valid(bufnr) then
        return nil
    end

    local buf = Buffer.new(bufnr)
    buffers[bufnr] = buf
    return buf
end

function M.enable(bufnr)
    if bufnr == 0 then
        bufnr = nvim.get_current_buf()
    end
    if buffers[bufnr] then
        return
    end

    if not create_buffer(bufnr) then
        error('Invalid buffer: ' .. bufnr)
    end
end

-- function M.parse(bufnr, start_row, end_row)
--     local buffer = buffers[bufnr]
--     if not buffer then
--         error('Invalid buffer: ' .. bufnr)
--     end
--     return buffer:parse(start_row, end_row)
-- end

function M.free(bufnr)
    if bufnr == 0 then
        bufnr = nvim.get_current_buf()
    end
    local buffer = buffers[bufnr]
    if buffer then
        buffer:free()
    end
end

function M.free_all()
    for bufnr, buffer in pairs(buffers) do
        buffer:free()
    end
end

return M
