// Generic activity window - one window serves every activity (speed, races, hunter...).
// Driven entirely by the BJActivityState descriptor pushed from Lua
// (beamjoy/activity/framework.lua pushUIState): phase, participants, self flags, free-form
// detail rows from the client activity module, and permission-gated stop action.
// Activities only needing lobby/participants/details UI require NO Angular work at all.
angular.module("beamjoy").component("bjActivity", {
    templateUrl: "/ui/modModules/beamjoy/windows/activity/app.html",
    controller: function ($rootScope, beamjoyStore, $scope) {
        this.data = { visible: false };

        $rootScope.$on("BJSendAppsSizesAndPositions", (_, data) => {
            const el = data["beamjoy-activity"];
            const dom = document.querySelector("#beamjoy-activity");
            if (el && dom) {
                dom.style.width = el.width;
                dom.style.height = el.height;
                dom.style.top = el.top;
                dom.style.left = el.left;
            }
        });

        $rootScope.$on("BJActivityState", (_, state) => {
            this.data = state || { visible: false };
            $scope.$evalAsync();
        });

        this.action = (action) => {
            beamjoyStore.send("BJActivityAction", [action, this.data.key]);
        };

        $rootScope.$on("BJUnload", () => {
            this.data = { visible: false };
        });
    },
});
