// Votes window - kick votes and activity-start votes share one generic panel, driven
// entirely by the BJVoteState descriptor pushed from Lua (beamjoy/votes.lua pushUIState):
// current vote (if any), eligible targets/activities, permission-gated start controls, and
// the vote/cancel actions. Mirrors windows/activity/app.js's plumbing pattern.
angular.module("beamjoy").component("bjVotes", {
    templateUrl: "/ui/modModules/beamjoy/windows/vote/app.html",
    controller: function ($rootScope, $interval, beamjoyStore, beamjoyWindowRect, $scope) {
        this.data = { vote: null, players: [], activities: [], canStartKick: false, canStartActivity: false, canCancel: false };
        this.selectedTarget = null;
        this.selectedActivity = null;

        $rootScope.$on("BJSendAppsSizesAndPositions", (_, data) => {
            const el = data["beamjoy-votes"];
            const dom = document.querySelector("#beamjoy-votes");
            // skip the Lua-driven default once the player has manually moved/resized
            // (same guard as the activity/main/config windows); until the phantom app slot
            // is registered (see integration notes) this branch simply never runs and the
            // CSS fallback position below applies instead
            if (el && dom && !beamjoyWindowRect.get("votes")) {
                dom.style.width = el.width;
                dom.style.height = el.height;
                dom.style.top = el.top;
                dom.style.left = el.left;
            }
        });

        // EMPTY Lua tables serialize as {} (object), not [] - coerce before using Array
        // methods, otherwise the thrown TypeError breaks the whole Angular $broadcast chain
        // and windows registered after this one never receive their events
        const asArray = (v) => (Array.isArray(v) ? v : Object.values(v || {}));

        $rootScope.$on("BJVoteState", (_, state) => {
            this.data = state || {};
            this.data.players = asArray(this.data.players);
            this.data.activities = asArray(this.data.activities);
            this.data.vote = this.data.vote || null;
            // keep the pickers pointed at a valid option as the roster/activity list changes
            if (!this.data.players.find((p) => p.value === this.selectedTarget)) {
                this.selectedTarget = this.data.players.length ? this.data.players[0].value : null;
            }
            if (!this.data.activities.find((a) => a.value === this.selectedActivity)) {
                this.selectedActivity = this.data.activities.length ? this.data.activities[0].value : null;
            }
            $scope.$evalAsync();
        });

        this.startKick = () => {
            if (this.selectedTarget) {
                beamjoyStore.send("BJVoteAction", ["startKick", this.selectedTarget]);
            }
        };
        this.startActivity = () => {
            if (this.selectedActivity) {
                beamjoyStore.send("BJVoteAction", ["startActivity", this.selectedActivity]);
            }
        };
        this.cast = () => beamjoyStore.send("BJVoteAction", ["cast"]);
        this.cancel = () => beamjoyStore.send("BJVoteAction", ["cancel"]);

        // ticks the countdown display every second while a vote is running; the server
        // remains the sole authority on the actual timeout (this is display-only)
        this.remaining = 0;
        const recomputeRemaining = () => {
            this.remaining = this.data.vote
                ? Math.max(0, Math.ceil(this.data.vote.endsAt - Date.now() / 1000))
                : 0;
        };
        const tick = $interval(recomputeRemaining, 1000);
        $scope.$on("$destroy", () => $interval.cancel(tick));
        recomputeRemaining();

        $rootScope.$on("BJUnload", () => {
            this.data = { vote: null, players: [], activities: [], canStartKick: false, canStartActivity: false, canCancel: false };
        });
    },
});
