# BeamJoy — BeamNG 0.39 Port · Tracking & Architecture

> **Living document.** Central knowledge base for the BeamNG 0.39 port of BeamJoy.
> Updated continuously as work progresses. Keep this file at the repo root.
>
> Last update: 2026-08-05 — **V3.0.0** (0.39 port + stabilization + UI optimization)

---

## 1. Mission

Port **BeamJoy v2.0.8** (currently targeting BeamNG **0.38**) to BeamNG **0.39.x**, cleanly:

1. **Phase 1 (current):** make every feature work on 0.39, one by one — an ULTRA-clean port
   to the new BeamNG/BeamMP APIs. English comments. No feature changes.
2. **Phase 2 (later):** improve, streamline, extend.

The mod ships as a **double ZIP**:
- **Server side** (BeamMP server resource): `BeamJoyCore` + `BeamJoyChatHandler` + `BeamJoyData` (db)
- **Client side** (sent to players by BeamMP): `BJI.zip` — built from `BeamJoyInterface/`

---

## 2. Environment map

| Role | Path | Notes |
|---|---|---|
| **Working repo (this Git)** | `E:\compt\Documents\4 - VSC\BeamJoy` | Fork `YannD-Deltagon/BeamJoy` of `my-name-is-samael/BeamJoy` (remote `upstream`). Branch `main`. |
| **BeamJoy-sandbox (merge target)** | `E:\compt\Documents\4 - VSC\BeamJoy-sandbox` | Official remake by the original author (`my-name-is-samael/BeamJoy-sandbox`, v1.0.4, last commit 2025-12-11 = **pre-0.39**). HTML/Angular UI, sandbox-only scope, **incompatible with classic**. See §12-§13. |
| **BeamMP client source** | `E:\compt\Documents\4 - VSC\BeamMP` | Reference for multiplayer integration (`MPCoreNetwork`, `MPGameNetwork`, `MPVehicleGE`, mod loading). |
| **Game install (0.39 source of truth)** | `C:\Program Files (x86)\Steam\steamapps\common\BeamNG.drive` | **v0.39.2.1**, build 20887 (2026-07-31). Game Lua is **unpacked** under `lua\` — use it to verify every API. |
| **Game user profile** | `C:\Users\compt\AppData\Local\BeamNG\BeamNG.drive\current` | Logs (`beamng.log`), `mods\` (BeamMP.zip lives in `mods\multiplayer\`), settings, cache. |
| **Test server (remote PC, mounted)** | `L:\Server\BeamMP` | Live BeamMP server. `Resources\Server\` = BeamJoyCore v2.0.8 + BeamJoyData; `Resources\Client\BJI.zip` = deployed client mod. `ServerConfig.toml` (never commit its AuthKey). |

Key game-source files for the port:
- `<game>\lua\common\extensions\ui\imgui.lua` (+ `imgui_api.lua`, `imgui_luaintf.lua`, `cdefImgui.lua`) — the 0.39 imgui surface
- `<game>\lua\ge\extensions\core\*` / `gameplay\*` — GE modules (`core_*`, `gameplay_*` globals)
- `<game>\lua\ge\extensions\ui\*` — UI apps / streams

Version facts verified on this machine:
- `beamng.log`: `Current version: '0.39.2.1.20887'` — BeamMP reports *"compatible with the current version"*.
- Server log: `BeamJoyCore v2.0.8 loaded !` → **server side boots fine**; the breakage is client-side (BJI).
- No BeamJoy session has been logged on 0.39 on this PC yet → breakage analysis is done by
  static cross-reference against the unpacked 0.39 game Lua (workflow, see §6).

---

## 3. Repository layout

```
BeamJoy/
├── BeamJoyCore/            # SERVER (runs inside BeamMP server Lua VM)
│   ├── BeamJoyCore.lua     # entrypoint
│   ├── managers/           # 19 managers (Cache, Config, Groups, Permissions, Players,
│   │                       #   Votes, Maps, Environment, Tournament, Vehicles, Chat…)
│   ├── scenarii/           # server-side scenario logic (races, hunter, derby…)
│   ├── rx/ tx/             # inbound / outbound network controllers (protocol)
│   ├── dao/                # file-system DAO (JSON db under BeamJoyData/) — swappable
│   ├── lang/               # server-side i18n (en, fr, de, it, es, pt, ru, tr)
│   ├── utils/              # helpers
│   └── tests/
├── BeamJoyChatHandler/     # chat bridge resource (Discord ChatHook compat)
├── BeamJoyInterface/       # CLIENT (zipped as BJI.zip, sent to players)
│   ├── scripts/BeamJoyInterface/modScript.lua   # bootstrap: load('BeamJoyInterface'), manual unload mode
│   ├── lua/ge/extensions/BeamJoyInterface.lua   # main GE extension entrypoint
│   ├── lua/ge/extensions/BJI/
│   │   ├── managers/       # 45 client managers (Cache, Vehicle, Scenario, Tick, Restrictions,
│   │   │                   #   Nametags, Env, Camera, GPS, Markers, Drift, Pursuit, VehSelector…)
│   │   ├── scenario/       # 13 client scenarios (Freeroam, RaceSolo/Multi, Hunter, Derby,
│   │   │                   #   Speed, Infected, TagDuo, Deliveries, BusMission…)
│   │   ├── rx/ tx/         # client side of the protocol
│   │   └── ui/             # imgui layer: Builders.lua, CommonStyle.lua, windows/ (~35 windows)
│   ├── lua/ge/extensions/utils/   # Icons, UI, MATH, Table, String, ShapeDrawer…
│   ├── lua/vehicle/extensions/BeamJoyInterface/BJIPhysics.lua  # vehicle-VM extension
│   └── art/                # sounds, thumbnails
├── development/            # dev tooling & type stubs
└── assets/                 # readme images
```

Git state at start of port: `main` @ `6c5ff46` *"0.38 update"* (mod v2.0.8).

---

## 4. Architecture map

### 4.0 Runtime topology

```
BeamMP SERVER (Lua)                          BeamNG CLIENT (GE Lua)
┌───────────────────────────┐                ┌────────────────────────────────┐
│ BeamJoyCore  (plugin)     │                │ BJI.zip  → mods/multiplayer/   │
│  managers/ dao/ scenarii/ │                │  BeamJoyInterface extension    │
│  rx/  tx/                 │◄─ BJCEvent ───►│  managers/ scenario/ ui/ rx/tx │
├───────────────────────────┤   BJCEventData └────────────────────────────────┘
│ BeamJoyChatHandler        │  (2 wire events)         ▲
│  (separate plugin/state)  │                          │ BeamMP client
└───────────────────────────┘                   MPCoreNetwork / MPGameNetwork
        ▲ MP.TriggerGlobalEvent                        / MPVehicleGE
        │ (onBJCChatMessage / onBJCConsoleInput)
   native chat & console
