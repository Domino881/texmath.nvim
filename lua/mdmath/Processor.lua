local vim = vim
local api = vim.api
local uv = vim.loop
local config = require'mdmath.config'.opts
local util = require'mdmath.util'
local bit = require'bit'

local plugin_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local processor_dir = plugin_dir .. '/mdmath-js'

local get_next_id
do
    local id = 0
    get_next_id = function()
        id = id + 1
        return tostring(id)
    end
end

local function has(flags, flag)
    return bit.band(flags, flag) == flag
end

local PROCESS_PATH = processor_dir .. '/src/processor.js'

local Processor = util.class 'Processor'

function Processor:_assert(condition, ...)
    local message = table.concat(vim.iter({ ... }):flatten():totable())
    if not condition then
        self:close()
        error(message)
    end
end

function Processor:_on_data(identifier, data_type, width, height, data)
    local callback = self.callbacks[identifier]
    if not callback then
        return util.err_message('no callback for identifier: ', identifier)
    end
    self.callbacks[identifier] = nil

    if data_type == 'image' then
        callback({
            width = width,
            height = height,
            data = data
        })
    elseif data_type == 'error' then
        callback(nil, data)
    end
end

-- function Processor:setForeground(color)
--     if type(color) == 'number' then
--         color = string.format('#%06x', color)
--     elseif type(color) ~= 'string' then
--         error('color: expected string|number, got ' .. type(color))
--     end

--     local code, err = self.pipes[0]:write(string.format("0:fgcolor:%s:", color))
--     self:_assert(not err, 'failed to set foreground: ', err)
-- end

function Processor:setInternalScale(scale)
    local code, err = self.pipes[0]:write(string.format("0:iscale:%.2f:", scale))
    self:_assert(not err, 'failed to set internal scale: ', err)
end

function Processor:setDynamicScale(scale)
    local code, err = self.pipes[0]:write(string.format("0:dscale:%.2f:", scale))
    self:_assert(not err, 'failed to set dynamic scale: ', err)
end

