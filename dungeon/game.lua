local game = {}

local insert, remove = table.insert, table.remove
local floor, random, max, min = math.floor, math.random, math.max, math.min
local abs = math.abs
local format = string.format

-- constants --

local MAP_WIDTH = 40
local MAP_HEIGHT = 30
local FOV_RADIUS = 5

local TILE_WALL = 1
local TILE_FLOOR = 2
local TILE_STAIRS = 3

local MONSTER_TYPES = {
    { name = "rat", hp = 8, attack = 2, defense = 0, symbol = "rat", min_floor = 1 },
    { name = "snake", hp = 12, attack = 4, defense = 1, symbol = "snake", min_floor = 1 },
    { name = "skeleton", hp = 20, attack = 6, defense = 2, symbol = "skeleton", min_floor = 2 },
    { name = "ghost", hp = 15, attack = 8, defense = 3, symbol = "ghost", min_floor = 3 },
    { name = "dragon", hp = 40, attack = 12, defense = 5, symbol = "dragon", min_floor = 5 },
}

local ITEM_TYPES = {
    { name = "potion", symbol = "potion", effect = "heal", value = 15 },
    { name = "sword", symbol = "weapon", effect = "attack", value = 2 },
    { name = "shield", symbol = "shield", effect = "defense", value = 1 },
}

-- map generation --

local function create_map()
    local map = {}
    for y = 1, MAP_HEIGHT do
        map[y] = {}
        for x = 1, MAP_WIDTH do
            map[y][x] = TILE_WALL
        end
    end
    return map
end

local function carve_room(map, rx, ry, rw, rh)
    for y = ry, ry + rh - 1 do
        for x = rx, rx + rw - 1 do
            if y > 1 and y < MAP_HEIGHT and x > 1 and x < MAP_WIDTH then
                map[y][x] = TILE_FLOOR
            end
        end
    end
end

local function carve_corridor(map, x1, y1, x2, y2)
    local x, y = x1, y1

    if random(1, 2) == 1 then
        while x ~= x2 do
            if x > 1 and x < MAP_WIDTH and y > 1 and y < MAP_HEIGHT then
                map[y][x] = TILE_FLOOR
            end
            x = x + (x2 > x1 and 1 or -1)
        end
        while y ~= y2 do
            if x > 1 and x < MAP_WIDTH and y > 1 and y < MAP_HEIGHT then
                map[y][x] = TILE_FLOOR
            end
            y = y + (y2 > y1 and 1 or -1)
        end
    else
        while y ~= y2 do
            if x > 1 and x < MAP_WIDTH and y > 1 and y < MAP_HEIGHT then
                map[y][x] = TILE_FLOOR
            end
            y = y + (y2 > y1 and 1 or -1)
        end
        while x ~= x2 do
            if x > 1 and x < MAP_WIDTH and y > 1 and y < MAP_HEIGHT then
                map[y][x] = TILE_FLOOR
            end
            x = x + (x2 > x1 and 1 or -1)
        end
    end
end

local function generate_dungeon(depth)
    local map = create_map()
    local rooms = {}
    local room_count = 5 + min(depth, 5)

    for _ = 1, room_count * 3 do
        if #rooms >= room_count then break end

        local rw = random(4, 8)
        local rh = random(3, 6)
        local rx = random(2, MAP_WIDTH - rw - 1)
        local ry = random(2, MAP_HEIGHT - rh - 1)

        local overlap = false
        for i = 1, #rooms do
            local r = rooms[i]
            if rx < r.x + r.w + 1 and rx + rw + 1 > r.x
                and ry < r.y + r.h + 1 and ry + rh + 1 > r.y then
                overlap = true
                break
            end
        end

        if not overlap then
            carve_room(map, rx, ry, rw, rh)
            insert(rooms, { x = rx, y = ry, w = rw, h = rh })
        end
    end

    for i = 2, #rooms do
        local prev = rooms[i - 1]
        local curr = rooms[i]
        local px = floor(prev.x + prev.w / 2)
        local py = floor(prev.y + prev.h / 2)
        local cx = floor(curr.x + curr.w / 2)
        local cy = floor(curr.y + curr.h / 2)
        carve_corridor(map, px, py, cx, cy)
    end

    return map, rooms