```

Three independent Lua states: **BeamJoyCore** (server), **BeamJoyChatHandler** (server,
isolated on purpose), **BeamJoyInterface** (client). Cross-plugin server communication goes
through `MP.TriggerGlobalEvent`; client↔server goes through the custom BJC protocol (§4.3).

### 4.1 Server — BeamJoyCore

- **Entrypoint** `BeamJoyCore.lua`: computes `BJCPluginPath`, defines the global `onInit()`
  that BeamMP calls, `pcall`s `loadBeamJoy()` which `require`s utils then all managers **in a
  strict order** (Events → Async → Defaults → Dao → Core → Cache → Vehicles → Config → Lang →
  Groups → Players → Perm → Maps → Command → Vote → Tx → Environment → ChatCommand → Chat →
  ScenarioData → Scenario → Tournament → Rx). Each `require` runs the module's `init()`
  immediately and publishes a global (`BJCEvents`, `BJCDao`, `BJCCore`, …). **Load order is
  load-bearing.**
- **EventsManager** = the BeamMP bridge. At require time it `MP.RegisterEvent`s a global
  `BJC<key>` handler for every native hook (`onPlayerAuth/Connecting/Joining/Join/Disconnect`,
  `onVehicleSpawn/Reset/Edited/PaintChanged/Deleted`, `onFileChanged`) plus the custom
  `onBJCChatMessage` / `onBJCConsoleInput`, and creates two `MP.CreateEventTimer` timers:
  **fastTick 100 ms** and **slowTick 1000 ms**. It fans events to a pub/sub listener table with
  cancellable returns (int ≠ 0 cancels a vehicle spawn/edit, string cancels console input;
  `onPlayerAuth`: `1` = deny, `2` = bypass, string = reason).
- **Chat/console are rerouted**: `BeamJoyChatHandler` registers the native `onChatMessage` /
  `onConsoleInput`, **always cancels them** (`return 1` / `""`) and re-emits them as global
  events — a documented workaround for BeamMP-Server issue #435. All chat then flows through
  `ChatManager` and reaches clients over the `BJCPlayer/"chat"` protocol endpoint.
- **Persistence (DAO)**: flat JSON under `Resources/Server/BeamJoyData/db/` (path derived by
  replacing `BeamJoyCore` with `BeamJoyData/db` in `BJCPluginPath`). Singletons `core.json`,
  `bjc.json`, `groups.json`, `permissions.json`, `environment.json`, `maps.json`,
  `vehicles.json`, `tournaments.json`; one file per player in `players/<name>.json`; per-map
  scenario files in `scenarii/<map>_races|_stations|_deliveries|_buslines|_hunter|_derby.json`.
  All writes are atomic (write `.temp` → `FS.Remove` + `FS.Rename`), and every DAO `init()`
  seeds from `managers/Defaults.lua` when the file is missing.
- **Config**: `bjc.json` = BeamJoy feature config (Server lang/theme/broadcasts/welcome,
  Freeroam rules, Reputation rewards, per-scenario timeouts, Whitelist, VoteKick/VoteMap,
  TempBan bounds, CEN toggles), merged over Defaults at boot, mutated per `"Parent.Key"` with
  permission checks + clamping. `core.json` mirrors BeamMP core settings and `FileCore` keeps
  it two-way synced with `ServerConfig.toml [General]` via the bundled TOML codec, pushing into
  the live server with `MP.Set(MP.Settings[k])` — and forcing `MaxCars ≥ 200` so BeamJoy's own
  per-group `vehicleCap` does the real limiting.
- **Permissions (2 layers)**: `groups.json` (defaults none=0, player=2, mod=5, admin=7,
  owner=100) each `{level, vehicleCap (0=none, -1=unlimited), banned, whitelisted, muted,
  staff, permissions[]}`; `permissions.json` maps ~30 named permissions to a minimum level.
  `BJCPerm.hasPermission` passes if the group lists the permission explicitly **or**
  `group.level >= required`.
- **Map switching**: `CoreManager.setMap` moves custom map archives between `Resources/` root
  and `Resources/Client/`, kicks everyone with a countdown, and `Exit()`s for reboot when the
  map mod changes (hence the "have a reboot loop" instruction — `BeamMPLoop.bat`).

### 4.2 Server — scenarios, votes, tournament

Server-authoritative state machines driven by client events.
- **ScenarioManager** distinguishes: **exclusive** server scenarios (Race, Speed, Hunter,
  Infected, Derby — only one at a time via the `CurrentScenario` pointer), **hybrid** ones
  players join/leave freely (DeliveryMulti, TagDuo), and **solo** ones stored as a string on
  the player object (raceSolo, deliveryVehicle, deliveryPackage, busMission, handled by
  PlayerManager).
- Lifecycle for exclusives: `start()` validates + calls `stopServerScenarii()` → PREPARATION/
  GRID phase collects participants (Join/Ready events, `BJCAsync` grid timeout) → GAME/RACE
  phase processes gameplay events → win condition or participant starvation triggers a delayed
  stop. **Note: only the grid/preparation phases have timeouts — no watchdog during GAME.**
- **ScenarioDataManager** owns static data (races with branching waypoint steps, delivery
  points/hubs, bus lines, hunter/infected spawns, derby arenas, energy stations, garages),
  loaded per map, validated on save, with a 2.0.0 in-place migration. Races carry a content
  hash (`loopable + startPositions + steps`) that clients use to detect stale local data, plus
  a persistent best-lap record.
- **VotesManager** runs three flows (Kick, Map, Scenario). A player *vote* and a staff *direct
  start* share one pipeline: store type+settings+voters, program a timeout, then on expiry
  either check the voter threshold (vote) or start unconditionally (direct).
- **TournamentManager** is an optional scoring overlay persisted in `tournaments.json`:
  each scenario start appends an activity, managers push positional scores (lower total =
  better; missing score counts as #players), with a special timed solo-race activity.

### 4.3 Protocol (the seam)

Everything multiplexes over **exactly two BeamMP wire events**: `BJCEvent` (header) and
`BJCEventData` (payload chunks), declared identically in `BeamJoyCore/utils/Constants.lua` and
`BeamJoyInterface/lua/ge/extensions/utils/Constants.lua` (TX/RX tables mirrored per direction).

- **Addressing**: controller name (`BJCCache`, `BJCPlayer`, `BJCScenario`, …) + endpoint string
  (`require`, `tick`, `RaceSave`, …). On receive, a generic dispatcher calls the controller
  function whose *name equals the endpoint*.
- **Chunking**: payload wrapped in a table → JSON (server `JSON.stringifyRaw`, client
  `jsonEncode`) → sliced into **20 000-char chunks** (`PAYLOAD_LIMIT_SIZE`). Sender emits
  `{id=UUID, parts=N, controller, endpoint}` on `BJCEvent`, then `{id, part=i, data=chunk}` on
  `BJCEventData`. Receivers reassemble per UUID (server finalizes on fastTick when
  `#chunks == parts`, 30 s timeout; client finalizes eagerly per packet).
- **Transport**: server→client `MP.TriggerClientEvent(targetID, name, jsonString)` (`-1` =
  broadcast; `TriggerClientEventJson` is *not* used since payloads are pre-stringified);
  client→server the BeamMP client globals `TriggerServerEvent` / `AddEventHandler`.
- **Sync model = pull-based, hash-driven.** The client never receives unsolicited state.
  Every second the server sends a per-player `tick` containing the hashes of ~26 named caches +
  server time + ToD; the client compares hashes, marks stale caches, and requests them
  (`BJI_Tx_cache.require` → `BJCCache.getCache` (permission-checked) → `BJCTx.cache.send` →
  client `BJI_Cache.handleRx`). Server-side "invalidation" simply pushes a fresh cache.
- **Errors**: server rx controllers `error({key = lang_key})`; the dispatcher pcalls and
  converts it into a localized toast for the sender.

### 4.4 Client — bootstrap

1. BeamMP launcher downloads `Resources/Client/BJI.zip` → `mods/multiplayer/` → BeamNG
   `core_modmanager` mounts it → runs `scripts/BeamJoyInterface/modScript.lua` (2 lines:
   `load('BeamJoyInterface')` + `setExtensionUnloadMode(..., 'manual')`).
2. `lua/ge/extensions/BeamJoyInterface.lua` does **heavy top-level work at require time**
   (before `onExtensionLoaded`): LoadDefaults → `log.lua` (Log* globals) → LUA/MATH/String/
   Table (**monkey-patches the shared `math`/`string`/`table` globals** + defines `Table`,
   `Range`, `UUID`, `TrueFn`, `GetCurrentTimeMillis`, `dump`…), creates the global `BJI` root
   (VERSION 2.0.8, CONSTANTS, Utils.{ShapeDrawer,Icon,UI,Style}, Bench, Physics), then
   auto-discovers every file in `BJI/managers` via `FS:directoryList` and registers each as
   both `BJI.Managers[name]` and a global `BJI_<name>`, then `BJI.Tx` / `BJI.Rx`.
3. `M.dependencies` declares ~25 game extensions (`ui_imgui`, `gameplay_traffic`,
   `gameplay_police`, `core_multiSpawn`, `gameplay_drift_*`, `freeroam_bigMapMode`,
   `gameplay_walk`, `core_jobsystem`, `ui_missionInfo`, …).
4. `onExtensionLoaded` requires `ui/Builders.lua` (installs the UI globals), initializes
   `BJI_Context.GUI` from the game's `ge/extensions/editor/api/gui`, and pcall-runs each
   manager's `onLoad`.
5. **Ready handshake** in `onUpdate`: once `WorldReadyState == 2` **and** imgui framerate > 5,
   sets `BJI.CLIENT_READY`, shows the loading overlay, sends `BJI_Tx_player.connected()`, waits
   for base caches, fires `ON_POST_LOAD`.
6. `bindNGHooks` maps ~16 BeamNG GE hooks onto the internal `BJI_Events` bus, so the rest of
   the mod only ever listens to BJI events.
7. Vehicle-VM side: `lua/vehicle/extensions/BeamJoyInterface/BJIPhysics.lua` counts 2000
   physics steps (= 1 s at 2000 Hz), measures wall-clock, and pushes `physmult` back to GE via
   `obj:queueGameEngineLua("BJI.setPhysicsSpeed(...)")` — real physics speed detection.

### 4.5 Client — managers (~45 singletons)

Each returns a table with `_name`, optional `onLoad`, and tick hooks.
- **TickManager** is the heartbeat: `M.client()` runs every frame (gated on
  `WorldReadyState == 2` + `MPGameNetwork.launcherConnected()`), builds a shared `TickContext`
  (now, user, players, current MPVehicle, camera), pcalls every manager's `renderTick`, emits
  FAST_TICK (~250 ms). `M.server()` is driven by the server tick (~1 s) → SLOW_TICK.
- **EventsManager** separates synchronous NG-forwarded game events from queued async app
  events (drained one per frame).
- **CacheManager** implements the client half of the pull protocol; **Context** holds all
  shared state (User, Players, BJC config, Maps, Database) and derives connect/disconnect/
  vehicle-spawn events by diffing cache payloads.
- **Defining pattern — monkey-patching the game.** VehicleManager, VehicleSelectorUIManager,
  InputManager, RestrictionsManager, AIManager, ModsManager, GPSManager, BigmapManager,
  InteractiveMarkerManager and PromptManager save `baseFunctions` and overwrite live functions
  on `core_vehicles`, `core_vehicle_manager`, `core_input_actionFilter`, `gameplay_traffic`,
  `core_groundMarkers`, `freeroam_bigMapPoiProvider`, `gameplay_rawPois`,
  `gameplay_missions_missions`, `core_recoveryPrompt`, `core_modmanager`, `commands`, `spawn`
  and the global `resetGameplay`; they roll back via `RollBackNGFunctionsWrappers`.
  **This is where a game update hurts most.**
- **RestrictionsManager** aggregates `getRestrictions(ctxt)` from every manager and enforces
  through `core_input_actionFilter` — its hardcoded action-name lists are a direct coupling to
  the game's input map.
- Vehicle side effects (freeze, engine, lights, gears, FFB, ghosting, fuel) are executed as
  **string `queueLuaCommand` payloads into vehicle VMs** → both GE-side and vehicle-Lua APIs
  must survive the update, and failures are *silent*.