function Processor:request(data, cell_width, cell_height, width, height, flags, color, callback)
    -- width/height should be number of cells
    -- flags: 0: none, 1: dynamic, 2: center, 3: dynamic + center
    --        TODO: flags should be a enum

    local identifier = get_next_id()
    if self.callbacks[identifier] then
        return util.err_message('identifier already in use: ', identifier, ' (how the hell did this happen?)')
    end
    self.callbacks[identifier] = callback

    local code, err =
        self.pipes[0]:write(string.format("%s:request:%d:%s:%d:%d:%d:%d:%d:%s",
            identifier, flags, color, cell_width, width, cell_height, height, #data, data))

    self:_assert(not err, 'failed to request: ', err)
end

function Processor:_listen()
    local separator = string.byte(':')

    -- TODO: use JSON instead of custom protocol 
    local states = {
        READING_IDENTIFIER = 0,
        READING_TYPE = 1,
        READING_WIDTH = 2,
        READING_HEIGHT = 3,
        READING_LENGTH = 4,
        READING_DATA = 5
    }

    local state = states.READING_IDENTIFIER
    local identifier = ""
    local data_type = ""
    local width = 0
    local height = 0
    local length = 0
    local buffer = {}

    local function process_byte(byte)
        if state == states.READING_IDENTIFIER then
            if byte == separator then
                identifier = table.concat(buffer)
                buffer = {}
                state = states.READING_TYPE
            else
                table.insert(buffer, string.char(byte))
            end
        elseif state == states.READING_TYPE then
            if byte == separator then
                data_type = table.concat(buffer)
                self:_assert(data_type == "image" or data_type == "error", "Invalid data type: ", data_type)
                buffer = {}
                state = states.READING_WIDTH
            else
                table.insert(buffer, string.char(byte))
            end
        elseif state == states.READING_WIDTH then
            if byte == separator then
                local width_str = table.concat(buffer)
                width = tonumber(width_str)
                self:_assert(width, "Invalid width: ", width_str)
                buffer = {}
                state = states.READING_HEIGHT
            else
                table.insert(buffer, string.char(byte))
            end
        elseif state == states.READING_HEIGHT then
            if byte == separator then
                local height_str = table.concat(buffer)
                height = tonumber(height_str)
                self:_assert(height, "Invalid height: ", height_str)
                buffer = {}
                state = states.READING_LENGTH
            else
                table.insert(buffer, string.char(byte))
            end
        elseif state == states.READING_LENGTH then
            if byte == separator then
                local length_str = table.concat(buffer)
                length = tonumber(length_str)
                self:_assert(length, "Invalid length: ", length_str)
                buffer = {}
                state = states.READING_DATA
            else
                table.insert(buffer, string.char(byte))
            end
        elseif state == states.READING_DATA then
            table.insert(buffer, string.char(byte))
            if #buffer == length then
                self:_on_data(identifier, data_type, width, height, table.concat(buffer))
                state = states.READING_IDENTIFIER
                buffer = {}
            end
        end
    end

    local code, err = uv.read_start(self.pipes[1], function(err, data)
        if data then
            for i = 1, #data do
                local byte = data:byte(i)
                process_byte(byte)
            end
        end
    end)

    self:_assert(code == 0, 'failed to start reading from out pipe: ', err)
end

function Processor:_init()
    self.callbacks = {}

    local err
    self.pipes = {}
    for i = 0, 2 do
        self.pipes[i], err = uv.new_pipe()
        self:_assert(self.pipes[i], 'failed to open pipe ', i, ': ', err)
    end

    self.is_closing = false
    self.closed = false

    self.handle, err = uv.spawn('node', {
        args = { PROCESS_PATH },
        stdio = { self.pipes[0], self.pipes[1], self.pipes[2] }
    }, function(code, signal)
        if code == 0 and signal == 0 then
            self:_assert(not self.is_closing, 'processor closed unexpectedly')

            self.is_closing = false
            self.closed = true
        else
            local err = table.concat(self.err_buffer)
            self:close()
            error('processor runtime error: ' .. err)
        end
    end)
    self:_assert(self.handle, 'failed to spawn LatexProcessor: ', err)

    self.err_buffer = {}
    local code, err = uv.read_start(self.pipes[2], function(err, data)
        if data then
            table.insert(self.err_buffer, data)
        end
    end)
    self:_assert(code == 0, 'failed to start reading from err pipe: ', err)

    self:_listen()

    -- self:setForeground(config.foreground)
    self:setInternalScale(config.internal_scale)
    self:setDynamicScale(config.dynamic_scale)
end

function Processor:close()
    if self.closed or self.is_closing then
        return
    end

    self.is_closing = true
    self.callbacks = nil

    for i = 0, 2 do
        if self.pipes[i] then
            self.pipes[i]:close()
            self.pipes[i] = nil
        end
    end
    if self.handle ~= nil then
        self.handle:close()
        self.handle = nil
    end
end

local processor = nil
local ref_count = 0
local buffers = {}

local M = {}

local function detach(bufnr)
    ref_count = ref_count - 1
    if ref_count == 0 and processor then
        processor:close()
        processor = nil
    end
end

local function on_detach(_, bufnr)
    if buffers[bufnr] == false then
        buffers[bufnr] = nil
    elseif buffers[bufnr] == true then
        buffers[bufnr] = nil
        detach(bufnr)
    end
end

function M.from_bufnr(bufnr)
    assert(type(bufnr) == 'number', 'bufnr is required')
    bufnr = bufnr == 0 and api.nvim_get_current_buf() or bufnr

    if buffers[bufnr] then
        return processor
    end

    if ref_count == 0 then
        processor = Processor.new()
    end
    ref_count = ref_count + 1

    local should_attach = (buffers[bufnr] == nil)
    buffers[bufnr] = true

    if should_attach then
        local success = api.nvim_buf_attach(bufnr, false, {
            on_detach = on_detach,
        })
        if not success then
            buffers[bufnr] = nil
            detach(bufnr)
            error('failed to attach to buffer ' .. bufnr)
        end
    end

    return processor
end

function M.stop_instance()
    for bufnr, _ in pairs(buffers) do
        if buffers[bufnr] then
            -- mark false to prevent on_detach from being called multiple times
            buffers[bufnr] = false 
            detach(bufnr)
        end
    end
end

return M
