"""Autonomous dungeon crawler player powered by Claude."""

from __future__ import annotations

import argparse
import sys
import time
from dataclasses import dataclass
from dataclasses import field

import anthropic
import requests
from anthropic.types import TextBlock
from anthropic.types import ToolUseBlock

GAME_URL = "http://127.0.0.1:8080"
MODEL = "claude-sonnet-4-6"
TURN_DELAY = 0.5

SYSTEM_PROMPT = """\
You are playing a roguelike dungeon crawler. You control the player via tools.

SYMBOLS:
  @ = you   # = wall   . = floor   > = stairs down
  r = rat   s = snake  k = skeleton  g = ghost  D = dragon
  ! = potion (heals HP)  / = sword (+ATK)  ] = shield (+DEF)
  ~ = visited floor      (space) = unexplored fog

RULES:
- Each turn you MUST call the "play" tool with an action from available_actions.
- You may also call "record_memory" and "delete_memory" to manage your notes.
- You can invoke multiple tools per turn.
- Monsters chase you within 5 tiles and attack when adjacent (including diagonally).
- "attack" hits one adjacent monster automatically (including diagonal).
- You regenerate 1 HP every 3 turns if you haven't taken damage. Use "wait" to heal.
- Stand on an item and use "pickup" to collect it.
- Stand on > and use "descend" to go deeper.

STRATEGY:
- Attack adjacent monsters immediately (they chase you, no point fleeing, diagonals count).
- When low on HP and no monsters nearby, use "wait" repeatedly to regenerate.
- Pick up all items: potions heal, swords boost ATK, shields boost DEF.
- Explore toward fog/unexplored areas (avoid ~ tiles when fog exists).
- Move toward stairs (>) when you've explored enough.
- Use diagonal moves (ul, ur, dl, dr) to navigate efficiently.
- Use memories to track goals, unexplored directions, and floor plans.
- Keep memories concise. Prune outdated ones (e.g. after descending).

Think briefly before acting, then call "play"."""

TOOLS = [
    {
        "name": "play",
        "description": "Execute a game action. Must be called exactly once per turn.",
        "input_schema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "description": (
                        "The action to take, e.g. 'move:up', 'attack', "
                        "'pickup', 'descend', 'wait'."
                    ),
                },
            },
            "required": ["action"],
        },
    },
    {
        "name": "record_memory",
        "description": "Save a note about the game. Be concise.",
        "input_schema": {
            "type": "object",
            "properties": {
                "memory": {
                    "type": "string",
                    "description": "The memory to record.",
                },
            },
            "required": ["memory"],
        },
    },
    {
        "name": "delete_memory",
        "description": "Delete an outdated or redundant memory by its index.",
        "input_schema": {
            "type": "object",
            "properties": {
                "index": {
                    "type": "integer",
                    "description": "0-based index of the memory to delete.",
                },
            },
            "required": ["index"],
        },
    },
]

@dataclass
class TurnResult:
    action: str
    reasoning: str
    response_blocks: list[dict]
    tool_use_ids: list[str]


class ExploredMap:
    """Stitches 7x7 viewports into a cumulative explored map per floor."""

    tiles: dict[tuple[int, int], str]
    player_trail: list[tuple[int, int]]

    def __init__(self) -> None:
        self.tiles = {}
        self.player_trail = []

    def update(self, grid: list[str], px: int, py: int) -> None:
        half = len(grid) // 2
        for vy, row in enumerate(grid):
            for vx, ch in enumerate(row):
                wx = px + (vx - half)
                wy = py + (vy - half)
                if ch != " ":
                    self.tiles[(wx, wy)] = ch
        if not self.player_trail or self.player_trail[-1] != (px, py):
            self.player_trail.append((px, py))

    def render_around(self, px: int, py: int, radius: int = 7) -> list[str]:
        visited = set(self.player_trail)
        rows: list[str] = []
        for wy in range(py - radius, py + radius + 1):
            row: list[str] = []
            for wx in range(px - radius, px + radius + 1):
                if wx == px and wy == py:
                    row.append("@")
                elif (wx, wy) in self.tiles:
                    ch = self.tiles[(wx, wy)]
                    if ch in ".@" and (wx, wy) in visited:
                        row.append("~")
                    else:
                        row.append(ch)
                else:
                    row.append(" ")
            rows.append("".join(row))
        return rows

    def stats(self) -> dict[str, int]:
        floors = sum(1 for ch in self.tiles.values() if ch in ".@>")
        walls = sum(1 for ch in self.tiles.values() if ch == "#")
        visited = len(set(self.player_trail))
        return {
            "explored_tiles": floors + walls,
            "visited": visited,
            "floor_tiles": floors,
        }


