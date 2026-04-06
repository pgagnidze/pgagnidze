local png = require("png")
local font = require("font")

local function prepare_sprites(data)
    if not data then return nil end
    for _, spr in pairs(data) do
        local unique = {}
        local px = spr.px
        for i = 0, spr.w * spr.h - 1 do
            local idx = i * 4
            if px[idx + 4] > 0 then
                local r, g, b = px[idx + 1], px[idx + 2], px[idx + 3]
                local key = r * 65536 + g * 256 + b
                if not unique[key] then
                    unique[key] = { r, g, b }
                end
                spr[i] = unique[key]
            end
        end
        spr.px = nil
    end
    return data
end

local ok, raw_sprites = pcall(require, "sprites")
local sprites = ok and prepare_sprites(raw_sprites) or nil

local tiles = {}

local format = string.format
local floor = math.floor
local sub = string.sub

-- layout --

local TILE_SIZE = 32
local GRID = 7
local GLYPH_W, GLYPH_H = 5, 7
local GLYPH_SCALE = 3
local SPRITE_SCALE = 2
local CANVAS_W = TILE_SIZE * GRID
local STATUS_H = 24
local MSG_H = 20
local GAP = 2
local CANVAS_H = STATUS_H + GAP + TILE_SIZE * GRID + GAP + MSG_H

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

-- tile definitions --

