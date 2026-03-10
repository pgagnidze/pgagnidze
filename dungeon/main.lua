#!/usr/bin/env lua

local mote = require("mote")
local dungeon = require("game")

local format = string.format

-- favicon --

local favicon_data
do
    local f = io.open("favicon.ico", "rb")
    if f then favicon_data = f:read("*a"); f:close() end
end

-- constants --

local REDIRECT_URL = os.getenv("REDIRECT_URL") or "https://github.com/pgagnidze"
local GAME_TTL = 1800

-- shared game state --

local current_game = nil
local last_active = 0
local turn_counter = 0

local game_logs = {}
local log_seq = 0
local MAX_LOGS = 200

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
        turn_counter = turn_counter + 1
    end

    ctx:redirect(redirect)
end)

mote.get("/dungeon/attack", function(ctx)
    local redirect = ctx.query.redirect or REDIRECT_URL

    local state = get_game()
    if not state.dead then
        dungeon.attack(state)
        turn_counter = turn_counter + 1
    end

    ctx:redirect(redirect)
end)

mote.get("/dungeon/pickup", function(ctx)
    local redirect = ctx.query.redirect or REDIRECT_URL

    local state = get_game()
    if not state.dead then
        dungeon.pickup(state)
        turn_counter = turn_counter + 1
    end

    ctx:redirect(redirect)
end)

mote.get("/dungeon/descend", function(ctx)
    local redirect = ctx.query.redirect or REDIRECT_URL

    local state = get_game()
    if not state.dead then
        dungeon.descend(state)
        turn_counter = turn_counter + 1
    end

    ctx:redirect(redirect)
end)

-- new game endpoint --

mote.get("/dungeon/new", function(ctx)
    local redirect = ctx.query.redirect or REDIRECT_URL
    reset_game()
    turn_counter = turn_counter + 1
    ctx:redirect(redirect)
end)

-- watch endpoint (auto-refreshing viewer) --