### 4.6 Client — scenarios

- One active-scenario state machine in **ScenarioManager**. Modules are auto-discovered
  (`FS:directoryList` on `BJI/scenario`), registered into solo/multi lists, always starting in
  FREEROAM. `switchScenario(new)` → `canChangeTo` → `old.onUnload` → set → `new.onLoad`
  (rollback on error) → `SCENARIO_CHANGED` + `BJI_Restrictions.update()`.
- Every game-facing decision is delegated to the active scenario via defaulted dispatchers:
  ticks, vehicle lifecycle hooks, and policy predicates (`canReset`, `tryReset`,
  `getRewindLimit`, `canSpawnNewVehicle`, `canWalk`, `getCollisionsType`, `doShowNametag`,
  `getModelList`, `getRestrictions`, `drawUI`…). Repeated pcall failures force a fallback to
  Freeroam.
- **Respawn strategies** (`ALL_RESPAWNS`, `LAST_CHECKPOINT`, `STAND`, `NO_RESPAWN`) are enforced
  client-side: LAST_CHECKPOINT/STAND continuously re-point the game "home" via
  `BJI_Veh.saveHome` and remap every reset input to `loadHome`; NO_RESPAWN blocks resets and
  runs a DNF countdown; rewind is time-limited by re-calling the base RECOVER action.
- **Checkpoint detection is fully client-side** (`RaceWaypointManager`): it wraps the base-game
  `scenario/race_marker` for visuals (**only `sideColumnMarker` is used — other marker types
  crash on disconnect**) and does its own geometry per frame (vehicle OBB corners, segment
  intersection for gates, radius for pit stands).
- **RaceUIManager / BusUIManager** are pure sinks translating state into stock UI apps via
  `guihooks.trigger` (RaceLapChange, WayPointChange, HotlappingTimer, RaceCheckpointComparison,
  raceTime, ScenarioNotRunning…).
- Multiplayer scenarios are **server-driven**: server caches route into each scenario's
  `rxData(data)`, which itself calls `switchScenario` in/out.

### 4.7 Client — UI layer

Pure immediate-mode imgui on the global `ui_imgui`, rendered from `onUpdate` →
`WindowsManager.renderTick`.
- `Builders.lua` deliberately installs **global** wrappers (`Text`, `Button`, `IconButton`,
  `InputInt/Float/Text`, `Combo`, `Slider*`, `ColorPicker*`, `BeginTable`, `BeginChild`,
  `RenderWindow`, `ImVec2/4`, `BoolPtr/IntPtr/FloatPtr`…) so window files need no `require`.
  Each wrapper pushes theme colors, allocates FFI pointers per call, calls the raw
  `ui_imgui` function with a `##id`-suffixed label, pops styles, returns the changed value.
- **Defensive binding `ui_imgui.X or function() end` means a missing symbol fails SILENTLY**
  (blank widget, no error) — a port must positively verify every symbol.
- UI scaling uses `SetWindowFontScale` + size multiplication from a user-stored `UI_SCALE`
  (no font loading). Icons come from the base game atlas (`Icons.lua`, ~1400 entries) resolved
  through `BJI_Context.GUI` — which is the game's **editor GUI API**
  (`ge/extensions/editor/api/gui`: `initialize`, `registerWindow`, `showWindow`, `hideWindow`,
  `uiIconImage`, `uiIconImageButton`, `.icons`).
- Theming is server-driven: `CommonStyle.lua` maps imgui enums into style tables;
  `LoadTheme(Context.BJC.Server.Theme)` builds them; every frame WindowsManager brackets all
  windows between `InitDefaultStyles()` / `ResetStyles()`.
- Windows are declarative tables `{name, getState, body, menu?, header?, footer?, onLoad?,
  onUnload?, onClose?, minSize/maxSize/size/position/flags}`, auto-discovered from
  `BJI/ui/windows` (26 top-level; subfolders are sub-modules), registered with the editor GUI
  API and as `BJI_Win_<name>`; visibility is polled each frame from `getState()` with
  rising/falling edges.

### 4.7b The Angular → Vue question (0.39 UI migration)

**BeamJoy's own UI is imgui (native Lua), not HTML.** The BeamNG Vue migration therefore does
**not** require rewriting any of BeamJoy's ~35 windows. What BeamJoy touches of the HTML UI is
only ~25 `guihooks.trigger` channels — and 0.39 is a *hybrid*: BeamNG kept the **same Lua-side
contracts** while swapping the JS implementation underneath.

| BeamJoy touchpoint | 0.39 consumer | Verdict |
|---|---|---|
| Race/scenario apps: `raceTime`, `HotlappingTimer`, `RaceLapChange`, `WayPointChange`, `RaceCheckpointComparison`, `RaceTimeComparison`, `ScenarioNotRunning`, `ScenarioResetTimer`, `ScenarioFlashMessage`, `ScenarioRealtimeDisplay`, `BigmapMissionData` | **still legacy Angular UI apps** in `ui/modules/apps/` (`RaceTime`, `RaceLaps`, `Hotlapping`, `RaceCheckpointComparison`, `Odometer`…) | ✅ unchanged |
| `OpenRecoveryPrompt` + `core_recoveryPrompt.{getUIData, uiPopupButtonPressed, uiPopupCancelPressed}` | **moved to Vue** — `ui-vue/src/services/gameContextStore.js:106` listens, `ui-vue/src/modules/recovery/views/Recovery.vue:85/93/101` calls the three Lua functions | ✅ same contract (see B2) |
| `ActivityAcceptUpdate` + `ui_missionInfo.*` | **moved to Vue** — `gameContextStore.js:99`; `ui_missionInfo.openActivityAcceptDialogue/closeDialogue/openDialogue/performActivityAction` all still exist (`lua/ge/extensions/ui/missionInfo.lua`) and still read `elem.buttonFun` | ✅ unchanged |
| `ShowApps` | **Vue** — `ui-vue/src/modules/apps/appLayoutsStore.js:601` | ✅ |
| `chatMessage` | **no consumer left** — BeamMP moved its chat to an imgui window | 🔧 see B10 |

**Why the Vue side still reaches BeamJoy's Lua functions:** the Vue bridge is a generic RPC.
`lua.core_recoveryPrompt.getUIData()` is compiled by `ui-vue/src/bridge/libs/Lua.js:130` into
`runRaw("core_recoveryPrompt.getUIData()")` and executed as **raw Lua in the GE VM**. The name
is resolved on the extension table **at call time**, so a function monkey-patched onto
`extensions.core_recoveryPrompt` is exactly what gets called. BeamNG deleting its *own*
implementation does not remove the contract — it just means whoever supplies the function wins,
and here that is BeamJoy.

### 4.8 BeamMP client integration (reference)

- BeamMP's own `modScript.lua` **hard-gates on BeamNG minor version == 39** (exact match).
- Two TCP sockets to the launcher: **MPCoreNetwork (4444)** session lifecycle, **MPGameNetwork
  (4445)** in-session traffic. Mod API surface for third parties: `AddEventHandler`,
  `RemoveEventHandler`, `TriggerServerEvent`, `TriggerClientEvent`, key-event helpers.
- Join sequence: `C` connect → `L` mod list → `MPModManager.setServerMods` → launcher downloads
  `Resources/Client` zips into `mods/multiplayer/` → `U ldone` → `loadServerMods` mounts the
  zips (**this is when BJI starts**) → `requestMap` → map load → `onClientStartMission` →
  post-join hooks.
- **On leaving a server BeamMP deletes all `mods/multiplayer/` mods and forces a full Lua
  reload** (`Lua:requestReload`) — BeamJoy client state is wiped per session by design.
- `MPVehicleGE` keys everything by `"ownerID-vehID"` strings, replaces
  `core_vehicles.spawnNewVehicle/replaceVehicle/removeAllExceptCurrent/spawnDefault` after
  post-join, and protects vehicles via a `protected` object field. **BeamJoy must spawn through
  the current (MP-wrapped) `core_vehicles` entry points, never through saved originals.**

### 4.9 Packaging

- Client: zip **the contents** of `BeamJoyInterface/` (art/, lua/, scripts/, COPYING, LICENSE)
  → `BJI.zip` → `Resources/Client/`. **Must be zipped with 7-Zip** (stock Windows zip breaks
  the mod, per `development/README.md`).
- Server: copy `BeamJoyCore/` and `BeamJoyChatHandler/` as folders into `Resources/Server/`.
- **The BeamMP launcher cache copy must be purged after each rebuild**
  (`%appdata%\BeamMP-Launcher\Resources\BJI.zip`) or the old client stays live.
- `development/buildLoop.cmd` automates all of it + server restart loop; `development/types/`
  is IDE-only (LuaCATS) and never ships.

---

## 5. BeamNG 0.39 breakage matrix

> Every external API used by `BeamJoyInterface` is cross-checked against the unpacked
> 0.39.2.1 game Lua. Categories: `imgui`, `core_*/gameplay_* GE extensions`,
> engine bindings (`be:`, `scenetree`, `guihooks`, `settings`, `map`…), BeamMP APIs.

Legend: ✅ ok · 🔧 changed (migration needed) · ❌ removed (rewrite needed) · ❓ unsure (needs in-game test)

### 5.1 CONFIRMED BREAKAGE

| # | API | Where in BeamJoy | Status | Fix | Ported |
|---|---|---|---|---|---|
| B1 | `extensions.hook("trackNewVeh")` | `BeamJoyInterface/lua/ge/extensions/BJI/ui/windows/VehSelector.lua` lines **306, 331, 340, 364, 376** | 🔧 renamed in BeamMP 4.22.1 | → `extensions.hook("onBeamMPTrackNewVehicle")` (confirmed `BeamMP/lua/ge/extensions/MPVehicleGE.lua:2199`) | ☐ |