end

-- entity placement --

local function place_stairs(map, rooms)
    local last_room = rooms[#rooms]
    local sx = floor(last_room.x + last_room.w / 2)
    local sy = floor(last_room.y + last_room.h / 2)
    map[sy][sx] = TILE_STAIRS
    return sx, sy
end

local function spawn_monsters(rooms, depth)
    local monsters = {}
    local available = {}

    for i = 1, #MONSTER_TYPES do
        if MONSTER_TYPES[i].min_floor <= depth then
            insert(available, MONSTER_TYPES[i])
        end
    end

    if #available == 0 then return monsters end

    for i = 2, #rooms do
        local room = rooms[i]
        local count = random(0, 2)
        for _ = 1, count do
            local template = available[random(1, #available)]
            local mx = random(room.x + 1, room.x + room.w - 2)
            local my = random(room.y + 1, room.y + room.h - 2)
            local hp_scale = 1 + (depth - 1) * 0.15
            insert(monsters, {
                x = mx,
                y = my,
                name = template.name,
                symbol = template.symbol,
                hp = floor(template.hp * hp_scale),
                max_hp = floor(template.hp * hp_scale),
                attack = template.attack + floor(depth * 0.5),
                defense = template.defense + floor(depth * 0.3),
            })
        end
    end

    return monsters
end

local function spawn_items(rooms)
    local items = {}

    for i = 1, #rooms do
        if random(1, 3) == 1 then
            local room = rooms[i]
            local template = ITEM_TYPES[random(1, #ITEM_TYPES)]
            insert(items, {
                x = random(room.x + 1, room.x + room.w - 2),
                y = random(room.y + 1, room.y + room.h - 2),
                name = template.name,
                symbol = template.symbol,
                effect = template.effect,
                value = template.value,
            })
        end
    end

    return items
end

-- shadowcast fov (recursive, octant-based) --

local function create_fov_map()
    local fov = {}
    for y = 1, MAP_HEIGHT do
        fov[y] = {}
        for x = 1, MAP_WIDTH do
            fov[y][x] = false
        end
    end
    return fov
end

local function is_opaque(map, x, y)
    if y < 1 or y > MAP_HEIGHT or x < 1 or x > MAP_WIDTH then return true end
    return map[y][x] == TILE_WALL
end

local OCTANTS = {
    { 1, 0, 0, 1 },
    { 0, 1, 1, 0 },
    { 0, -1, 1, 0 },
    { -1, 0, 0, 1 },
    { -1, 0, 0, -1 },
    { 0, -1, -1, 0 },
    { 0, 1, -1, 0 },
    { 1, 0, 0, -1 },
}

local function cast_light(map, fov, ox, oy, radius, oct, start_slope, end_slope, depth)
    if start_slope < end_slope then return end

    local xx, xy, yx, yy = oct[1], oct[2], oct[3], oct[4]
    local new_start = start_slope

    for j = depth, radius do
        local blocked = false
        local dy = -j

        for dx = -j, 0 do
            local lx = ox + dx * xx + dy * xy
            local ly = oy + dx * yx + dy * yy

            local l_slope = (dx - 0.5) / (dy + 0.5)
            local r_slope = (dx + 0.5) / (dy - 0.5)

            if new_start < r_slope then goto next_dx end
            if end_slope > l_slope then break end

            local dist_sq = dx * dx + dy * dy
            if dist_sq <= radius * radius
                and lx >= 1 and lx <= MAP_WIDTH
                and ly >= 1 and ly <= MAP_HEIGHT then
                fov[ly][lx] = true
            end

            if blocked then
                if is_opaque(map, lx, ly) then
                    new_start = r_slope
                else
                    blocked = false
                    start_slope = new_start
                end
            elseif is_opaque(map, lx, ly) and j < radius then
                blocked = true
                cast_light(map, fov, ox, oy, radius, oct, new_start, l_slope, j + 1)
                new_start = r_slope
            end

            ::next_dx::
        end

        if blocked then break end
    end
end

local function compute_fov(map, px, py, radius)
    local fov = create_fov_map()
    fov[py][px] = true

    for i = 1, #OCTANTS do
        cast_light(map, fov, px, py, radius, OCTANTS[i], 1.0, 0.0, 1)
    end

    return fov
end

-- memory map (remembered but not currently visible) --

local function create_memory_map()
    local mem = {}
    for y = 1, MAP_HEIGHT do
        mem[y] = {}
        for x = 1, MAP_WIDTH do
            mem[y][x] = false
        end
    end
    return mem
end

local function update_memory(memory, fov)
    for y = 1, MAP_HEIGHT do
        for x = 1, MAP_WIDTH do
            if fov[y][x] then
                memory[y][x] = true
            end
        end
    end
end

-- game factory --

function game.new_game()
    local map, rooms = generate_dungeon(1)
    local first_room = rooms[1]
    local px = floor(first_room.x + first_room.w / 2)
    local py = floor(first_room.y + first_room.h / 2)

    place_stairs(map, rooms)

    local fov = compute_fov(map, px, py, FOV_RADIUS)
    local memory = create_memory_map()
    update_memory(memory, fov)

    local state = {
        map = map,
        floor = 1,
        dead = false,
        message = "You enter the dungeon...",
        player = {
            x = px,
            y = py,
            hp = 30,
            max_hp = 30,
            attack = 5,
            defense = 2,
        },
        monsters = spawn_monsters(rooms, 1),
        items = spawn_items(rooms),
        fov = fov,
        memory = memory,
        rooms = rooms,
    }

    return state
end

-- queries --

local function find_monster_at(state, x, y)
    local monsters = state.monsters
    for i = 1, #monsters do
        local m = monsters[i]
        if m.x == x and m.y == y and m.hp > 0 then
            return m, i
        end
    end
    return nil
end

local function find_item_at(state, x, y)
    local items = state.items
    for i = 1, #items do
        local item = items[i]
        if item.x == x and item.y == y then
            return item, i
        end
    end
    return nil
end

local function find_adjacent_monster(state)
    local px, py = state.player.x, state.player.y
    local dirs = { { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }
    for i = 1, #dirs do
        local m = find_monster_at(state, px + dirs[i][1], py + dirs[i][2])
        if m then return m end
    end
    return nil
end

local function refresh_fov(state)
    state.fov = compute_fov(state.map, state.player.x, state.player.y, FOV_RADIUS)
    update_memory(state.memory, state.fov)
end

-- actions --

local DIR_OFFSETS = {
    up = { 0, -1 },
    down = { 0, 1 },
    left = { -1, 0 },
    right = { 1, 0 },
    ul = { -1, -1 },
    ur = { 1, -1 },
    dl = { -1, 1 },
    dr = { 1, 1 },
    wait = { 0, 0 },
}

function game.move(state, dir)
    if state.dead then return end

    local offset = DIR_OFFSETS[dir]
    if not offset then
        state.message = "Invalid direction"
        return
    end

    local player = state.player
    local nx = player.x + offset[1]
    local ny = player.y + offset[2]

    if dir == "wait" then
        state.message = "You wait..."
        game.monster_turn(state)
        return
    end

    if ny < 1 or ny > MAP_HEIGHT or nx < 1 or nx > MAP_WIDTH then
        state.message = "A wall blocks your path"
        return
    end

    if state.map[ny][nx] == TILE_WALL then
        state.message = "A wall blocks your path"
        return
    end

    local monster = find_monster_at(state, nx, ny)
    if monster then
        state.message = format("A %s blocks the way!", monster.name)
        return
    end

    player.x = nx
    player.y = ny
    refresh_fov(state)

    if state.map[ny][nx] == TILE_STAIRS then
        state.message = "You see stairs going down. Click descend to go deeper."
    else
        local item = find_item_at(state, nx, ny)
        if item then
            state.message = format("You see a %s on the ground", item.name)
        else
            state.message = "You move "..dir
        end
    end

    game.monster_turn(state)
end

function game.attack(state)
    if state.dead then return end

    local monster = find_adjacent_monster(state)
    if not monster then
        state.message = "Nothing to attack nearby"
        return
    end

    local player = state.player
    local damage = max(1, player.attack - monster.defense)
    monster.hp = monster.hp - damage
    state.message = format("You hit the %s for %d damage", monster.name, damage)

    if monster.hp <= 0 then
        state.message = format("You defeated the %s!", monster.name)
    end

    game.monster_turn(state)
end

function game.pickup(state)
    if state.dead then return end

    local player = state.player
    local item, idx = find_item_at(state, player.x, player.y)

    if not item then
        state.message = "Nothing to pick up here"
        return
    end

    if item.effect == "heal" then
        player.hp = min(player.max_hp, player.hp + item.value)
        state.message = format("You drink the %s (+%d HP)", item.name, item.value)
    elseif item.effect == "attack" then
        player.attack = player.attack + item.value
        state.message = format("You equip the %s (+%d ATK)", item.name, item.value)
    elseif item.effect == "defense" then
        player.defense = player.defense + item.value
        state.message = format("You equip the %s (+%d DEF)", item.name, item.value)
    end

    remove(state.items, idx)
end

function game.descend(state)
    if state.dead then return end

    local player = state.player
    if state.map[player.y][player.x] ~= TILE_STAIRS then
        state.message = "No stairs here"
        return
    end

    state.floor = state.floor + 1
    local map, rooms = generate_dungeon(state.floor)
    state.map = map
    state.rooms = rooms

    local first_room = rooms[1]
    player.x = floor(first_room.x + first_room.w / 2)
    player.y = floor(first_room.y + first_room.h / 2)

    place_stairs(map, rooms)
    state.monsters = spawn_monsters(rooms, state.floor)
    state.items = spawn_items(rooms)
    state.memory = create_memory_map()
    refresh_fov(state)

    state.message = format("You descend to floor %d...", state.floor)
end

function game.monster_turn(state)
    if state.dead then return end

    local player = state.player
    local monsters = state.monsters

    for i = 1, #monsters do
        local m = monsters[i]
        if m.hp > 0 then
            local dx = player.x - m.x
            local dy = player.y - m.y
            local dist = abs(dx) + abs(dy)

            if dist == 1 then
                local damage = max(1, m.attack - player.defense)
                player.hp = player.hp - damage
                state.message = state.message..format(" The %s hits you for %d!", m.name, damage)

                if player.hp <= 0 then
                    player.hp = 0
                    state.dead = true
                    state.message = format("Killed by a %s on floor %d!", m.name, state.floor)
                    return
                end
            elseif dist <= 5 then
                local nx, ny = m.x, m.y
                if abs(dx) >= abs(dy) then
                    nx = m.x + (dx > 0 and 1 or -1)
                else
                    ny = m.y + (dy > 0 and 1 or -1)
                end

                if ny >= 1 and ny <= MAP_HEIGHT and nx >= 1 and nx <= MAP_WIDTH
                    and state.map[ny][nx] ~= TILE_WALL
                    and not find_monster_at(state, nx, ny)
                    and not (nx == player.x and ny == player.y) then
                    m.x = nx
                    m.y = ny
                end
            end
        end
    end
end

-- rendering --

local tiles = require("tiles")

local function resolve_tile(state, wx, wy)
    if wy < 1 or wy > MAP_HEIGHT or wx < 1 or wx > MAP_WIDTH then
        return "wall"
    end

    local visible = state.fov[wy][wx]
    local remembered = state.memory[wy][wx]

    if not visible and not remembered then
        return "fog"
    end

    if visible then
        local player = state.player
        if wx == player.x and wy == player.y then
            return "player"
        end

        local monster = find_monster_at(state, wx, wy)
        if monster then
            return monster.symbol
        end

        local item = find_item_at(state, wx, wy)
        if item then
            return item.symbol
        end
    end

    local tile = state.map[wy][wx]
    if tile == TILE_WALL then
        return visible and "wall" or "remembered_wall"
    elseif tile == TILE_STAIRS then
        return visible and "stairs" or "remembered_floor"
    end

    return visible and "floor" or "remembered_floor"
end

function game.render_canvas(state)
    local player = state.player
    local grid = tiles.GRID
    local half = floor(grid / 2)
    local tile_types = {}
    for vy = 0, grid - 1 do
        for vx = 0, grid - 1 do
            local wx = player.x + (vx - half)
            local wy = player.y + (vy - half)
            tile_types[vy * grid + vx + 1] = resolve_tile(state, wx, wy)
        end
    end
    return tiles.render_canvas(state, tile_types)
end

return game
