// F1-style live standings board - a read-only view of the SAME descriptor the generic
// activity window already listens to (beamjoy/activity/framework.lua pushUIState pushes
// "BJActivityState" to every client: participants, self flags, canStop, free-form details,
// and the running activity's own "state" object - the *state* field is broadcast verbatim,
// unfiltered, unlike "participants" which is whitelisted to {name, ready, eliminated,
// position} server-side). Visible to spectators and participants alike for the same reason
// the activity window already is: framework.lua falls back to the running exclusive
// activity for anyone not personally in it (see its pushUIState comment), so `visible` is
// already the shared toggle - no extra wiring needed here.
//
// Richer per-participant statuses (who's "it", who's infected, lap counts) and gaps aren't a
// fixed field on the wire - framework.lua only forwards ready/eliminated/position per
// participant. Until that whitelist grows, this board reads them from the free-form `state`
// object by convention: state.it (player name), state.infected (array or name-keyed map),
// state.laps (name -> lap number), state.finishTimes / state.times (name -> seconds).
// Activities that don't publish these (Speed, today) simply fall back to phase-based status.
angular.module("beamjoy").component("bjStandings", {
    templateUrl: "/ui/modModules/beamjoy/windows/standings/app.html",
    controller: function ($rootScope, $scope) {
        this.data = { visible: false };
        this.rows = [];

        const STATUS = {
            eliminated: "beamjoy.standings.status.eliminated",
            ready: "beamjoy.standings.status.ready",
            waiting: "beamjoy.standings.status.waiting",
            racing: "beamjoy.standings.status.racing",
            winner: "beamjoy.standings.status.winner",
            finished: "beamjoy.standings.status.finished",
            it: "beamjoy.standings.status.it",
            infected: "beamjoy.standings.status.infected",
        };

        // returns {key} for a translatable status, or {text} for an untranslated one (e.g.
        // "Lap 3" - the lap number isn't known ahead of time so it isn't a locale key)
        const deriveStatus = (p, phase, state) => {
            if (p.eliminated) return { key: STATUS.eliminated };
            if (state) {
                if (state.it && state.it === p.name) return { key: STATUS.it };
                const infected = state.infected;
                const isInfected = Array.isArray(infected)
                    ? infected.includes(p.name)
                    : !!(infected && infected[p.name]);
                if (isInfected) return { key: STATUS.infected };
                if (state.laps && state.laps[p.name] != null) {
                    return { text: "Lap " + state.laps[p.name] };
                }
            }
            if (phase === "lobby") return { key: p.ready ? STATUS.ready : STATUS.waiting };
            if (phase === "ended") return { key: p.position === 1 ? STATUS.winner : STATUS.finished };
            if (phase === "running" || phase === "countdown") return { key: STATUS.racing };
            return { text: phase || "-" };
        };

        const deriveGap = (p, state) => {
            const times = state && (state.finishTimes || state.times);
            const t = times && times[p.name];
            return typeof t === "number" ? t.toFixed(2) + "s" : "-";
        };

        const rebuild = () => {
            // empty Lua tables serialize as {} - coerce before Array methods
            const raw = this.data.participants || [];
            const participants = Array.isArray(raw) ? raw : Object.values(raw);
            const phase = this.data.phase;
            const state = this.data.state;
            this.rows = participants.map((p, i) => {
                const status = deriveStatus(p, phase, state);
                return {
                    name: p.name,
                    position: p.position || i + 1,
                    statusKey: status.key || null,
                    statusText: status.text || null,
                    gap: deriveGap(p, state),
                    eliminated: p.eliminated === true,
                };
            });
        };

        $rootScope.$on("BJActivityState", (_, state) => {
            this.data = state || { visible: false };
            rebuild();
            $scope.$evalAsync();
        });

        $rootScope.$on("BJUnload", () => {
            this.data = { visible: false };
        });
    },
});