local TILE_DEFS = {
    wall = { bg = PICO8.brown, fg = PICO8.darkgrey, symbol = "#", sprite = "wall" },
    wall_tl = { bg = PICO8.brown, fg = PICO8.darkgrey, symbol = "#", sprite = "wall_tl" },
    wall_t = { bg = PICO8.brown, fg = PICO8.darkgrey, symbol = "#", sprite = "wall_t" },
    wall_tr = { bg = PICO8.brown, fg = PICO8.darkgrey, symbol = "#", sprite = "wall_tr" },
    wall_l = { bg = PICO8.brown, fg = PICO8.darkgrey, symbol = "#", sprite = "wall_l" },
    wall_r = { bg = PICO8.brown, fg = PICO8.darkgrey, symbol = "#", sprite = "wall_r" },
    wall_bl = { bg = PICO8.brown, fg = PICO8.darkgrey, symbol = "#", sprite = "wall_bl" },
    wall_b = { bg = PICO8.brown, fg = PICO8.darkgrey, symbol = "#", sprite = "wall_b" },
    wall_br = { bg = PICO8.brown, fg = PICO8.darkgrey, symbol = "#", sprite = "wall_br" },
    floor = { bg = PICO8.black, fg = PICO8.darkgrey, symbol = ".", sprite = "floor" },
    player = { bg = PICO8.black, fg = PICO8.lime, symbol = "@", sprite = "player" },
    scorpion = { bg = PICO8.black, fg = PICO8.brown, symbol = "r", sprite = "scorpion" },
    snake = { bg = PICO8.black, fg = PICO8.green, symbol = "s", sprite = "snake" },
    mummy = { bg = PICO8.black, fg = PICO8.grey, symbol = "k", sprite = "mummy" },
    fairy = { bg = PICO8.black, fg = PICO8.lavender, symbol = "g", sprite = "fairy" },
    griffin = { bg = PICO8.black, fg = PICO8.red, symbol = "D", sprite = "griffin" },
    potion = { bg = PICO8.black, fg = PICO8.pink, symbol = "!", sprite = "potion" },
    weapon = { bg = PICO8.black, fg = PICO8.yellow, symbol = "/", sprite = "weapon" },
    shield = { bg = PICO8.black, fg = PICO8.blue, symbol = "]", sprite = "shield" },
    stairs = { bg = PICO8.black, fg = PICO8.white, symbol = ">", sprite = "stairs" },
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

local function blit_sprite(pixels, pw, ox, oy, spr, scale)
    local sw = spr.w
    for sy = 0, spr.h - 1 do
        for sx = 0, sw - 1 do
            local c = spr[sy * sw + sx]
            if c then
                fill_rect(pixels, pw,
                    ox + sx * scale, oy + sy * scale,
                    scale, scale, c)
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

-- draw a single tile onto the canvas --

local function draw_tile(pixels, tx, ty, tile_type)
    local def = TILE_DEFS[tile_type] or TILE_DEFS.fog
    fill_rect(pixels, CANVAS_W, tx, ty, TILE_SIZE, TILE_SIZE, def.bg)

    local spr = def.sprite and sprites and sprites[def.sprite]
    if spr then
        local sw = spr.w * SPRITE_SCALE
        local sh = spr.h * SPRITE_SCALE
        local ox = tx + floor((TILE_SIZE - sw) / 2)
        local oy = ty + floor((TILE_SIZE - sh) / 2)
        blit_sprite(pixels, CANVAS_W, ox, oy, spr, SPRITE_SCALE)
    else
        local gw = GLYPH_W * GLYPH_SCALE
        local gh = GLYPH_H * GLYPH_SCALE
        local ox = tx + floor((TILE_SIZE - gw) / 2)
        local oy = ty + floor((TILE_SIZE - gh) / 2)
        draw_glyph(pixels, CANVAS_W, ox, oy, def.symbol, def.fg, GLYPH_SCALE)
    end
end

-- draw status bar --

local function draw_status(pixels, y, state)
    fill_rect(pixels, CANVAS_W, 0, y, CANVAS_W, STATUS_H, PICO8.black)

    if not state then
        local text = "No active game"
        local scale = 2
        local tw = text_width(text, scale)
        draw_text(pixels, CANVAS_W, floor((CANVAS_W - tw) / 2), y + 4, text, PICO8.darkgrey, scale)
        return
    end

    local player = state.player
    local hp_text = format("HP:%d/%d", player.hp, player.max_hp)
    local stats_text = format("ATK:%d DEF:%d", player.attack, player.defense)
    local floor_text = format("FL:%d", state.floor)

    local hp_ratio = player.hp / player.max_hp
    local bar_width = 60
    local bar_height = 10
    local bar_x = 4
    local bar_y = y + floor((STATUS_H - bar_height) / 2)

    local hp_color = PICO8.lime
    if hp_ratio < 0.3 then
        hp_color = PICO8.red
    elseif hp_ratio < 0.6 then
        hp_color = PICO8.orange
    end

    fill_rect(pixels, CANVAS_W, bar_x, bar_y, bar_width, bar_height, PICO8.navy)
    fill_rect(pixels, CANVAS_W, bar_x, bar_y,
        floor(bar_width * hp_ratio), bar_height, hp_color)

    local scale = 1
    local text_y = y + floor((STATUS_H - GLYPH_H * scale) / 2)
    local hp_tw = text_width(hp_text, scale)
    draw_text(pixels, CANVAS_W,
        floor(bar_x + (bar_width - hp_tw) / 2), text_y, hp_text, PICO8.white, scale)
    draw_text(pixels, CANVAS_W,
        bar_x + bar_width + 8, text_y, stats_text, PICO8.grey, scale)

    local fl_tw = text_width(floor_text, scale)
    draw_text(pixels, CANVAS_W,
        CANVAS_W - fl_tw - 4, text_y, floor_text, PICO8.yellow, scale)

    if state.dead then
        fill_rect(pixels, CANVAS_W, 0, y, CANVAS_W, STATUS_H, PICO8.black)
        local dead_text = "YOU DIED"
        local dead_scale = 2
        local dtw = text_width(dead_text, dead_scale)
        local dty = y + floor((STATUS_H - GLYPH_H * dead_scale) / 2)
        draw_text(pixels, CANVAS_W,
            floor((CANVAS_W - dtw) / 2), dty, dead_text, PICO8.red, dead_scale)
    end
end

-- draw message bar --

local function draw_message(pixels, y, msg)
    fill_rect(pixels, CANVAS_W, 0, y, CANVAS_W, MSG_H, PICO8.black)
    if msg and #msg > 0 then
        local scale = 1
        local tw = text_width(msg, scale)
        local ty = y + floor((MSG_H - GLYPH_H * scale) / 2)
        local tx = floor((CANVAS_W - tw) / 2)
        if tx < 2 then tx = 2 end
        draw_text(pixels, CANVAS_W, tx, ty, msg, PICO8.grey, scale)
    end
end

-- main render: single canvas with everything --

function tiles.render_canvas(state, tile_types)
    local pixels = {}
    fill_rect(pixels, CANVAS_W, 0, 0, CANVAS_W, CANVAS_H, PICO8.black)

    draw_status(pixels, 0, state)

    local grid_y = STATUS_H + GAP
    for gy = 0, GRID - 1 do
        for gx = 0, GRID - 1 do
            local idx = gy * GRID + gx + 1
            draw_tile(pixels, gx * TILE_SIZE, grid_y + gy * TILE_SIZE, tile_types[idx])
        end
    end

    draw_message(pixels, grid_y + TILE_SIZE * GRID + GAP, state and state.message or "")

    return png.encode(CANVAS_W, CANVAS_H, pixels)
end

tiles.GRID = GRID

return tiles
