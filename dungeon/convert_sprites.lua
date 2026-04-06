#!/usr/bin/env luajit

local pngdecode = require("pngdecode")

local floor = math.floor

-- constants --

local BG_R, BG_G, BG_B = 39, 39, 54
local SPRITE_SIZE = 16

local CREATURE_MAP = {
    player = "Rogue",
    scorpion = "Scorpion",
    snake = "Snake",
    mummy = "Mummy",
    fairy = "Fairy",
    griffin = "Griffin",
}

local SHEET_MAP = {
    floor = { row = 0, col = 9 },
    stairs = { row = 7, col = 11 },
    potion = { row = 7, col = 13 },
}

local HAND_DRAWN = {
    wall = {
        palette = {
            M = { 55, 40, 52 },
            A = { 210, 120, 85 },
            B = { 190, 105, 75 },
        },
        grid = {
            "MMMMMMMMMMMMMMMM",
            "MAAAAAAAMBBBBBBB",
            "MAAAAAAAMBBBBBBB",
            "MAAAAAAAMBBBBBBB",
            "MMMMMMMMMMMMMMMM",
            "BBBBMAAAAAAAMBBB",
            "BBBBMAAAAAAAMBBB",
            "BBBBMAAAAAAAMBBB",
            "MMMMMMMMMMMMMMMM",
            "MAAAAAAAMBBBBBBB",
            "MAAAAAAAMBBBBBBB",
            "MAAAAAAAMBBBBBBB",
            "MMMMMMMMMMMMMMMM",
            "BBBBMAAAAAAAMBBB",
            "BBBBMAAAAAAAMBBB",
            "BBBBMAAAAAAAMBBB",
        },
    },
    weapon = {
        palette = {
            W = { 255, 255, 235 },
            G = { 170, 175, 190 },
            Y = { 220, 180, 60 },
            B = { 130, 80, 45 },
            H = { 160, 100, 55 },
            P = { 100, 65, 35 },
        },
        grid = {
            "................",
            ".......W........",
            "......WGW.......",
            "......WGW.......",
            "......WGW.......",
            "......WGW.......",
            "......WGW.......",
            "......WGW.......",
            ".....YWGWY......",
            ".....YYYYY......",
            "......BHB.......",
            "......BHB.......",
            "......BPB.......",
            ".......P........",
            "................",
            "................",
        },
    },
    shield = {
        palette = {
            D = { 50, 50, 70 },
            C = { 68, 157, 206 },
            L = { 90, 180, 230 },
            W = { 255, 255, 235 },
        },
        grid = {
            "................",
            "................",
            "....DDDDDDD.....",
            "...DLCCCCCCLD...",
            "...DCCCWCCCD....",
            "...DCCWWWCCD....",
            "...DCCCWCCCD....",
            "...DCCWWWCCD....",
            "...DCCCWCCCD....",
            "...DCCCCCCCD....",
            "....DCCCCCD.....",
            ".....DCCCD......",
            "......DCD.......",
            ".......D........",
            "................",
            "................",
        },
    },
}

-- helpers --

local script_dir = arg[0]:match("(.*/)") or "./"
local creature_dir = script_dir .. "assets/creatures"
local sheet_path = script_dir .. "assets/spritesheet.png"

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil, "cannot open: "..path end
    local data = f:read("*a")
    f:close()
    return data
end

local function strip_bg(img)
    for i = 1, #img.pixels do
        local p = img.pixels[i]
        if p[1] == BG_R and p[2] == BG_G and p[3] == BG_B then
            p[4] = 0
        end
    end
end

local function recolor_green(img)
    for i = 1, #img.pixels do
        local p = img.pixels[i]
        if p[4] > 0 then
            p[1] = floor(p[1] * 0.20)
            p[2] = floor(p[2] * 0.90)
            p[3] = floor(p[3] * 0.25)
        end
    end
end

