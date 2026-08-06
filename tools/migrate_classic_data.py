#!/usr/bin/env python3
"""Migrate a classic BeamJoy (<= V3.x) BeamJoyData/db folder to the V4 (sandbox-based) format.

Usage:
    python tools/migrate_classic_data.py <classic_db_dir> <output_db_dir>

Example:
    python tools/migrate_classic_data.py "L:/Server/BeamMP/0.38/Server/BeamJoyData/db" "L:/Server/BeamMP/Resources/Server/BeamJoyData/db"

What it does (verified against both codebases, 2026-08):
- groups.json: classic = name-keyed map with sparse numeric levels (none=0, player=2, mod=5,
  admin=7, owner=100); V4 = ordered ARRAY where the position IS the level. Groups are
  flattened order-preserving by level, classic names are remapped (none -> default), and the
  V4-only chat color fields (nameColor/textColor) are backfilled with defaults.
- players/<name>.json: field mapping (beammp -> beammpID), moderation fields carried as-is,
  and classic's reputation/stats (delivery/race/bus counters) preserved under
  data.classic — the V4 reputation port will read them from there.
- Never overwrites an existing output file unless --force is given.

Classic features with no V4 counterpart yet (scenarii/, environment, maps, bjc.json) are NOT
migrated: their V4 formats differ or do not exist yet; the scenario data migration will ship
with the scenario framework (see TRACKING.md section 15).
"""
import json
import sys
from pathlib import Path

CLASSIC_TO_V4_GROUP_NAMES = {"none": "default"}
DEFAULT_NAME_COLOR = [1, 1, 1]
DEFAULT_TEXT_COLOR = [1, 1, 1]


def load_json(path: Path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def save_json(path: Path, data, force: bool):
    if path.exists() and not force:
        print(f"  SKIP (exists): {path}")
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent=4, ensure_ascii=False)
    print(f"  wrote {path}")
    return True


def migrate_groups(classic_db: Path, out_db: Path, force: bool):
    src = classic_db / "groups.json"
    if not src.exists():
        print("  no classic groups.json, skipping")
        return {}
    classic = load_json(src)
    # classic: { name: {level, vehicleCap, banned, whitelisted, muted, staff, permissions[]} }
    ordered = sorted(classic.items(), key=lambda kv: kv[1].get("level", 0))
    v4 = []
    name_map = {}
    for name, g in ordered:
        v4_name = CLASSIC_TO_V4_GROUP_NAMES.get(name, name)
        name_map[name] = v4_name
        v4.append({
            "name": v4_name,
            "vehicleCap": g.get("vehicleCap", 1),
            "banned": bool(g.get("banned", False)),
            "whitelisted": bool(g.get("whitelisted", False)),
            "muted": bool(g.get("muted", False)),
            "staff": bool(g.get("staff", False)),
            "permissions": g.get("permissions", []),
            "nameColor": DEFAULT_NAME_COLOR,
            "textColor": DEFAULT_TEXT_COLOR,
        })
    save_json(out_db / "groups.json", v4, force)
    print(f"  {len(v4)} groups migrated (levels flattened to array order)")
    return name_map


def migrate_players(classic_db: Path, out_db: Path, name_map: dict, force: bool):
    src_dir = classic_db / "players"
    if not src_dir.is_dir():
        print("  no classic players/ dir, skipping")
        return
    count, skipped = 0, 0
    for src in sorted(src_dir.glob("*.json")):
        p = load_json(src)
        v4 = {
            "playerName": p.get("playerName") or src.stem,
            "ip": p.get("ip"),
            "beammpID": p.get("beammp"),
            "lang": p.get("lang"),
            "group": name_map.get(p.get("group"), p.get("group") or "default"),
            "muted": p.get("muted"),
            "muteReason": p.get("muteReason"),
            "banned": p.get("banned"),
            "tempBanUntil": p.get("tempBanUntil"),
            "banReason": p.get("banReason"),
            "kickReason": p.get("kickReason"),
            # classic progression data, preserved for the V4 reputation/stats port
            "data": {
                "classic": {
                    "reputation": p.get("reputation", 0),
                    "stats": p.get("stats", {}),
                }
            },
        }
        if save_json(out_db / "players" / src.name, v4, force):
            count += 1
        else:
            skipped += 1
    print(f"  {count} players migrated, {skipped} skipped")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    force = "--force" in sys.argv
    if len(args) != 2:
        print(__doc__)
        sys.exit(1)
    classic_db, out_db = Path(args[0]), Path(args[1])
    if not classic_db.is_dir():
        print(f"classic db dir not found: {classic_db}")
        sys.exit(1)

    print("== groups ==")
    name_map = migrate_groups(classic_db, out_db, force)
    print("== players ==")
    migrate_players(classic_db, out_db, name_map, force)
    print("done. NOT migrated (formats differ / V4 pending): bjc.json, environment.json, "
          "maps.json, scenarii/ (ships with the V4 scenario framework), vehicles.json")


if __name__ == "__main__":
    main()
