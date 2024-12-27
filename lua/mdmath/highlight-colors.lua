local api = vim.api

local H = {}

local HIGHLIGHT_NAME_PREFIX = '@mdmath-id-'

local function is_integer(n)
    return type(n) == 'number' and n == math.floor(n)
end

setmetatable(H, {
    __index = function(self, key)
        assert(is_integer(key), "key must be a number")
        assert(key >= 1 and key <= 0xFFFFFF, 'key must be in a 24-bit color range')

        local name = HIGHLIGHT_NAME_PREFIX .. tostring(key)
        if key < 256 then
            api.nvim_command(string.format('highlight %s guifg=#%06X ctermfg=%d', name, key, key))
        else
            api.nvim_command(string.format('highlight %s guifg=#%06X', name, key))
        end
        self[key] = name
        return name
    end
})

return H