class Memories:
    """Claude-managed memory list with record/delete operations."""

    entries: list[str]

    def __init__(self) -> None:
        self.entries = []

    def record(self, memory: str) -> None:
        self.entries.append(memory)

    def delete(self, index: int) -> None:
        if 0 <= index < len(self.entries):
            self.entries.pop(index)

    def format(self) -> str:
        if not self.entries:
            return "<memories>(empty)</memories>"
        lines = ["<memories>"]
        for i, entry in enumerate(self.entries):
            lines.append(f"  <memory id='{i}'>{entry}</memory>")
        lines.append("</memories>")
        return "\n".join(lines)

    def reset(self) -> None:
        self.entries.clear()


@dataclass
class GameSession:
    client: anthropic.Anthropic
    model: str
    base_url: str
    delay: float
    history: list[dict] = field(default_factory=list)
    explored_map: ExploredMap = field(default_factory=ExploredMap)
    memories: Memories = field(default_factory=Memories)
    recent_actions: list[str] = field(default_factory=list)
    death_lessons: list[str] = field(default_factory=list)
    run_number: int = 1
    turn: int = 0
    player_x: int = 0
    player_y: int = 0


def post_log(base_url: str, line: str, detail: str = "") -> None:
    try:
        requests.post(
            f"{base_url}/dungeon/log",
            json={"line": line, "detail": detail},
            timeout=2,
        )
    except requests.RequestException:
        pass


def get_state(base_url: str) -> dict:
    resp = requests.get(f"{base_url}/dungeon/state", timeout=5)
    resp.raise_for_status()
    return resp.json()


def execute_action(base_url: str, action: str) -> None:
    endpoint_map = {
        "attack": "/dungeon/attack",
        "pickup": "/dungeon/pickup",
        "descend": "/dungeon/descend",
        "new": "/dungeon/new",
    }

    if action.startswith("move:"):
        direction = action.split(":", 1)[1]
        requests.get(
            f"{base_url}/dungeon/move",
            params={"dir": direction, "redirect": "none"},
            allow_redirects=False,
            timeout=5,
        )
    elif action == "wait":
        requests.get(
            f"{base_url}/dungeon/move",
            params={"dir": "wait", "redirect": "none"},
            allow_redirects=False,
            timeout=5,
        )
    elif action in endpoint_map:
        requests.get(
            f"{base_url}{endpoint_map[action]}",
            params={"redirect": "none"},
            allow_redirects=False,
            timeout=5,
        )


def detect_loop(recent_actions: list[str]) -> str | None:
    if len(recent_actions) < 6:
        return None
    recent = recent_actions[-6:]
    is_oscillating = (
        recent[-1] == recent[-3] == recent[-5]
        and recent[-2] == recent[-4] == recent[-6]
        and recent[-1] != recent[-2]
    )
    if is_oscillating:
        return (
            f"You are looping between {recent[-1]} and {recent[-2]}. "
            f"Try a different direction!"
        )
    is_repeating = len(set(recent[-4:])) == 1 and recent[-1] != "attack"
    if is_repeating:
        return f"You repeated '{recent[-1]}' 4 times. Try something different!"
    return None


def format_turn(state: dict, session: GameSession) -> str:
    player = state["player"]
    hp_pct = player["hp"] / player["max_hp"] * 100 if player["max_hp"] > 0 else 0

    lines = [
        f"<turn id='{session.turn}'>",
        f"<stats>"
        f"Floor {state['floor']} | "
        f"HP: {player['hp']}/{player['max_hp']} ({hp_pct:.0f}%) | "
        f"ATK: {player['attack']} | DEF: {player['defense']} | "
        f"Pos: ({session.player_x},{session.player_y})"
        f"</stats>",
        f"<message>{state['message']}</message>",
    ]

    loop_warning = detect_loop(session.recent_actions)
    if loop_warning:
        lines.append(f"<warning>{loop_warning}</warning>")

    lines.append("<explored_map>")
    for row in session.explored_map.render_around(session.player_x, session.player_y):
        lines.append(f"  {row}")
    stats = session.explored_map.stats()
    lines.append(f"  [{stats['visited']} visited / {stats['floor_tiles']} known]")
    lines.append("</explored_map>")

    if state["visible_monsters"]:
        lines.append("<monsters>")
        for mon in state["visible_monsters"]:
            dist = abs(mon["dx"]) + abs(mon["dy"])
            adj = " ADJACENT" if dist == 1 else ""
            lines.append(
                f"  {mon['name']} ({mon['dx']},{mon['dy']}) "
                f"HP:{mon['hp']}/{mon['max_hp']} "
                f"ATK:{mon['attack']} DEF:{mon['defense']}{adj}"
            )
        lines.append("</monsters>")

    if state["visible_items"]:
        lines.append("<items>")
        for item in state["visible_items"]:
            here = " HERE" if item["dx"] == 0 and item["dy"] == 0 else ""
            lines.append(
                f"  {item['name']} ({item['dx']},{item['dy']}) "
                f"{item['effect']}:{item['value']}{here}"
            )
        lines.append("</items>")

    lines.append(session.memories.format())
    lines.append(
        f"<available_actions>{', '.join(state['available_actions'])}</available_actions>"
    )
    lines.append("</turn>")

    return "\n".join(lines)