local WATCH_HTML = [[
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Dungeon Crawler</title>
<link rel="icon" href="/favicon.ico" type="image/png">
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    background: #0a0e14; color: #e2e8f0;
    font-family: 'JetBrains Mono', 'Fira Code', 'SF Mono', Consolas, monospace;
    height: 100vh; overflow: hidden;
    display: grid; grid-template-columns: 1fr 1fr;
  }

  /* --- game panel --- */
  #panel-game {
    display: flex; flex-direction: column;
    align-items: center; justify-content: center;
    padding: 1.5rem; overflow: hidden;
    border-right: 1px solid #1e293b;
  }
  #game-frame {
    background: #111827; border: 1px solid #1e293b; border-radius: 8px;
    padding: 0.5rem; width: 100%; max-width: 504px;
    transition: border-color 0.15s ease, box-shadow 0.15s ease;
  }
  #game-frame:hover {
    border-color: #3b82f6;
    box-shadow: 0 0 20px rgba(59, 130, 246, 0.15);
  }
  #game {
    image-rendering: pixelated; image-rendering: crisp-edges;
    display: block; width: 100%; height: auto; border-radius: 4px;
  }
  #status {
    margin-top: 0.75rem; font-size: 0.6875rem; color: #64748b;
    text-align: center; text-transform: uppercase; letter-spacing: 0.05em;
  }
  .dot {
    display: inline-block; width: 6px; height: 6px; border-radius: 50%;
    margin-right: 6px; vertical-align: middle;
  }
  .dot-live { background: #22c55e; box-shadow: 0 0 6px rgba(34, 197, 94, 0.5); }
  .dot-dead { background: #ef4444; box-shadow: 0 0 6px rgba(239, 68, 68, 0.5); }
  .dot-off  { background: #64748b; }

  /* --- log panel --- */
  #panel-log {
    display: flex; flex-direction: column; min-width: 0; overflow: hidden;
  }
  #log-header {
    padding: 0.5rem 1rem; background: #111827;
    border-bottom: 1px solid #1e293b;
    font-size: 0.6875rem; color: #64748b; flex-shrink: 0;
    text-transform: uppercase; letter-spacing: 0.05em; font-weight: 600;
  }
  #log {
    flex: 1; overflow-y: auto; overflow-x: hidden;
    padding: 0.25rem 0; font-size: 0.75rem; line-height: 1.6;
  }
  #log::-webkit-scrollbar { width: 6px; }
  #log::-webkit-scrollbar-track { background: #0a0e14; }
  #log::-webkit-scrollbar-thumb { background: #1e293b; border-radius: 3px; }
  #log::-webkit-scrollbar-thumb:hover { background: #283548; }
  .log-entry {
    border-bottom: 1px solid rgba(30, 41, 59, 0.5);
    transition: background 0.15s ease;
  }
  .log-line {
    white-space: pre-wrap; word-break: break-word;
    cursor: pointer; padding: 0.25rem 1rem;
  }
  .log-line:hover { background: #1a2332; }
  .log-line .action { color: #22c55e; }
  .log-line .hp { color: #ef4444; }
  .log-line .thought { color: #64748b; }
  .log-line .floor { color: #f59e0b; }
  .log-line .death { color: #ef4444; font-weight: 700; }
  .log-detail {
    display: none; padding: 0.5rem 1rem 0.5rem 1.5rem;
    background: #111827; border-left: 2px solid #1e40af;
    color: #94a3b8; font-size: 0.6875rem; white-space: pre-wrap;
    word-break: break-word; max-height: 200px; overflow-y: auto;
  }
  .log-entry.open .log-detail { display: block; }
  .log-entry.open { background: rgba(59, 130, 246, 0.05); }
  #empty {
    display: flex; align-items: center; justify-content: center;
    height: 100%; color: #64748b; font-size: 0.8125rem;
  }

  /* --- responsive --- */
  @media (max-width: 768px) {
    body { grid-template-columns: 1fr; grid-template-rows: auto 1fr; }
    #panel-game {
      border-right: none; border-bottom: 1px solid #1e293b;
      padding: 1rem;
    }
    #game-frame { max-width: 320px; }
  }
</style>
</head>
<body>
<div id="panel-game">
  <div id="game-frame">
    <img id="game" alt="dungeon">
  </div>
  <div id="status"><span class="dot dot-off"></span>connecting</div>
</div>
<div id="panel-log">
  <div id="log-header">Game Log</div>
  <div id="log"><div id="empty">Waiting for entries...</div></div>
</div>
<script>
const img = document.getElementById('game');
const log = document.getElementById('log');
const status = document.getElementById('status');
const empty = document.getElementById('empty');
let prevTurn = -1;
let logOffset = 0;

function colorize(line) {
  return line
    .replace(/(-> \s*\S+)/, '<span class="action">$1</span>')
    .replace(/(HP:\s*\d+\/\d+)/, '<span class="hp">$1</span>')
    .replace(/(\| [^|]+$)/, '<span class="thought">$1</span>')
    .replace(/(F\d+)/, '<span class="floor">$1</span>')
    .replace(/(DIED[^|]*)/, '<span class="death">$1</span>');
}

async function pollGame() {
  try {
    const r = await fetch('/dungeon/info');
    if (!r.ok) return;
    const info = await r.json();
    if (info.turn == null) return;
    if (info.turn !== prevTurn) {
      prevTurn = info.turn;
      const next = new Image();
      next.onload = function() { img.src = next.src; };
      next.src = '/dungeon/view?' + Date.now();
    }
    const hp = (info.hp || 0) + '/' + (info.max_hp || 0);
    if (info.dead) {
      status.innerHTML = '<span class="dot dot-dead"></span>DEAD \u00b7 turn ' + info.turn;
    } else {
      status.innerHTML = '<span class="dot dot-live"></span>F' + info.floor + ' \u00b7 HP:' + hp + ' \u00b7 turn ' + info.turn;
    }
  } catch(e) {
    status.innerHTML = '<span class="dot dot-off"></span>disconnected';
  }
}

async function pollLogs() {
  try {
    const r = await fetch('/dungeon/logs?since=' + logOffset);
    const data = await r.json();
    if (data.entries && data.entries.length > 0) {
      if (empty && empty.parentNode) empty.parentNode.removeChild(empty);
      const frag = document.createDocumentFragment();
      for (const entry of data.entries.reverse()) {
        const wrapper = document.createElement('div');
        wrapper.className = 'log-entry';
        const line = document.createElement('div');
        line.className = 'log-line';
        line.innerHTML = colorize(entry.line);
        wrapper.appendChild(line);
        if (entry.detail) {
          const detail = document.createElement('div');
          detail.className = 'log-detail';
          detail.textContent = entry.detail;
          wrapper.appendChild(detail);
          line.addEventListener('click', function() {
            wrapper.classList.toggle('open');
          });
        }
        frag.appendChild(wrapper);
      }
      log.insertBefore(frag, log.firstChild);
    }
    logOffset = data.cursor;
  } catch(e) {}
}

setInterval(pollGame, 300);
setInterval(pollLogs, 500);
pollGame();
pollLogs();
</script>
</body>
</html>
]]

mote.get("/dungeon/watch", function(ctx)
    ctx.response.type = "text/html"
    ctx.response.body = WATCH_HTML
end)

-- state endpoint --

mote.get("/dungeon/state", function(ctx)
    ctx.response.body = dungeon.get_state_data(get_game())
end)

-- log endpoints --

mote.post("/dungeon/log", function(ctx)
    local entry = ctx.request.body
    if entry and entry.line then
        log_seq = log_seq + 1
        table.insert(game_logs, { seq = log_seq, line = entry.line, detail = entry.detail or "" })
        if #game_logs > MAX_LOGS then
            table.remove(game_logs, 1)
        end
    end
    ctx.response.body = { ok = true }
end)

mote.get("/dungeon/logs", function(ctx)
    local since = tonumber(ctx.query.since) or 0
    local result = {}
    for i = 1, #game_logs do
        if game_logs[i].seq > since then
            table.insert(result, game_logs[i])
        end
    end
    ctx.response.body = { entries = result, cursor = log_seq }
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
        turn = turn_counter,
    }
end)

mote.get("/favicon.ico", function(ctx)
    if favicon_data then
        ctx.response.type = "image/png"
        ctx:set("Cache-Control", "public,max-age=86400")
        ctx.response.body = favicon_data
    end
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
