#!/usr/bin/env lua

local mote = require("mote")
local dungeon = require("game")

local format = string.format

-- constants --

local REDIRECT_URL = os.getenv("REDIRECT_URL") or "https://github.com/pgagnidze"
local GAME_TTL = 1800

-- shared game state --

local current_game = nil
local last_active = 0

local function get_game()
    local now = os.time()
    if not current_game or now - last_active > GAME_TTL then
        current_game = dungeon.new_game()
    end
    last_active = now
    return current_game
end

local function reset_game()
    current_game = dungeon.new_game()
    last_active = os.time()
    return current_game
end

-- png helpers --

local function set_png_headers(ctx)
    ctx.response.type = "image/png"
    ctx:set("Cache-Control", "no-cache,max-age=0")
end

-- view endpoint (single canvas) --

mote.get("/dungeon/view", function(ctx)
    set_png_headers(ctx)
    ctx.response.body = dungeon.render_canvas(get_game())
end)

-- action endpoints --

mote.get("/dungeon/move", function(ctx)
    local dir = ctx.query.dir
    local redirect = ctx.query.redirect or REDIRECT_URL

    local state = get_game()
    if not state.dead then
        dungeon.move(state, dir)
    end

    ctx:redirect(redirect)
end)

mote.get("/dungeon/attack", function(ctx)
    local redirect = ctx.query.redirect or REDIRECT_URL

    local state = get_game()
    if not state.dead then
        dungeon.attack(state)
    end

    ctx:redirect(redirect)
end)

mote.get("/dungeon/pickup", function(ctx)
    local redirect = ctx.query.redirect or REDIRECT_URL

    local state = get_game()
    if not state.dead then
        dungeon.pickup(state)
    end

    ctx:redirect(redirect)
end)

mote.get("/dungeon/descend", function(ctx)
    local redirect = ctx.query.redirect or REDIRECT_URL

    local state = get_game()
    if not state.dead then
        dungeon.descend(state)
    end

    ctx:redirect(redirect)
end)

-- new game endpoint --

mote.get("/dungeon/new", function(ctx)
    local redirect = ctx.query.redirect or REDIRECT_URL
    reset_game()
    ctx:redirect(redirect)
end)

-- info endpoint --

mote.get("/dungeon/info", function(ctx)
    local state = get_game()
    ctx.response.body = {
        floor = state.floor,
        hp = state.player.hp,
        max_hp = state.player.max_hp,
        attack = state.player.attack,
        defense = state.player.defense,
        dead = state.dead,
        message = state.message,
    }
end)

mote.get("/health", function(ctx)
    ctx.response.body = { status = "ok" }
end)

-- main --

local function main()
    math.randomseed(os.time())
    local port = tonumber(os.getenv("PORT")) or 8080
    local app = mote.create({ host = "0.0.0.0", port = port })
    print(format("Dungeon crawler listening on http://localhost:%d", port))
    app:run()
end

main()