def process_tool_calls(
    content: list,
    memories: Memories,
) -> tuple[str | None, str, list[dict], list[str]]:
    action: str | None = None
    reasoning = ""
    response_blocks: list[dict] = []
    tool_use_ids: list[str] = []

    for block in content:
        if isinstance(block, TextBlock):
            reasoning += block.text
            response_blocks.append({"type": "text", "text": block.text})
        elif isinstance(block, ToolUseBlock):
            response_blocks.append({
                "type": "tool_use",
                "id": block.id,
                "name": block.name,
                "input": block.input,
            })
            tool_use_ids.append(block.id)

            if block.name == "play":
                action = block.input.get("action", "wait")
            elif block.name == "record_memory":
                mem = block.input.get("memory", "")
                if mem:
                    memories.record(mem)
            elif block.name == "delete_memory":
                idx = block.input.get("index", -1)
                memories.delete(idx)

    return action, reasoning, response_blocks, tool_use_ids


def validate_action(action: str | None, available: list[str]) -> str:
    if action and action in available:
        return action
    if action:
        match = next((a for a in available if a in action or action in a), None)
        if match:
            return match
    return "wait" if "wait" in available else available[0]


def ask_claude(state: dict, session: GameSession) -> TurnResult:
    state_text = format_turn(state, session)
    available = state["available_actions"]

    messages: list[dict] = []
    for entry in session.history[-5:]:
        messages.append({"role": "user", "content": entry["state"]})
        messages.append({"role": "assistant", "content": entry["response_blocks"]})
        messages.append({
            "role": "user",
            "content": [
                {"type": "tool_result", "tool_use_id": tid, "content": "ok"}
                for tid in entry["tool_use_ids"]
            ],
        })
    messages.append({"role": "user", "content": state_text})

    system = SYSTEM_PROMPT
    if session.death_lessons:
        lessons = "\n".join(f"- {l}" for l in session.death_lessons)
        system += f"\n\nLESSONS FROM PREVIOUS RUNS:\n{lessons}"

    resp = session.client.messages.create(
        model=session.model,
        max_tokens=300,
        system=system,
        tools=TOOLS,
        messages=messages,
    )

    raw_action, reasoning, response_blocks, tool_use_ids = process_tool_calls(
        resp.content, session.memories
    )
    action = validate_action(raw_action, available)

    return TurnResult(
        action=action,
        reasoning=reasoning,
        response_blocks=response_blocks,
        tool_use_ids=tool_use_ids,
    )


def sync_position(state: dict, session: GameSession) -> None:
    player = state["player"]
    session.player_x = player["x"]
    session.player_y = player["y"]


def apply_action(action: str, state: dict, session: GameSession) -> None:
    if action == "descend":
        session.explored_map = ExploredMap()

    session.recent_actions.append(action)
    if len(session.recent_actions) > 20:
        session.recent_actions.pop(0)


def print_turn(state: dict, action: str, reasoning: str, session: GameSession) -> None:
    player = state["player"]
    monster_count = len(state["visible_monsters"])
    item_count = len(state["visible_items"])
    stats = session.explored_map.stats()
    full_thought = reasoning.strip().replace("\n", " ") if reasoning else ""
    short_thought = full_thought[:60] if full_thought else ""

    line = (
        f"T{session.turn:>4d} | F{state['floor']} | "
        f"HP:{player['hp']:>3d}/{player['max_hp']} | "
        f"ATK:{player['attack']:>2d} DEF:{player['defense']:>2d} | "
        f"M:{monster_count} I:{item_count} | "
        f"vis:{stats['visited']:>3d} mem:{len(session.memories.entries):>2d} | "
        f"-> {action:>12s}"
    )
    if short_thought:
        line += f" | {short_thought}"
    print(line)
    post_log(session.base_url, line, detail=full_thought)


