local ffi = require("ffi")
local bit = require("bit")

local pngdecode = {}

local byte, sub, concat = string.byte, string.sub, table.concat
local band = bit.band
local floor, abs = math.floor, math.abs

ffi.cdef[[
    int uncompress(uint8_t *dest, unsigned long *destLen,
                   const uint8_t *source, unsigned long sourceLen);
]]

local zlib = ffi.load("z.so.1")

-- helpers --

local function read_u32(data, offset)
    local a, b, c, d = byte(data, offset, offset + 3)
    return a * 16777216 + b * 65536 + c * 256 + d
end

local function paeth(a, b, c)
    local p = a + b - c
    local pa = abs(p - a)
    local pb = abs(p - b)
    local pc = abs(p - c)
    if pa <= pb and pa <= pc then return a
    elseif pb <= pc then return b
    else return c end
end

-- decode --

function pngdecode.decode(data)
    if sub(data, 1, 8) ~= "\137PNG\r\n\26\n" then
        return nil, "not a PNG file"
    end

    local pos = 9
    local width, height, bit_depth, color_type
    local idat_parts = {}
    local idat_n = 0

    while pos <= #data do
        local length = read_u32(data, pos)
        local chunk_type = sub(data, pos + 4, pos + 7)
        local chunk_data = sub(data, pos + 8, pos + 7 + length)
        pos = pos + 12 + length

        if chunk_type == "IHDR" then
            width = read_u32(chunk_data, 1)
            height = read_u32(chunk_data, 5)
            bit_depth = byte(chunk_data, 9)
            color_type = byte(chunk_data, 10)
        elseif chunk_type == "IDAT" then
            idat_n = idat_n + 1
            idat_parts[idat_n] = chunk_data
        elseif chunk_type == "IEND" then
            break
        end
    end

    if not width then return nil, "missing IHDR" end
    if bit_depth ~= 8 then return nil, "unsupported bit depth: "..tostring(bit_depth) end
    if color_type ~= 6 and color_type ~= 2 then
        return nil, "unsupported color type: "..tostring(color_type)
    end

    local bpp = color_type == 6 and 4 or 3
    local stride = width * bpp

    local compressed = concat(idat_parts)
    local raw_size = height * (1 + stride)
    local raw_buf = ffi.new("uint8_t[?]", raw_size)
    local raw_len = ffi.new("unsigned long[1]", raw_size)
    local comp_buf = ffi.new("uint8_t[?]", #compressed)
    ffi.copy(comp_buf, compressed, #compressed)

    local ret = zlib.uncompress(raw_buf, raw_len, comp_buf, #compressed)
    if ret ~= 0 then return nil, "zlib uncompress failed: "..tostring(ret) end

    local prev_row = ffi.new("uint8_t[?]", stride)
    local curr_row = ffi.new("uint8_t[?]", stride)
    local pixels = {}

    for y = 0, height - 1 do
        local row_start = y * (1 + stride)
        local filter = raw_buf[row_start]

        for i = 0, stride - 1 do
            curr_row[i] = raw_buf[row_start + 1 + i]
        end

        if filter == 1 then
            for i = bpp, stride - 1 do
                curr_row[i] = band(curr_row[i] + curr_row[i - bpp], 0xff)
            end
        elseif filter == 2 then
            for i = 0, stride - 1 do
                curr_row[i] = band(curr_row[i] + prev_row[i], 0xff)
            end
        elseif filter == 3 then
            for i = 0, stride - 1 do
                local a = i >= bpp and curr_row[i - bpp] or 0
                curr_row[i] = band(curr_row[i] + floor((a + prev_row[i]) / 2), 0xff)
            end
        elseif filter == 4 then
            for i = 0, stride - 1 do
                local a = i >= bpp and curr_row[i - bpp] or 0
                local c = i >= bpp and prev_row[i - bpp] or 0
                curr_row[i] = band(curr_row[i] + paeth(a, prev_row[i], c), 0xff)
            end
        end

        for x = 0, width - 1 do
            local off = x * bpp
            local r = curr_row[off]
            local g = curr_row[off + 1]
            local b = curr_row[off + 2]
            local a = bpp == 4 and curr_row[off + 3] or 255
            pixels[y * width + x + 1] = { r, g, b, a }
        end

        ffi.copy(prev_row, curr_row, stride)
    end

    return { width = width, height = height, pixels = pixels }
end

return pngdecode
