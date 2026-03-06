local tiles = {}

local insert, concat = table.insert, table.concat
local format = string.format

-- tile dimensions --

local TILE_SIZE = 50
local FONT_SIZE = 24
local STATUS_WIDTH = 270
local STATUS_HEIGHT = 40
local MSG_WIDTH = 270
local MSG_HEIGHT = 30

-- pico-8 palette --

local PICO8 = {
    black = "#000000",
    navy = "#1d2b53",
    purple = "#7e2553",
    green = "#008751",
    brown = "#ab5236",
    darkgrey = "#5f574f",
    grey = "#c2c3c7",
    white = "#fff1e8",
    red = "#ff004d",
    orange = "#ffa300",
    yellow = "#ffec27",
    lime = "#00e436",
    blue = "#29adff",
    lavender = "#83769c",
    pink = "#ff77a8",
    peach = "#ffccaa",
}

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
    remembered_wall = { bg = PICO8.black, fg = "#111833", symbol = "#" },
    remembered_floor = { bg = PICO8.black, fg = "#0a0a0a", symbol = "." },
}

-- svg helpers --

local function svg_open(width, height)
    return format(
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d">',
        width, height
    )
end

local SVG_CLOSE = "</svg>"

local function svg_rect(x, y, w, h, fill)
    return format(
        '<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>',
        x, y, w, h, fill
    )
end

local function svg_text(x, y, text, color, size)
    return format(
        '<text x="%d" y="%d" fill="%s" font-family="monospace" '
        ..'font-size="%d" font-weight="bold" text-anchor="middle" '
        ..'dominant-baseline="central">%s</text>',
        x, y, color, size or FONT_SIZE, text
    )
end

-- tile rendering --

function tiles.render(tile_type)
    local def = TILE_DEFS[tile_type] or TILE_DEFS.fog
    local half = TILE_SIZE / 2

    local parts = {
        svg_open(TILE_SIZE, TILE_SIZE),
        svg_rect(0, 0, TILE_SIZE, TILE_SIZE, def.bg),
        svg_text(half, half, def.symbol, def.fg),
        SVG_CLOSE,
    }
    return concat(parts)
end

function tiles.render_fog()
    return tiles.render("fog")
end

-- status bar --

function tiles.render_status(state)
    if not state then
        local parts = {
            svg_open(STATUS_WIDTH, STATUS_HEIGHT),
            svg_rect(0, 0, STATUS_WIDTH, STATUS_HEIGHT, PICO8.black),
            svg_text(STATUS_WIDTH / 2, STATUS_HEIGHT / 2, "No active game", PICO8.darkgrey, 14),
            SVG_CLOSE,
        }
        return concat(parts)
    end

    local player = state.player
    local hp_text = format("HP:%d/%d", player.hp, player.max_hp)
    local stats_text = format("ATK:%d DEF:%d", player.attack, player.defense)
    local floor_text = format("FL:%d", state.floor)

    local hp_ratio = player.hp / player.max_hp
    local bar_width = 80
    local bar_height = 12
    local bar_x = 5
    local bar_y = (STATUS_HEIGHT - bar_height) / 2

    local hp_color = PICO8.lime
    if hp_ratio < 0.3 then
        hp_color = PICO8.red
    elseif hp_ratio < 0.6 then
        hp_color = PICO8.orange
    end

    local parts = {
        svg_open(STATUS_WIDTH, STATUS_HEIGHT),
        svg_rect(0, 0, STATUS_WIDTH, STATUS_HEIGHT, PICO8.black),
        svg_rect(bar_x, bar_y, bar_width, bar_height, PICO8.navy),
        svg_rect(bar_x, bar_y, bar_width * hp_ratio, bar_height, hp_color),
        svg_text(bar_x + bar_width / 2, STATUS_HEIGHT / 2, hp_text, PICO8.white, 10),
        svg_text(bar_x + bar_width + 40, STATUS_HEIGHT / 2, stats_text, PICO8.grey, 11),
        svg_text(STATUS_WIDTH - 25, STATUS_HEIGHT / 2, floor_text, PICO8.yellow, 11),
    }

    if state.dead then
        insert(parts, svg_rect(0, 0, STATUS_WIDTH, STATUS_HEIGHT, "rgba(0,0,0,0.7)"))
        insert(parts, svg_text(STATUS_WIDTH / 2, STATUS_HEIGHT / 2, "YOU DIED", PICO8.red, 18))
    end

    insert(parts, SVG_CLOSE)
    return concat(parts)
end

-- message bar --

function tiles.render_message(msg)
    local parts = {
        svg_open(MSG_WIDTH, MSG_HEIGHT),
        svg_rect(0, 0, MSG_WIDTH, MSG_HEIGHT, PICO8.black),
        svg_text(MSG_WIDTH / 2, MSG_HEIGHT / 2, msg or "", PICO8.grey, 11),
        SVG_CLOSE,
    }
    return concat(parts)
end

return tiles