def analyze_death(state: dict, session: GameSession) -> str:
    recent = session.recent_actions[-15:]
    stats = session.explored_map.stats()
    memories = session.memories.entries[:] if session.memories.entries else []

    context = (
        f"Run #{session.run_number} ended: {state['message']}\n"
        f"Floor {state['floor']}, turn {session.turn}, "
        f"{stats['visited']} tiles visited\n"
        f"Final stats: ATK:{state['player']['attack']} DEF:{state['player']['defense']}\n"
        f"Last 15 actions: {', '.join(recent)}\n"
    )
    if memories:
        context += f"Active memories: {'; '.join(memories)}\n"

    try:
        resp = session.client.messages.create(
            model=session.model,
            max_tokens=150,
            system=(
                "You are analyzing a roguelike game death. "
                "Write ONE concise lesson (1-2 sentences) about what to do differently. "
                "Be specific and actionable. No preamble."
            ),
            messages=[{"role": "user", "content": context}],
        )
        return resp.content[0].text.strip()
    except Exception:
        return ""


def handle_death(state: dict, session: GameSession) -> None:
    stats = session.explored_map.stats()
    death_line = (
        f"DIED on floor {state['floor']}! {state['message']} "
        f"({session.turn} turns, {stats['visited']} tiles)"
    )
    print(f"\n  {death_line}")
    post_log(session.base_url, death_line)

    lesson = analyze_death(state, session)
    if lesson:
        session.death_lessons.append(lesson)
        if len(session.death_lessons) > 5:
            session.death_lessons.pop(0)
        print(f"  Lesson: {lesson}")
        post_log(session.base_url, f"  Lesson: {lesson}")

    print(f"  Run #{session.run_number} complete. Restarting...\n")
    post_log(session.base_url, f"  Starting run #{session.run_number + 1}")

    execute_action(session.base_url, "new")
    session.history.clear()
    session.explored_map = ExploredMap()
    session.memories.reset()
    session.recent_actions.clear()
    session.turn = 0
    session.run_number += 1
    time.sleep(2)


def run_game_loop(session: GameSession) -> None:
    try:
        while True:
            state = get_state(session.base_url)

            if state["dead"]:
                handle_death(state, session)
                continue

            sync_position(state, session)
            session.explored_map.update(
                state["grid"], session.player_x, session.player_y
            )
            session.turn += 1

            result = ask_claude(state, session)
            print_turn(state, result.action, result.reasoning, session)
            execute_action(session.base_url, result.action)
            apply_action(result.action, state, session)

            state_text = format_turn(state, session)
            session.history.append({
                "state": state_text,
                "response_blocks": result.response_blocks,
                "tool_use_ids": result.tool_use_ids,
            })
            if len(session.history) > 7:
                session.history.pop(0)

            time.sleep(session.delay)

    except KeyboardInterrupt:
        stats = session.explored_map.stats()
        print(f"\nStopped after {session.turn} turns | {stats['visited']} tiles visited")
        if session.memories.entries:
            print(f"  Final memories ({len(session.memories.entries)}):")
            for i, mem in enumerate(session.memories.entries):
                print(f"    {i}. {mem}")
    except requests.ConnectionError:
        print(f"\nCannot connect to {session.base_url}. Is the server running?")
        sys.exit(1)


def main() -> None:
    parser = argparse.ArgumentParser(description="AI dungeon crawler player")
    parser.add_argument("--url", default=GAME_URL, help="Game server URL")
    parser.add_argument("--model", default=MODEL, help="Claude model to use")
    parser.add_argument(
        "--delay", type=float, default=TURN_DELAY, help="Seconds between turns"
    )
    parser.add_argument(
        "--new", action="store_true", help="Start a new game before playing"
    )
    args = parser.parse_args()

    session = GameSession(
        client=anthropic.Anthropic(),
        model=args.model,
        base_url=args.url,
        delay=args.delay,
    )

    print(f"Connecting to {args.url}...")
    print(f"Using model: {args.model}")
    print(f"Watch the game at: {args.url}/dungeon/watch")
    print()

    if args.new:
        execute_action(args.url, "new")
        time.sleep(0.5)

    run_game_loop(session)


if __name__ == "__main__":
    main()