local function extract_tile(sheet, row, col)
    local ox = col * SPRITE_SIZE
    local oy = row * SPRITE_SIZE
    local pixels = {}
    for y = 0, SPRITE_SIZE - 1 do
        for x = 0, SPRITE_SIZE - 1 do
            local si = (oy + y) * sheet.width + (ox + x) + 1
            local p = sheet.pixels[si]
            pixels[y * SPRITE_SIZE + x + 1] = { p[1], p[2], p[3], p[4] }
        end
    end
    return { width = SPRITE_SIZE, height = SPRITE_SIZE, pixels = pixels }
end

local function build_hand_drawn(def)
    local pixels = {}
    for y = 1, 16 do
        local row = def.grid[y]
        for x = 1, 16 do
            local ch = row:sub(x, x)
            local color = def.palette[ch]
            if color then
                pixels[(y - 1) * 16 + x] = { color[1], color[2], color[3], 255 }
            else
                pixels[(y - 1) * 16 + x] = { 0, 0, 0, 0 }
            end
        end
    end
    return { width = 16, height = 16, pixels = pixels }
end

-- load sprites --

local function main()
    local sprites = {}

    for game_name, asset_name in pairs(CREATURE_MAP) do
        local path = creature_dir .. "/" .. asset_name .. ".png"
        local data = read_file(path)
        if not data then
            io.stderr:write("WARNING: missing " .. path .. ", skipping " .. game_name .. "\n")
        else
            io.stderr:write("Decoding " .. path .. " -> " .. game_name .. "\n")
            local img, err = pngdecode.decode(data)
            if not img then
                io.stderr:write("  ERROR: " .. err .. "\n")
            else
                strip_bg(img)
                if game_name == "player" then
                    recolor_green(img)
                end
                sprites[game_name] = img
            end
        end
    end

    local sheet_data = read_file(sheet_path)
    if not sheet_data then
        io.stderr:write("WARNING: missing " .. sheet_path .. ", skipping sheet tiles\n")
    else
        io.stderr:write("Decoding " .. sheet_path .. "\n")
        local sheet, err = pngdecode.decode(sheet_data)
        if not sheet then
            io.stderr:write("  ERROR: " .. err .. "\n")
        else
            for game_name, pos in pairs(SHEET_MAP) do
                io.stderr:write("  Extracting (" .. pos.row .. "," .. pos.col .. ") -> " .. game_name .. "\n")
                local tile = extract_tile(sheet, pos.row, pos.col)
                strip_bg(tile)
                sprites[game_name] = tile
            end
        end
    end

    for game_name, def in pairs(HAND_DRAWN) do
        io.stderr:write("Building hand-drawn -> " .. game_name .. "\n")
        sprites[game_name] = build_hand_drawn(def)
    end

    -- emit --

    local out = {}
    local function emit(s) out[#out + 1] = s end

    emit("-- generated by convert_sprites.lua\n")
    emit("local S = {}\n\n")

    local sorted = {}
    for name in pairs(sprites) do
        sorted[#sorted + 1] = name
    end
    table.sort(sorted)

    for _, name in ipairs(sorted) do
        local img = sprites[name]
        emit("S." .. name .. " = {\n")
        emit("    w = " .. img.width .. ", h = " .. img.height .. ",\n")
        emit("    px = {\n")

        for y = 0, img.height - 1 do
            emit("        ")
            for x = 0, img.width - 1 do
                local p = img.pixels[y * img.width + x + 1]
                emit(p[1] .. "," .. p[2] .. "," .. p[3] .. "," .. p[4] .. ",")
            end
            emit("\n")
        end

        emit("    },\n")
        emit("}\n\n")
    end

    emit("return S\n")

    local f, err = io.open("sprites.lua", "w")
    if not f then
        io.stderr:write("ERROR: " .. err .. "\n")
        os.exit(1)
    end
    f:write(table.concat(out))
    f:close()

    io.stderr:write("Wrote sprites.lua (" .. #sorted .. " sprites)\n")
end

main()