**The BeamMP 0.39 compat release (PR #920, merged 2026-07-30, BeamMP 4.22.1) renamed every
cross-extension hook to an `onBeamMP*` prefix.** BeamJoy uses only one of them, so the blast
radius is small — but the failure mode is *silent* (`extensions.hook` on an unknown name simply
does nothing). Renames to keep in mind if more are added later: `runPostJoin` →
`onBeamMPPostJoin`, `onServerLeave` → `onBeamMPServerLeave`, `onLauncherConnected` →
`onBeamMPLauncherConnected`, `trackCamMode` → `onBeamMPTrackCameraMode`,
`loadControllerSyncFunctions` → `onBeamMPLoadControllerSyncFunctions`. CEF/guihooks events were
renamed the same way (`authReceived` → `onBeamMPAuthReceived`, etc.) — BeamJoy currently uses
none of those. ✔ verified by grep: BeamJoy references **no** other old BeamMP hook name.

### 5.2 VERIFIED OK (no change needed)

**BeamMP client APIs — all 11 used by BeamJoy confirmed present with matching signatures in
BeamMP 4.22.1:**

| API | Evidence (BeamMP source) |
|---|---|
| `MPGameNetwork.launcherConnected` | `MPGameNetwork.lua:591` (def :549) |
| `MPCoreNetwork.getCurrentServer` | `MPCoreNetwork.lua:286`, exported :829 — `{ip, port, name}` |
| `MPVehicleGE.getVehicles` | `MPVehicleGE.lua:406`, exported :2851 |
| `MPVehicleGE.getOwnMap` | `MPVehicleGE.lua:306`, exported :2856 |
| `MPVehicleGE.getGameVehicleID` | `MPVehicleGE.lua:225`, exported :2870 (takes `"ownerID-vehID"`) |
| `MPVehicleGE.isOwn` | `MPVehicleGE.lua:293`, exported :2855 |
| `MPVehicleGE.hideNicknames` | `MPVehicleGE.lua:389`, exported :2861 |
| `MPVehicleGE.applyQueuedEvents` | `MPVehicleGE.lua:2418`, exported :2877 |
| `MPVehicleGE.teleportVehToPlayer` | `MPVehicleGE.lua:2357` — *call site already commented out in BeamJoy* |
| `TriggerServerEvent` | `MPGameNetwork.lua:293` — protocol transport intact |
| `AddEventHandler` | `MPGameNetwork.lua:311` — protocol transport intact |

→ **The BJC protocol itself (§4.3) is safe**: both transport globals are unchanged.

**Critical game modules still present in 0.39.2.1:**

| Module | Path | Why it matters |
|---|---|---|
| editor GUI API | `lua/ge/extensions/editor/api/gui.lua` | icons + window registration — the whole UI depends on it |
| race markers | `lua/ge/extensions/scenario/race_marker.lua` | all race/delivery/hunter waypoint visuals |
| imgui utils | `lua/common/extensions/ui/imguiUtils.lua` | `texObj` vehicle previews in VehSelector |

**imgui binding — the BeamNG-specific numbered/legacy variants BeamJoy relies on are all still
in the 0.39 binding** (`lua/common/extensions/ui/imgui_luaintf.lua` + `imgui_custom_luaintf.lua`,
both still aggregated by `imgui_api.lua`): `BeginChild1`, `Combo1`, `MenuItem1`, `TreeNode1`,
`TreeNodeEx1`, `PushStyleColor2`, `ShowHelpMarker`, `SetWindowFontScale`, `GetMainViewport`,
`Col_TabUnfocused` (**not** renamed to `TabDimmed*` — BeamNG kept the legacy enum),
`BoolPtr`/`IntPtr`/`FloatPtr`/`ArrayChar`/`ArrayFloat`/`ArrayCharPtrByTbl`. **211 of the 213
imgui symbols verified OK — the imgui layer is NOT the main breakage**, contrary to the initial
hypothesis. (The 2 exceptions are `ImVec2One`/`ImVec2Zero`, see B3.)

### 5.3 Exhaustive API verification — RESULT

**425 unique external symbols** inventoried from the client mod (213 imgui · 120 GE extension
functions · 66 engine bindings · 26 other), each verified against the unpacked 0.39.2.1 game
source with a cited `file:line`.

| Status | Count |
|---|---|
| ✅ ok | **410** (96.5 %) |
| ❌ removed | 5 |
| 🔧 changed | 7 |
| ❓ unsure | 3 (2 of which are pre-existing BeamJoy bugs, not 0.39 issues) |

**Verdict: the 0.39 port is far smaller than feared.** The mod is not broadly broken — it has a
handful of precise breakages, one of which (the recovery prompt) needs a real rewrite.

#### Port items

| # | Item | Files | Status | Action |
|---|---|---|---|---|
| **B1** | BeamMP hook renamed | `ui/windows/VehSelector.lua` :306, :331, :340, :364, :376 | 🔧 | `extensions.hook("trackNewVeh")` → `extensions.hook("onBeamMPTrackNewVehicle")` | ✅ |
| **B2** | ~~Recovery prompt contract gone~~ — **downgraded, see below** | `managers/PromptManager.lua` :161-163 | ✅ | **No change needed** — the Vue UI still calls the same three Lua functions | ✅ n/a |
| **B3** | `ui_imgui.ImVec2One` / `ImVec2Zero` undefined | `ui/Builders.lua` :1316 | ❌ | → `ui_imgui.ImVec2(1,1)` / `ImVec2(0,0)`, cached as file-level locals | ✅ |
| **B4** | `core_environment.setTimeOfDay` silently ignores `dayScale`, `nightScale`, `azimuthOverride` (field allow-list at `core/environment.lua`:469-482) | `managers/EnvironmentManager.lua` `_tryApplySun` | 🔧 | Removed the 3 dead assignments. **`azimuthOverride` no longer exists anywhere in the engine** → real feature loss, see note below | ✅ |
| **B5** | `core_environment.get/setFogDensityOffset` are now deprecation stubs (`nil` / no-op) — `core/environment.lua`:1167-1174 | `managers/EnvironmentManager.lua` `_tryApplyWeather` | 🔧 | Dropped from the env sync | ✅ |
| **B6** | `core_environment.get/setCloudExposureByID` are now deprecation stubs — `core/environment.lua`:1038-1045 | `managers/EnvironmentManager.lua` `_tryApplyWeather` | 🔧 | Dropped from the cloud sync | ✅ |
| **B7** | `gameplay_traffic.onSettingsChanged` no longer exists | `managers/SettingsManager.lua` :21, :26 | ❌ | Dead `onChange` refs removed. 0.39 reads these settings on demand (`gameplay/traffic.lua`:771, `traffic/vehicle.lua`:565) ⇒ they apply from the next traffic activation | ✅ |
| **B8** | `gameplay_markerInteraction.isStateFreeroam` does not exist on that module in 0.39 | `managers/InteractiveMarkerManager.lua` :280, :283 | ❌ | Dead monkey-patch (write nobody reads) → removed with its now-unused local + rollback listener | ✅ |
| **B9** | `obj:unregisterObject()` unconfirmed — the 0.39 game never calls it anywhere | `managers/WorldObjectManager.lua` :58, `managers/InteractiveMarkerManager.lua` :152 | ❓ | **In-game smoke test.** If it errors: use `obj:delete()` (the pattern 0.39 itself uses in `gameplay/playmodeMarkers.lua`:35/44) | ☐ |
| **B10** | **BeamMP chat module moved** — `require("multiplayer.ui.chat")` at load time, but BeamMP 4.22.1 relocated it to `beammp/ui/chat.lua` (and turned the chat into an imgui window) | `managers/ChatManager.lua` :18 | ❌ | A failing top-level `require` **aborts the whole ChatManager**. Now resolved lazily and protected: tries the `beammp_ui_chat` global, falls back to `pcall(require, "beammp.ui.chat")` — the same module instance BeamMP renders from (`BeamMP/lua/ge/extensions/UI.lua`:14). `addMessage(username, message, id, color)` signature is **identical** | ✅ |

#### ⚠ Feature loss to accept (B4)

`sunAzimuthOverride` has **no replacement**: `azimuthOverride` returns 0 hits across the entire
0.39 game Lua. BeamNG replaced the manual override with a real astronomical sun model driven by
`latitude` / `longitude` / `year` / `month` / `day` / `utcOffset` / `celestialProfile` (all of
which *are* in the `setTimeOfDay` allow-list). The `Sun Azimuth Override` slider in
`ui/windows/Environment/Sun.lua` is therefore now **inert** — same for the `Fog Density Offset`
and `Cloud Exposure` sliders (B5/B6). They still sync server↔client, they just no longer affect
rendering. Phase 2 candidate: replace the azimuth slider with lat/long controls, and hide the
two dead ones.

Note: `dayScale` / `nightScale` are **not** lost — BeamJoy uses its own values to compute day and
night durations (`EnvironmentManager.lua`:399-401 client, `BeamJoyCore/managers/EnvironmentManager.lua`:355-357
server). Only the hardcoded `ToD.dayScale = 1` / `ToD.nightScale = 1` passthrough was dead.

#### B2 in detail — why it is NOT a breakage (corrected)

Initial analysis flagged this as the biggest port item, by checking only the **game's Lua**:
in 0.39 `core/recoveryPrompt.lua` has no `getUIData` at all, and `uiPopupButtonPressed` /
`uiPopupCancelPressed` are commented out of the export table (:982-983), renamed internally to
`buttonPressed` (:636) / `onPopupClosed` (:657).

**That conclusion was wrong**, because the consumer is not the game's Lua — it is the UI:

- `ui-vue/src/modules/recovery/views/Recovery.vue` calls `lua.core_recoveryPrompt.getUIData()`
  (:101), `lua.core_recoveryPrompt.uiPopupButtonPressed(index + 1)` (:85) and
  `lua.core_recoveryPrompt.uiPopupCancelPressed()` (:93).
- Those are resolved **at call time in the GE VM** (`bridge/libs/Lua.js`:130 → `runRaw`).
- BeamJoy assigns exactly those three names onto `extensions.core_recoveryPrompt`, and fires the
  `OpenRecoveryPrompt` guihook itself — which `gameContextStore.js`:106 still listens for.

⇒ **BeamJoy's prompt system should work as-is on 0.39.** BeamNG removing its own implementation
just means BeamJoy is now the only provider. **No rewrite. Verify in-game** (`☐` in §7).

Two things to watch during the in-game test: `Recovery.vue` reads `button.keepMenuOpen` and
`popupData.cancelButton.keepMenuOpen` (BeamJoy sets neither → falsy → popup closes on click,
which is the wanted behavior), and the icon names in `utils/IconsPrompt.lua` must still resolve
in the Vue component.

#### B2 in detail — the recovery prompt (biggest port item)

BeamJoy hijacks the game's recovery-prompt popup to render its own multiplayer prompts, by
monkey-patching three functions in `PromptManager.onLoad`:

```lua
extensions.core_recoveryPrompt.uiPopupCancelPressed = onCancel
extensions.core_recoveryPrompt.uiPopupButtonPressed = onButtonPressed
extensions.core_recoveryPrompt.getUIData           = getUIData
```

In 0.39 (`lua/ge/extensions/core/recoveryPrompt.lua`):
- **`getUIData` does not exist at all** (0 occurrences in the file). The popup-data contract is
  gone — data is now built internally by `createPopupData()` (:776) into a private `popupData`
  local, consumed by `core_quickAccess.addEntry` generators (:897-899). The recovery prompt now
  lives in the **radial / quick-access menu**, not a separate JS popup.
- `uiPopupButtonPressed` and `uiPopupCancelPressed` are **commented out of the export table**
  (:982-983). They were renamed internally to `buttonPressed` (:636) and `onPopupClosed`
  (:657), both of which *are* exported (:977-978).

⇒ **All three BeamJoy assignments are writes to fields the game never reads. Every BJI prompt is
silently dead on 0.39.**

Nuance worth keeping: the quick-access entry at `recoveryPrompt.lua:751` invokes
`core_recoveryPrompt.buttonPressed(id, target)` **through the module table**, so patching
`extensions.core_recoveryPrompt.buttonPressed` *would* still intercept presses. But there is no
longer any way to inject BJI's own prompt content, so hooking button presses alone is useless.

**Recommended clean port: build a self-owned BJI prompt** on the existing imgui infrastructure
(`WindowsManager` + `PopupManager` are already there) instead of hijacking a game internal.
That is both the cleanest option and the one that stops this from breaking every release.
Rejected alternative: injecting into `core_quickAccess` — matches the new game flow but keeps
BeamJoy coupled to another moving internal.

#### Confirmed by the API pass: pre-existing BeamJoy bugs (not 0.39 regressions)

- **P2 confirmed** — `VehicleManager.lua` :1781-1783 stores the original under key `startWork`
  but :1793 calls `M.baseFunctions.util_screenshotCreator.saveConfigBaseFunction(...)` — a key
  that is never assigned ⇒ `attempt to call a nil value` the moment a config save fires.
- **P3 confirmed** — same pattern at :1785 / :1800: stored as `removeLocal`, called as
  `removeConfigBaseFunction` ⇒ nil call when deleting a saved vehicle config.

Neither symbol has ever existed in BeamNG — these are BeamJoy-internal key mismatches.

### 5.4 High-risk areas flagged by the architecture pass (to verify in-game)

Ranked by likelihood of breaking, from the subsystem analysis:

**All the game modules BeamJoy patches still exist in 0.39** (verified):
`gameplay/markers/missionMarker`, `freeroam/bigMapPoiProvider`, `gameplay/rawPois`,
`gameplay/missions/missions`, `core/groundMarkers`, `core/recoveryPrompt`, `gameplay/traffic`,
`gameplay/police`, `gameplay/parking`, `core/multiSpawn`, `gameplay/walk`, `core/jobsystem`,
`ui/missionInfo`, `freeroam/bigMapMode`, `core/hotlapping`, `core/camera`, `core/modmanager`,
`core/vehicles`, `core/vehicle/manager.lua` (= `core_vehicle_manager`),
`core/vehicle/partmgmt.lua` (= `core_vehicle_partmgmt`), `ui/vehicleSelector/tiles.lua`
(= `ui_vehicleSelector_tiles`). What remains to check is *behavior*, not existence:

1. **Interactive markers** — `InteractiveMarkerManager` consumes private internals of
   `gameplay/markers/missionMarker` (table shape, `groundDecalData[1]/[2]`, `iconDataById`,
   `interactInPlayMode`) + `BeamNGWorldIconsRenderer` + `Engine.Render.DynamicDecalMgr.addDecals`.
   The module exists, but the missions/markers system is among the most-refactored areas of
   BeamNG — **data-shape** verification needed in-game. (See also B8, B9.)
2. **Bigmap** — `BigmapManager` wholesale-replaces
   `freeroam_bigMapPoiProvider.sendCurrentLevelMissionsToBigmap`,
   `gameplay_rawPois.getRawPoiListByLevel`, `gameplay_missions_missions.getMissionById` with
   hand-built payloads. Functions verified present; the **payload contract** is what can break
   the map screen + quick travel.
3. ~~**Input action names**~~ — ✅ **CLEARED.** Every action name BeamJoy uses
   (`recover_vehicle`, `recover_vehicle_alt`, `saveHome`, `loadHome`, `dropPlayerAtCamera`,
   `dropPlayerAtCameraNoReset`, `reset_physics`, `toggleWalkingMode`, `toggleBigMap`,
   `photoMode`, `funstuff`, `nodegrabber*`, `editorToggle`) exists in 0.39 and **none appears
   in `lua/ge/extensions/core/input/deprecatedActions.lua`** (81 deprecated names
   cross-checked against the whole client mod → 0 real hits). The filter API is also intact:
   `core_input_actionFilter.addAction` (:142) and `.setGroup` (:144) unchanged. Respawn
   strategies are safe.
4. **Traffic & pursuit** — `AIManager` + `PursuitManager` patch `gameplay_traffic` and poke
   traffic objects directly (`setRole`, `setAiMode`, `insertTraffic` arg semantics,
   `gameplay_police.setPursuitMode`, `gameplay_parking`).
5. **Environment** — `EnvironmentManager` writes raw `ScatterSky`/`CloudLayer`/`Precipitation`/
   `LevelInfo` fields and mixes deprecated `bullettime` with `extensions.simTimeAuthority`.
6. **Vehicle selector** — patches `core_vehicles` spawn/replace/remove +
   `ui_vehicleSelector_tiles.getTiles` + `jbeam/io.getAvailableParts`.
7. **Vehicle-VM string commands** — `controller.mainController.setEngineIgnition` /
   `shiftToGearIndex` / `getState`, `electrics.set_lightbar_signal`, `hydros.get/setFFBConfig`,
   `obj:setGhostEnabled`, `thrusters.applyVelocity`, recovery rewrites. **All fail silently.**
8. **Legacy Angular guihooks channels** — `ScenarioFlashMessage`, `HotlappingTimer`,
   `RaceLapChange`, `BigmapMissionData`, `toastrMsg`, `OpenRecoveryPrompt`… BeamMP itself moved
   to a Vue UI in 0.39, so stock UI-app payload contracts are a real risk.
9. **GPS / navigation** — patches `core_groundMarkers.setPath`, mutates `colorSets`, uses
   `gameplay_playmodeMarkers` / `freeroam_bigMapMode.setNavFocus`.
10. **Camera** — `core_camera.setByName`, `getGlobalCameras().free` magic-number smoothing
    detection, `setSmoothedCam`, per-player `setPosRot`.
11. **Icons atlas** — `Icons.lua` hardcodes ~1400 (with IconsPrompt ~2300) atlas ids; renamed
    ids give blank icons with no error.
12. **Vanilla vehicle configs** — `VehiclePresets.lua` hardcodes configs (e.g. pickup
    `d35_disappointment_A`) that may not exist in 0.39 → breaks derby vehicle spawning.
13. **Map/terrain data** — stored scenario positions were authored pre-0.39; terrain mesh
    changes can leave start positions and waypoints underground. The server never validates.

### 5.5 Pre-existing bugs found during the analysis (decide: fix or preserve)

These are **not** 0.39 regressions — they exist today in 2.0.8.

| ID | Bug | Note |
|---|---|---|
| P1 | `BeamJoyCore/rx/VoteRx.lua` defines `ctrl.KicVotek` (typo) while the client sends `KickVote` | **Vote-kick voting is broken at protocol level.** Load-bearing typo: "fixing" only one side breaks it further — fix both sides together. |
| P2 | `VehicleManager` screenshotCreator wrapper called `baseFunctions...saveConfigBaseFunction` while the original is stored as `startWork` | latent nil call on every vehicle-config save — **✅ fixed** |
| P3 | `VehicleManager` partmgmt wrapper called `baseFunctions...removeConfigBaseFunction` while the original is stored as `removeLocal` | latent nil call on every saved-config delete — **✅ fixed** |
| P3b | `VehicleManager.stopVehicle` uses a stale local `veh` | not fixed (needs behavior review) |
| P4 | `WorldObjectManager.createCylinderMarker` colors an undefined `obj` | |
| P5 | `AutomaticLightsManager` purges the wrong table for `nightSwitched` | |
| P6 | `StationsManager.setGPS` reads a `ctxt` local that is nil before the first renderTick | |
| P7 | `PromptManager` replaces `core_recoveryPrompt` functions but never restores them on unload (unlike others using `RollBackNGFunctionsWrappers`) | can leave the base recovery prompt broken after unload |
| P8 | `TagDuoManager.stop` is never called by `stopServerScenarii` (only `CurrentScenario.forceStop`) | tag lobbies survive into exclusive scenarios |
| P9 | `TournamentManager.endTournament` calls `MP.Sleep(200)` per ranked player on the main server thread | blocks the BeamMP tick with large player lists |
| P10 | `ScenarioRaceSolo.tryReset` references `lastLaunchedCheckpoint`, never populated | dead-but-reachable branch, nil-guarded |

---

## 6. Work log

| Date | Action | Result |
|---|---|---|
| 2026-08-05 | Environment audit (game version, profile, test server, repos) | 0.39.2.1 confirmed; server side OK; client BJI to port |
| 2026-08-05 | Launched multi-agent comprehension workflow (`beamjoy-039-comprehension`) | 8 subsystem maps + API inventory (425 symbols) delivered; 3 verification agents failed (out of credits) → relaunched separately |
| 2026-08-05 | Created this tracking file | — |
| 2026-08-05 | Architecture map written (§4) | 8 subsystems documented |
| 2026-08-05 | BeamMP API verification | **11/11 APIs OK** in BeamMP 4.22.1; **1 breakage**: `trackNewVeh` hook renamed |
| 2026-08-05 | Spot-check of the highest-risk game modules | editor GUI API, race_marker, imguiUtils + all legacy imgui variants **present in 0.39** |
| 2026-08-05 | Input action names cross-checked vs `deprecatedActions.lua` | **0 hits** — respawn/restriction plumbing safe |
| 2026-08-05 | Exhaustive API verification (9 agents, 425 symbols) | **410 ok / 5 removed / 7 changed / 3 unsure** → 9 concrete port items (B1–B9) |
| 2026-08-05 | Deployed client vs repo | `L:\...\Client\BJI.zip` dated **2025-12-11** = stale (repo is ahead); server `BeamJoyCore` = repo 2.0.8 ✓ |
| 2026-08-05 | UI framework investigation (Angular → Vue) | BeamJoy UI is **imgui**, unaffected. All guihooks touchpoints still wired; **B2 downgraded from rewrite to no-op**; **B10 found** (BeamMP chat module moved) |
| 2026-08-05 | Port applied: B1, B3, B4, B5, B6, B7, B8, B10 + P2, P3 | 7 files changed, +70/−40 |
| 2026-08-05 | Test server rebuilt by user | BeamMP Server **v3.9.3**, clean `Resources/`; old setup archived in `L:\Server\BeamMP\0.38\` (20 GB, incl. intact `Server/BeamJoyData/db`, 3.3 MB) |
| 2026-08-06 | V3.0.0 released (commit 0663458, tag v3.0.0, pushed to GitHub) | 22 files, adversarially reviewed |
| 2026-08-06 | BeamJoy-sandbox mapped (8-agent workflow: 6 subsystems + 47-row feature matrix + 13-check 0.39 audit) | §12-§13 |
| 2026-08-05 | Deployed ported build to test server | `BeamJoyCore` + `BeamJoyChatHandler` → `Resources/Server/`, `BJI.zip` (885 KB) → `Resources/Client/`. **Fresh database chosen** (user decision) |

---

## 7. Porting roadmap & status

### Phase 1 — Make it run on 0.39 (current)

| # | Step | Status |
|---|---|---|
| 1 | Full architecture comprehension (multi-agent map) | ✅ done — §4 |
| 2 | Tracking file at Git root | ✅ created (this file) |
| 3 | 0.39 breakage identification (425-symbol cross-reference) | ✅ done — §5, 9 items B1–B9 |
| 4 | Clean port, function by function (English comments) | ✅ **done** — B1, B3, B4, B5, B6, B7, B8, B10 + P2, P3 (B2 = no change needed, B9 = smoke test) |
| 5 | Package double ZIP + deploy to `L:\Server\BeamMP` | ✅ deployed — **server restart required** |
| 6 | In-game validation, feature by feature | ⏳ **next** — checklist below |

### Current test-server state

- BeamMP Server **v3.9.3**, clean install. Server `Delta`, map `gridmap_v2` (vanilla), 6 slots.
- `Resources/Server/`: `BeamJoyCore` + `BeamJoyChatHandler` (ported build deployed).
- `Resources/Client/`: `BJI.zip` (885 KB, ported build).
- **No `BeamJoyData` yet** — a fresh default database will be generated on first load.
- Old production setup preserved untouched in `L:\Server\BeamMP\0.38\` (maps + full old DB).

**Next actions:**
1. **Restart the BeamMP server** (it runs on the other PC — `BeamMPLoop.bat`). The PluginMonitor
   does not hot-load brand-new plugin folders, and `onInit` only runs at startup.
2. Expect in the log: `Loading BeamJoyCore v2.0.8 ...` then `BeamJoyCore v2.0.8 loaded !`
3. In the server console: `bj setgroup <your_playername> owner` (fresh DB ⇒ no owner yet).
4. Join with the 0.39 client and walk the checklist below, watching
   `C:\Users\compt\AppData\Local\BeamNG\BeamNG.drive\current\beamng.log` for `BJI` errors.

### Feature validation checklist (to tick one by one on 0.39)

Priority items (directly touched by the port, or flagged as unverified):
- [ ] **Chat** — B10 fix: messages must appear in BeamMP's new **imgui** chat window
- [ ] **Prompts** — B2: scenario prompts (race launch options, respawn strategy…) must open and
      react to clicks; check the `IconsPrompt` icons render in the new Vue popup
- [ ] **Interactive markers** — B8/B9: markers appear, are interactable, and clean up on map
      change without a `unregisterObject` error
- [ ] **Vehicle selector** — B1: spawn / replace / clone / delete others still work
- [ ] **Environment** — B4/B5/B6: sun, weather and clouds still sync (azimuth override, fog
      density offset and cloud exposure sliders are now inert **by design**)
- [ ] **Vehicle config save/delete** — P2/P3: must no longer throw a nil call
- [ ] Race UI apps (RaceTime / Hotlapping / checkpoint comparison) still receive data

Full feature sweep:
- [ ] Mod loads on join (no softlock, extension loads, caches sync)
- [ ] UI windows render (imgui layer) — Main window, theme, all ~35 windows
- [ ] Chat (messages, commands, join/leave events)
- [ ] Permissions / groups / staff tools
- [ ] Vehicle spawn/delete/reset + vehicle selector UI
- [ ] Nametags rework
- [ ] Environment sync (sun, weather, gravity, sim speed, temperature)
- [ ] Map switcher + votes
- [ ] Reputation system
- [ ] Freeroam (respawn delays, ghost mode, quick travel)
- [ ] Gas stations / garages + world markers + GPS
- [ ] Races (solo + multi, editor, leaderboards, pit stands)
- [ ] Hunter / CarHunt
- [ ] Deliveries (vehicle, package, together)
- [ ] Bus missions (+ UI apps)
- [ ] Speed game
- [ ] Destruction Derby
- [ ] Tag Duo
- [ ] Infected
- [ ] Tournament mode
- [ ] Moderation (mute/kick/ban/freeze/engine/teleport)
- [ ] Broadcasts / welcome messages / i18n
- [ ] Theme editor
- [ ] Automatic headlights, smooth free cam, drift rewards, emergency refuel

### Known pre-existing issues (0.38 era, keep in mind)

- Leaving a BeamJoy server then joining freeroam/non-BeamJoy server softlocks the loading
  screen (module dependency issue — README "Known issues"). Watch whether 0.39 changes this.
- Windows UI system costs performance (imgui redraw) — candidate for Phase 2.

---

## 8. Deployment procedure (test loop)

1. Build/refresh server side: copy `BeamJoyCore/`, `BeamJoyChatHandler/` → `L:\Server\BeamMP\Resources\Server\`
2. Build client ZIP: zip the **contents** of `BeamJoyInterface/` → `BJI.zip` → `L:\Server\BeamMP\Resources\Client\BJI.zip`
3. Restart the BeamMP server (`BeamMPLoop.bat` on the server PC keeps it alive)
4. Join with the 0.39 game client; check `C:\Users\compt\AppData\Local\BeamNG\BeamNG.drive\current\beamng.log` for `BJI`/`BeamJoy` errors
5. Tick the feature checklist (§7) as features are validated in-game

Note: `L:\Server\BeamMP\Resources\Server\OLDFreeBJ\` holds an old copy — ignore, do not touch.

---

## 9. Conventions for this port

- **Comments in English**, everywhere, always.
- Clean-port rule: adapt to the new API surface **without changing behavior**; refactors and
  improvements go to Phase 2 (log candidates in §10 instead).
- One feature = one validated unit: port → deploy → test in-game → tick checklist → commit.
- Never commit secrets (server `AuthKey` in `ServerConfig.toml`).
- Keep the double-ZIP structure and the existing rx/tx protocol intact in Phase 1.

## 10. V3.0.0 — stabilization & optimization pass (2026-08-05)

Decision: **stay on imgui** (matches BeamMP's own 0.39 split: Vue for out-of-session screens,
imgui for all in-session UI — they even moved their chat *from* HTML *to* imgui). The perf
work targets what actually cost: per-frame allocation churn in the builder layer.

### 10.1 UI optimization (game-code idioms)

The game's own code validated the approach: `editor/api/gui.lua` uses a module-level
`tempVec2A` scratch vector and copies incoming vectors immediately — the exact pattern
adopted. Changes, all centralized in `Builders.lua` / `CommonStyle.lua` / `WindowsManager.lua`
(so all 82 window files benefit without being touched):

| Change | Before (per widget per frame) | After |
|---|---|---|
| Style presets | `Table(preset):map(→ new ImVec4)` ×4-7 + closure | pushed **by reference** (LoadTheme normalizes optional slots once; imgui copies at push) |
| Widget ids | `"##"..id` / `string.var("{1}##{2}")` string concat | memoized (`HiddenId`/`LabeledId`, 4096-entry safety cap) |
| In/out pointers | fresh `IntPtr/FloatPtr/ArrayFloat(4)/BoolPtr` cdata | module-level scratch cdata, reused (imgui reads/writes during the call only) |
| Size vectors | fresh `ImVec2` per call | 2 scratch vectors, mutated in place |
| `data or {}` defaults | fresh empty table per call + caller-table mutation | shared read-only `EMPTY` + locals; **builders no longer mutate caller tables** |
| UI scale | `BJI_LocalStorage.get` per widget | read **once per window** (`uiScale` upvalue) |
| Window titles | `BJI_Lang.get(string.var(...))` per window per frame | cached, invalidated on `LANG_CHANGED` |
| `SetStyleColor` validation | linear scan of ~40 enum entries per push | O(1) reverse lookup set |
| `ResetStyles` | `table.length()` per frame | count cached at LoadTheme |
| `Image` tint/border | 2× `ImColorByRGB(...)` per call | constants built once |
| Slider format strings | `"%.Nf"` concat per frame | memoized per precision |
| `InputTextMultiline` line count | `value:split2("\n")` table+strings | `string.find` counting loop, zero alloc |
| Flags | `Table():clone():addAll()` chains | `bit.bor` accumulation on locals |

Measurable with the built-in `Bench.lua` (GC tracking per window) before/after.

### 10.2 Stabilization fixes shipped in V3.0

| ID | Fix |
|---|---|
| P1 | `VoteRx.KicVotek` → `KickVote` (server now matches the client endpoint — **vote-kick works again**) |
| P3b | `VehicleManager.stopVehicle` stale `veh` upvalue → uses `mpVeh.veh` |
| P4 | `WorldObjectManager.createCylinderMarker` colored undefined `obj` → colors `marker` |
| P5 | `AutomaticLightsManager` purged `morningSwitched` in the `nightSwitched` loop → purges the right table |
| P6 | `StationsManager.setGPS` nil `ctxt` before first renderTick → guarded |
| P7 | `PromptManager` now saves/restores the `core_recoveryPrompt` hooks on unload |
| P8 | `stopServerScenarii` now also stops hybrid scenarios (TagDuo lobbies, DeliveryMulti) as TagDuo's own doc intended |
| P9 | Tournament results: blocking `MP.Sleep(200)`/player → `BJCAsync` batched scheduling (~5 msg/s, server tick never blocked) |

Not fixed on purpose: P10 (dead nil-guarded branch in `ScenarioRaceSolo.tryReset`) — harmless,
left for the scenario-logic Phase 2 pass.

### 10.3 Adversarial review (multi-agent, 2 rounds)

Every change was reviewed by 4 independent lenses (scratch/aliasing, behavior preservation,
Lua/FFI semantics, integration/runtime), each finding then adversarially verified by a
dedicated refuter agent. 8 findings confirmed, all fixed:

| Finding | Fix |
|---|---|
| `EMPTY` sentinel aliased into persistent window descriptors via `data.flags` | resolved on a local (`dataFlags`) |
| `LabeledId` counter counted rebuilds → periodic full cache wipes with dynamic labels | counts new keys only; in-place rebuild |
| Malformed server theme (missing preset slots) → style-stack underflow | `LoadTheme` backfills **all** indexed slots |
| Dead **Sun Azimuth Override** slider still interactive (silent lie to admins) | removed from `Sun.lua` (moonAzimuth kept — applied via ScatterSky, still works) |
| Dead **Fog Density Offset** / **Cloud Exposure(/One)** sliders still interactive | removed from `Weather.lua` |
| Tournament async task keys collide across runs | keys now carry a per-run time discriminator |
| `beammp_ui_chat` bare-global fast path unreachable (BeamMP registers no such global) | dropped; `require("beammp.ui.chat")` only |
| `uiScale` one-frame lag on same-frame scale change | **accepted** — self-corrects next frame, zero visual impact |

Self-verified separately: window-title cache is safe (`LANG_CHANGED` fires on the initial
lang cache load too, and rendering only starts after base caches load); scratch-vector reuse
matches the game's own idiom (`editor/api/gui.lua` `tempVec2A` copies incoming vectors
immediately).

### 10.4 Version bump

`BJI.VERSION` and `BJCVERSION`: **2.0.8 → 3.0.0**. `dist/` gitignored.

## 12. BeamJoy-sandbox — architecture map (2026-08-06)

> The official remake by the original author. **This is the merge target**: keep its new
> interface and architecture, bring classic BeamJoy's features onto it.
> v1.0.4 · 101 Lua files (vs 241 classic) · sandbox scope only (no scenarios).
> Structure: `BeamJoyClient` / `BeamJoyServer` / `BeamJoyServerHooks` (+ `assets`).

### 12.1 Client — module system (the big structural shift)

- **1 file = 1 real BeamNG extension.** No directory scanning, no manager registry, no `BJI`
  namespace table. `modScript.lua` loads `beamjoy_main` → `lua/ge/extensions/beamjoy/main.lua`,
  whose `M.dependencies` array **declares** every module (`beamjoy_cache`, `beamjoy_vehicles`,
  `beamjoy_communications_ui`, …). BeamNG's own extension manager resolves order and exposes
  each as a global (`beamjoy_context`, `beamjoy_vehicles`…). Path convention:
  `beamjoy/communications/ui.lua` → `beamjoy_communications_ui`.
- **Custom events ride `extensions.hook`** — no bespoke pub/sub: `onBJClientReady` (world
  ready + fps>5), `onSlowUpdate` (~250 ms from onPreRender), `onServerTick`. A module opts in
  by defining the same-named method. (Classic's BJI_Events bus disappears.)
- **Context**: `beamjoy_context.get()` = throttled memoized accessor (100 ms buckets) building
  `{now, camera, self, players, mpVeh}` — the classic `TickContext` equivalent.
- **Cache sync is decentralized**: the server pushes one batched `sendCache` event; each domain
  module registers its own handler and picks its slice (`caches.config`, `caches.langs`…).
  Deltas ride separate named events (`updatePlayer`, `updateDBPlayer`…). Push-on-change —
  **no hash-driven pull** like classic's 26-cache system.
- Shared helpers live in flat `lua/` (`NG.lua`, `mp.lua`, `imgui_builders.lua`, `bjColor`,
  Log*/UUID/Table patches) pulled by `loadDefaults.lua` (first dependency).

### 12.2 Client ↔ server protocol

Nearly identical in mechanics to classic, renamed: 2 wire events **`BJ_Event`**
(`{id, key, parts}`) + **`BJ_DataEvent`** (`{id, part, data}`), same 20 000-char chunking,
same JSON + numeric-string-key normalization, same 30 s reassembly timeout, same
`TriggerServerEvent`/`AddEventHandler` transport. Addressing is **key-based** with a
multi-handler registry (`addHandler`/`addOneUseHandler` + auto-expiry) instead of classic's
controller.endpoint dispatch. **The protocols are conceptually reconcilable; classic features
re-implement naturally on the sandbox's key-based dispatch.**

### 12.3 Client — HTML/Angular UI (the headline)

- **Load path is official & alive in 0.39**: the game's `ui/entrypoints/main/angularModules.js`
  auto-imports `/ui/modModules/<name>/<name>.js` and adds them to `BeamNG.ui` requires
  **before** `angular.bootstrap` — Angular is now *hosted inside Vue* but fully operational,
  with per-module error isolation. Verified against 0.39.2.1.
- `beamjoy.js` declares its own AngularJS 1.x module, serially `await import()`s directives →
  store → component library → windows (load order *is* the module system, no bundler), then
  bootstraps a **separate Angular root** (`<beamjoy>` prepended to body) alongside the game's.
- **State**: single `beamjoyStore` service; sub-namespaces are ES modules mutated directly;
  inbound Lua events arrive via `guihooks.trigger("BJEvent", {event, payload})` →
  `$rootScope.$on` → store method named after the event + re-broadcast. Outbound:
  `beamjoyStore.send()` → `bngApi.engineLua('beamjoy_communications_ui.dispatch(...)')`.
- **Window system is a clever hybrid**: `bj-window` is pure Angular chrome; **placement,
  resize, drag and persistence are delegated to BeamNG's native `ui_apps` widget grid** via 3
  phantom apps (`ui/modules/apps/BeamJoy-Main|HUD|Config`, empty Angular directives). Lua reads
  `ui_apps.getAvailableLayouts()` and pushes CSS `calc()` positions to JS
  (`BJSendAppsSizesAndPositions`). → BeamNG's own layout save/load does the persistence.
- A small **imgui layer remains client-side** (`beamjoy/imgui/`: manager, menu (F4 top bar),
  style, icon, debug) — verified OK against the 0.39 binding.

### 12.4 Server

From-scratch rewrite keeping the author's idioms: `BeamJoyServer.lua` `onInit` → version/build
check (BeamMP ≥ 3.9.0), write-permission probe, `loadExtensions()` walking a flat dependency
list (utils → dao → services → communications) into `_G[name]`; synthetic
`extensions.hook`/`hookWithReturn` (pcall-isolated; WithReturn stops at first non-nil — used
for auth/spawn gating); `onPreInit` then `onInit` lifecycle; native BeamMP hooks + custom
`onBJSChatMessage`/`onBJSConsoleInput` + timers `BJSUpdate` (100 ms) / `BJSSlowUpdate` (1 s).
**`BeamJoyServerHooks`** = same BeamMP issue #435 chat/console workaround as classic's
ChatHandler. **DAO** is near line-for-line classic (`BeamJoyData/db`, atomic `.tmp`+rename,
same layout; `players/<name>.json`, `activities/<map>_<type>.json`), plus a `dao_core`
dual-write into `ServerConfig.toml` via a bundled TOML codec.

### 12.5 Sandbox 0.39/BeamMP-4.22.1 compat audit (13 checks)

The sandbox predates 0.39. Verified against the installed game + BeamMP source:

| Status | Item |
|---|---|
| ✅ | Angular layer + `modModules` pipeline fully intact in 0.39 (the big one) |
| ✅ | Own imgui usage (`beamjoy/imgui/*`), `ui_topBar` concern, MPVehicleGE stubs, `trackNewVeh` (not used), traffic/markerInteraction/recoveryPrompt APIs (not used — thinner Lua layer) |
| ❌ | `imgui_builders.lua` :1229-1237 `Image()` uses `ui_imgui.ImVec2Zero/One` **unguarded** → same fix as classic B3 |
| ❌ | `chat.lua` :14 `require("multiplayer.ui.chat")` **unprotected, per message** → module moved to `beammp/ui/chat` → same fix as classic B10; **JS side too**: `override/chat.js` targets `#chat-list`/`addMessage` of the old Angular chat that BeamMP replaced with imgui |
| ❌ | Loading-screen DOM hack (`beamjoy.js` :1-12, `document.body.children[2]` + literal `"Loading UI..."`) — the 0.39 Vue boot has neither → rewrite against the new boot contract or drop |
| ❌ | **Phantom-app layout re-fetch triggers** — the 8 `$rootScope` events the window system listens to for app-container layout changes have shifted in the 0.39 Vue shell → needs a design decision (bridge a new signal, or poll `ui_apps` layouts from Lua) |
| ⚠ | `dayScale`/`nightScale` passthrough to `setTimeOfDay` silently ignored (same engine allow-list as classic B4) → reimplement day/night speed client-side or drop |

## 13. The merge — classic features onto the sandbox architecture

47-row feature matrix built (full data in the workflow output; key conclusions):

**Keep sandbox as-is (already at or above classic parity)** — map switch+labels, moderation,
whitelist, traffic (server-distributed = deliberate upgrade), pursuit, nametags (superset),
chat architecture, broadcasts, welcome/intro, vehicle selector (bugfix pass), local storage,
safe zones / replay / advanced mods handling / context menu / HUD / database UI / core config
UI (all net-new), cache protocol, DAO architecture.

**Port (scenario-independent, good first wins)** — reputation/XP, drift rewards, vote
kick/map pipeline, chat commands catalog, i18n gap-filling (it/tr), DAO field-typing
hardening, permission-catalog expansion.

**Port (needs shared building blocks first)** — world markers + bigmap + GPS (**the real
infrastructure gap**), then gas stations/garages on top; general collisions manager
(FORCED/DISABLED/GHOSTS as a superset of safe-zone ghosting); respawn strategies hybrid.

**The huge one — scenario/activity framework (rewrite)**: classic's single-active-scenario
FSM (exclusive/hybrid/solo semantics) must be redesigned sandbox-idiomatically (a
`services_scenario` dispatcher server-side + an Angular activity-state service + HUD/window
routing client-side). **Every scenario port depends on it**: races solo/multi (+ editor =
from-scratch Angular waypoint/gizmo UI, `huge`), hunter, infected, derby, speed, tag duo,
deliveries ×3, bus missions, then tournament as a scoring overlay, votes-scenario last.

**Theme editor**: drop/rewrite as CSS — the HTML UI is natively themeable.

### 13.1 Data migration (classic BeamJoyData → sandbox)

Same flat-JSON DAO + atomic writes on both sides ⇒ **a one-time migration script is
realistic**, not a drop-in copy: `groups.json` classic = name-keyed map with sparse numeric
levels (0/2/5/7/100) vs sandbox = **ordered array where position = level** (+ new
`nameColor`/`textColor`) → flatten order-preserving + backfill colors;
`players/<name>.json`: classic `reputation`/`stats` have **no sandbox counterpart yet** →
carry them through the migrator anyway (the reputation port will need them); permission
catalog needs remapping.

### 13.2 Recommended phasing

| Phase | Content | Size |
|---|---|---|
| **0** | Sandbox 0.39 port (§12.5 fixes — reuse classic's B3/B10 solutions) + data migration script | small |
| **1** | Quick wins: reputation/XP, drift rewards, votes kick/map, chat commands, i18n, hardening | small-medium |
| **2** | Shared building blocks: markers/GPS/bigmap layer → stations/garages, collisions manager | large |
| **3** | **Scenario/activity framework** (server dispatcher + Angular activity UI) — own design review before coding | huge |
| **4** | Scenarios one by one on top: speed → tag duo → races (+editor) → hunter/infected → derby → deliveries → bus → tournament + votes-scenario | large × N |

Open strategic question for the user: which repo hosts the merge (fork of sandbox? new repo?),
and whether classic V3.0 keeps receiving fixes during the merge (recommended: yes, it is the
only version players can run until merge Phase 4 delivers scenarios).

## 15. V4 — the merge (branch `v4`)

> **Goal (user, 2026-08-06): best of both worlds, all features, one all-in-one mod, with a
> simple way to add scenarios / event types.** Base = sandbox architecture; classic features
> ported on top. Classic V3.0 stays maintained on `main`.

### 15.1 Done

| Date | Step |
|---|---|
| 2026-08-06 | `v4` branch created; sandbox v1.0.4 imported as base (GPLv3, same author) |
| 2026-08-06 | **Phase 0 — 0.39/BeamMP 4.22.1 port of the base**: imgui `Image()` constants; chat Lua adapter → `beammp_ui_chat.addMessage` with caret color quantization; chat JS override reduced to a history service (old HTML chat globals gone); loading-screen rebrand on `.ui-boot-title`; `onBeamMPServerLeave` aliases ×5 (**found beyond the audit**: the sandbox used the renamed `onServerLeave` hook everywhere); `onLayoutsChanged` hook dead in 0.39 → throttled layout-signature poll; day/night asymmetric speed re-implemented via per-phase `dayLength` (engine dropped `dayScale`/`nightScale`) |
| 2026-08-06 | **Data migration tool** `tools/migrate_classic_data.py` — groups (sparse levels → ordered array, `none`→`default`, chat colors backfilled) + players (`beammp`→`beammpID`, reputation/stats preserved under `data.classic`). **Tested on the archived production db: 7 groups + 77 players migrated cleanly.** |

### 15.2 Next: the activity framework (design direction)

The extensibility requirement translates to: **adding a scenario = dropping in one server
file + one client file (+ optional Angular window), zero core edits.**

- **Server** — `services/activities.lua` dispatcher: registers activity modules by
  declaration (each exposes `type` = `exclusive|hybrid|solo`, `minPlayers`, lifecycle
  `canStart/onStart/onPlayerJoin/onPlayerReady/onEvent/onPlayerLeave/onStop`, and a
  serializable `state`). The dispatcher owns the exclusive-slot rule, participant tracking,
  disconnect cleanup, vote integration, and pushes state via the existing `sendCache` /
  named-events protocol under an `activities` cache key.
- **Client** — `beamjoy/activity/` (folder already exists in the sandbox with its manager):
  extend it into the mirror registry: modules declare game-facing policy (`canReset`,
  respawn strategy, restrictions, collisions mode, nametag rules — the classic scenario
  contract) + `onServerState(state)`; the manager enforces the single-active rule and
  routes `onSlowUpdate`/vehicle hooks.
- **UI** — one generic `activity` Angular window driven by a descriptor (title, phases,
  countdown, participant list, action buttons) + optional per-activity components; HUD slots
  in BeamJoy-HUD for timers/counters.
- **Proof**: port **Speed** first (simplest exclusive scenario), then walk §13.2 Phase 4
  order. Scenario data migration ships with the framework.

## 16. Phase 2 candidates (parking lot)

*(collect improvement ideas here — do not implement them in the stabilization phase)*

- Fix the freeroam-after-BeamJoy softlock (module dependency) — needs mod remake per README.
- Dirty-flag / throttled rendering for non-interactive windows (data-change driven via the
  cache-hash system) — next perf step after the allocation pass.
- Replace the now-inert Sun Azimuth Override slider with latitude/longitude controls
  (0.39 astronomical sun model); hide the dead Fog Density Offset / Cloud Exposure sliders.
- Optional hybrid UI: move heavy rarely-open screens (Database, Server config, Theme editor)
  to Vue while keeping the in-session HUD imgui.
