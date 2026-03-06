local ffi = require("ffi")
local bit = require("bit")

local png = {}

local byte, char, concat = string.byte, string.char, table.concat
local band, bxor, rshift = bit.band, bit.bxor, bit.rshift
local insert = table.insert

ffi.cdef[[
    unsigned long compressBound(unsigned long sourceLen);
    int compress2(uint8_t *dest, unsigned long *destLen,
                  const uint8_t *source, unsigned long sourceLen, int level);
]]

local zlib = ffi.load("z.so.1")

local function u32_bytes(n)
    return char(
        band(rshift(n, 24), 0xff),
        band(rshift(n, 16), 0xff),
        band(rshift(n, 8), 0xff),
        band(n, 0xff)
    )
end

local CRC_TABLE = {}
for i = 0, 255 do
    local r = i
    for _ = 1, 8 do
        if band(r, 1) == 1 then
            r = bxor(rshift(r, 1), 0xEDB88320)
        else
            r = rshift(r, 1)
        end
    end
    CRC_TABLE[i] = r
end

local function crc32(data)
    local c = 0xFFFFFFFF
    for i = 1, #data do
        c = bxor(rshift(c, 8), CRC_TABLE[band(bxor(c, byte(data, i)), 0xFF)])
    end
    return bxor(c, 0xFFFFFFFF)
end

local function make_chunk(ctype, data)
    local payload = ctype .. data
    return u32_bytes(#data) .. payload .. u32_bytes(crc32(payload))
end

local function deflate(raw)
    local src = ffi.new("uint8_t[?]", #raw)
    ffi.copy(src, raw, #raw)
    local bound = zlib.compressBound(#raw)
    local dst = ffi.new("uint8_t[?]", bound)
    local dst_len = ffi.new("unsigned long[1]", bound)
    local ret = zlib.compress2(dst, dst_len, src, #raw, 9)
    if ret ~= 0 then error("zlib error: " .. ret) end
    return ffi.string(dst, dst_len[0])
end

local MAGIC = "\137PNG\r\n\26\n"

function png.encode(width, height, pixels)
    local raw = {}
    for y = 0, height - 1 do
        insert(raw, "\0")
        for x = 0, width - 1 do
            local px = pixels[y * width + x] or { 0, 0, 0 }
            insert(raw, char(px[1], px[2], px[3]))
        end
    end

    local ihdr = u32_bytes(width)
        .. u32_bytes(height)
        .. char(8, 2, 0, 0, 0)

    return MAGIC
        .. make_chunk("IHDR", ihdr)
        .. make_chunk("IDAT", deflate(concat(raw)))
        .. make_chunk("IEND", "")
end

return png
