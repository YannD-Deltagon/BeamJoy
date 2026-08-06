# Adding an activity (game mode) to BeamJoy V4

An activity is any joinable game mode: speed game, race, hunter, derby, tag...
Adding one requires **two files and zero core edits**:

```
BeamJoyServer/services/activities/<key>.lua      -- server: rules, phases, win condition
BeamJoyClient/lua/ge/extensions/beamjoy/activity/activities/<key>.lua  -- client: gameplay + policy
```

Both are auto-discovered at boot. The generic Angular activity window renders your lobby,
participants, countdowns and detail rows automatically — custom UI is optional.

The Speed game (`speed.lua` on both sides, ~150 lines total) is the reference
implementation; read it alongside this guide.

## Concepts

- **Types**: `exclusive` (one at a time server-wide — races, speed...) or `hybrid`
  (always-on joinable lobby coexisting with freeroam — tag duo, delivery together...).
- **Handle** (server): the dispatcher gives every callback a `handle` owning
  `participants` (playerName → your public per-player table; the framework manages the
  `ready` flag), `state` (your public state, broadcast to every client), `phase`, and the
  methods `setPhase(phase)`, `sendState()`, `stop(reason)`, `countParticipants()`.
- **State flow**: mutate `handle.state` / `handle.participants`, then call
  `handle.sendState()` (or `setPhase`, which broadcasts too). Every client receives the
  update in its `activityState` cache slice; your client module gets `onStateUpdate`.
- **Gameplay events**: clients call `beamjoy_activity_framework.sendEvent("myEvent", ...)`;
  the server module receives them in `onClientEvent(handle, player, "myEvent", ...)`.
  Only participants can send them.

## Server module contract

```lua
local M = {
    KEY = "mygame",          -- unique, used on the wire
    TYPE = "exclusive",      -- or "hybrid"
    MIN_PLAYERS = 2,
}

-- all callbacks are optional:
function M.canStart(ctxt, settings) return true end -- false, "lang.key" to deny with a toast
function M.onStart(handle, settings) handle.setPhase("lobby") end
function M.onPlayerJoin(handle, player) end         -- return false to deny the join
function M.onPlayerReady(handle, player) end
function M.onClientEvent(handle, player, eventName, ...) end
function M.onPlayerLeave(handle, player, disconnected, entry) end -- entry = their participant record
function M.onSlowTick(handle) end                   -- every 1s while the activity exists
function M.onStop(handle, reason) end               -- "ended"|"cancelled"|"starved"|"forced"

return M
```

The dispatcher already handles for you: the StartActivity permission, the exclusive slot,
join/leave/ready plumbing, `player.activity` bookkeeping, disconnect cleanup, map-change
cancellation, and state broadcasting.

Two extra handle facilities:
- `handle.freezeParticipants()` — call when results become final (winner declared): players
  leaving or disconnecting afterwards stay in the broadcast roster so the results screen
  stays coherent.
- On the wire, `participants` is converted to an ARRAY of `{name = ..., ...fields}` records
  (never a name-keyed map — numeric display names would be mangled by the JSON layer). Your
  server module keeps indexing `handle.participants[playerName]`; your client module and UI
  read the array.

## Client module contract

```lua
local M = {
    KEY = "mygame",          -- must match the server KEY
    LABEL = "My Game",       -- window title
}

-- all callbacks are optional:
function M.getRestrictions(entry) return { "recover_vehicle" } end -- blocked input actions
function M.onJoin(entry) end                    -- local player entered the participants
function M.onStateUpdate(entry) end             -- any broadcast state change
function M.onLeave(reason) end                  -- left or activity stopped: CLEAN UP here
function M.onSlowUpdate(ctxt, entry) end        -- ~250ms while participating (ctxt.mpVeh...)
function M.getUIDetails(entry)                  -- extra rows in the activity window
    return { { label = "Score", value = "42" } }
end

return M
```

`entry` is the public activity entry: `{key, type, phase, settings, participants, state}`
(`participants` = array of `{name, ready, ...}` records). Restrictions are re-evaluated on
join/leave AND on every broadcast state change (they ride the existing
`beamjoy_restrictions` input-filter system), so phase-dependent restriction lists work.

i18n: `LABEL` and detail labels can be locale keys (the activity window pipes labels through
the translate filter); HUD strings should go through `beamjoy_lang.translate(key, fallback)`.
Add your keys to `BeamJoyClient/beamjoy_locales/*.json`.

## Starting an activity

- Staff/permission holders: `beamjoy_activity_framework.startActivity("mygame", settings)`
  (wired to menus/commands later; votes integration comes with the votes port).
- Players join/ready/leave through the generic activity window buttons — no code needed.

## Checklist for a new activity

1. Write the server module; make every phase transition explicit via `setPhase`.
2. Write the client module; put ALL cleanup in `onLeave` (it runs on stop, disconnect
   and switches).
3. If the generic window is not enough, add a component in
   `ui/modModules/beamjoy/windows/activity/` and branch on `$ctrl.data.key`.
4. Per-map data (start positions, waypoints...) goes through `services_activityConfig` /
   `dao_activity` (`activities/<map>_<type>.json`) like safe zones do.
