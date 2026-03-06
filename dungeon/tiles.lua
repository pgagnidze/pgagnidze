local png = require("png")
local font = require("font")

local tiles = {}

local format = string.format
local floor = math.floor
local sub = string.sub

-- tile dimensions --

local TILE_SIZE = 50
local GLYPH_W, GLYPH_H = 5, 7
local GLYPH_SCALE = 4
local STATUS_WIDTH = 270
local STATUS_HEIGHT = 40
local MSG_WIDTH = 270
local MSG_HEIGHT = 30

-- pico-8 palette as rgb tables --

local PICO8 = {
    black = { 0, 0, 0 },
    navy = { 29, 43, 83 },
    purple = { 126, 37, 83 },
    green = { 0, 135, 81 },
    brown = { 171, 82, 54 },
    darkgrey = { 95, 87, 79 },
    grey = { 194, 195, 199 },
    white = { 255, 241, 232 },
    red = { 255, 0, 77 },
    orange = { 255, 163, 0 },
    yellow = { 255, 236, 39 },
    lime = { 0, 228, 54 },
    blue = { 41, 173, 255 },
    lavender = { 131, 118, 156 },
    pink = { 255, 119, 168 },
    peach = { 255, 204, 170 },
}

local REMEMBERED_WALL_FG = { 17, 24, 51 }
local REMEMBERED_FLOOR_FG = { 10, 10, 10 }

-- tile definitions: { bg, fg, symbol } --

local TILE_DEFS = {
    wall = { bg = PICO8.navy, fg = PICO8.darkgrey, symbol = "#" },
    floor = { bg = PICO8.black, fg = PICO8.darkgrey, symbol = "." },
    player = { bg = PICO8.black, fg = PICO8.lime, symbol = "@" },
    rat = { bg = PICO8.black, fg = PICO8.brown, symbol = "r" },
    snake = { bg = PICO8.black, fg = PICO8.green, symbol = "s" },
    skeleton = { bg = PICO8.black, fg = PICO8.grey, symbol = "k" },
    ghost = { bg = PICO8.black, fg = PICO8.lavender, symbol = "g" },
    dragon = { bg = PICO8.black, fg = PICO8.red, symbol = "D" },
    potion = { bg = PICO8.black, fg = PICO8.pink, symbol = "!" },
    weapon = { bg = PICO8.black, fg = PICO8.yellow, symbol = "/" },
    shield = { bg = PICO8.black, fg = PICO8.blue, symbol = "]" },
    stairs = { bg = PICO8.black, fg = PICO8.white, symbol = ">" },
    fog = { bg = PICO8.black, fg = PICO8.black, symbol = " " },
    remembered_wall = { bg = PICO8.black, fg = REMEMBERED_WALL_FG, symbol = "#" },
    remembered_floor = { bg = PICO8.black, fg = REMEMBERED_FLOOR_FG, symbol = "." },
}

-- pixel buffer helpers --

local function fill_rect(pixels, pw, x, y, w, h, color)
    for py = y, y + h - 1 do
        for px = x, x + w - 1 do
            pixels[py * pw + px] = color
        end
    end
end

local function draw_glyph(pixels, pw, ox, oy, ch, color, scale)
    local glyph = font.get(ch)
    scale = scale or GLYPH_SCALE
    for row = 1, GLYPH_H do
        local line = glyph[row]
        for col = 1, GLYPH_W do
            if sub(line, col, col) == "1" then
                local bx = ox + (col - 1) * scale
                local by = oy + (row - 1) * scale
                fill_rect(pixels, pw, bx, by, scale, scale, color)
            end
        end
    end
end

local function draw_text(pixels, pw, x, y, text, color, scale)
    scale = scale or 2
    local spacing = GLYPH_W * scale + scale
    for i = 1, #text do
        local ch = sub(text, i, i)
        draw_glyph(pixels, pw, x + (i - 1) * spacing, y, ch, color, scale)
    end
end

local function text_width(text, scale)
    scale = scale or 2
    local spacing = GLYPH_W * scale + scale
    return #text * spacing - scale
end

-- tile rendering --

function tiles.render(tile_type)
    local def = TILE_DEFS[tile_type] or TILE_DEFS.fog
    local pixels = {}
    fill_rect(pixels, TILE_SIZE, 0, 0, TILE_SIZE, TILE_SIZE, def.bg)
    local gw = GLYPH_W * GLYPH_SCALE
    local gh = GLYPH_H * GLYPH_SCALE
    local ox = floor((TILE_SIZE - gw) / 2)
    local oy = floor((TILE_SIZE - gh) / 2)
    draw_glyph(pixels, TILE_SIZE, ox, oy, def.symbol, def.fg, GLYPH_SCALE)
    return png.encode(TILE_SIZE, TILE_SIZE, pixels)
end

function tiles.render_fog()
    return tiles.render("fog")
end

-- status bar --

function tiles.render_status(state)
    local pixels = {}
    fill_rect(pixels, STATUS_WIDTH, 0, 0, STATUS_WIDTH, STATUS_HEIGHT, PICO8.black)

    if not state then
        local text = "No active game"
        local tw = text_width(text, 2)
        draw_text(pixels, STATUS_WIDTH, floor((STATUS_WIDTH - tw) / 2), 12, text, PICO8.darkgrey, 2)
        return png.encode(STATUS_WIDTH, STATUS_HEIGHT, pixels)
    end

    local player = state.player
    local hp_text = format("HP:%d/%d", player.hp, player.max_hp)
    local stats_text = format("ATK:%d DEF:%d", player.attack, player.defense)
    local floor_text = format("FL:%d", state.floor)

    local hp_ratio = player.hp / player.max_hp
    local bar_width = 80
    local bar_height = 12
    local bar_x = 5
    local bar_y = floor((STATUS_HEIGHT - bar_height) / 2)

    local hp_color = PICO8.lime
    if hp_ratio < 0.3 then
        hp_color = PICO8.red
    elseif hp_ratio < 0.6 then
        hp_color = PICO8.orange
    end

    fill_rect(pixels, STATUS_WIDTH, bar_x, bar_y, bar_width, bar_height, PICO8.navy)
    fill_rect(pixels, STATUS_WIDTH, bar_x, bar_y,
        floor(bar_width * hp_ratio), bar_height, hp_color)

    local scale = 1
    local text_y = floor((STATUS_HEIGHT - GLYPH_H * scale) / 2)
    local hp_tw = text_width(hp_text, scale)
    draw_text(pixels, STATUS_WIDTH,
        floor(bar_x + (bar_width - hp_tw) / 2), text_y, hp_text, PICO8.white, scale)
    draw_text(pixels, STATUS_WIDTH,
        bar_x + bar_width + 10, text_y, stats_text, PICO8.grey, scale)

    local fl_tw = text_width(floor_text, scale)
    draw_text(pixels, STATUS_WIDTH,
        STATUS_WIDTH - fl_tw - 5, text_y, floor_text, PICO8.yellow, scale)

    if state.dead then
        fill_rect(pixels, STATUS_WIDTH, 0, 0, STATUS_WIDTH, STATUS_HEIGHT, { 0, 0, 0 })
        local dead_text = "YOU DIED"
        local dead_scale = 3
        local dtw = text_width(dead_text, dead_scale)
        local dty = floor((STATUS_HEIGHT - GLYPH_H * dead_scale) / 2)
        draw_text(pixels, STATUS_WIDTH,
            floor((STATUS_WIDTH - dtw) / 2), dty, dead_text, PICO8.red, dead_scale)
    end

    return png.encode(STATUS_WIDTH, STATUS_HEIGHT, pixels)
end

-- message bar --

function tiles.render_message(msg)
    local pixels = {}
    fill_rect(pixels, MSG_WIDTH, 0, 0, MSG_WIDTH, MSG_HEIGHT, PICO8.black)
    if msg and #msg > 0 then
        local scale = 1
        local tw = text_width(msg, scale)
        local ty = floor((MSG_HEIGHT - GLYPH_H * scale) / 2)
        draw_text(pixels, MSG_WIDTH, floor((MSG_WIDTH - tw) / 2), ty, msg, PICO8.grey, scale)
    end
    return png.encode(MSG_WIDTH, MSG_HEIGHT, pixels)
end

return tiles
