// update Loading screen (cosmetic rebrand)
// BeamNG 0.39 rebuilt the UI boot screen (Vue shell): the old hardcoded
// document.body.children[2] + "Loading UI..." DOM no longer exists. The new boot markup
// (ui/entrypoints/main/index.html) exposes a stable ".ui-boot-title" element instead;
// everything here is defensive since this is purely decorative.
(function () {
    try {
        const bootTitle = document.querySelector(".ui-boot-title");
        if (bootTitle && bootTitle.textContent.includes("Loading")) {
            bootTitle.textContent = "Loading BeamJoy...";
        }
    } catch (e) { /* decorative only, never block module load */ }
})();

const beamjoyModule = angular.module("beamjoy", [
    "pascalprecht.translate",
    "ngSanitize",
]);

await import(`/ui/modModules/beamjoy/override/chat.js`);

await import(`/ui/modModules/beamjoy/directives/tooltip.js`);
await import(`/ui/modModules/beamjoy/directives/ngHtml.js`);
await import(`/ui/modModules/beamjoy/directives/textareaAutoheight.js`);
await import(`/ui/modModules/beamjoy/directives/fitText.js`);

await import(`/ui/modModules/beamjoy/beamjoy-store.js`);

await import(`/ui/modModules/beamjoy/cmps/beamjoy-style/app.js`);
await import(`/ui/modModules/beamjoy/cmps/icon/app.js`);
await import(`/ui/modModules/beamjoy/cmps/toggle/app.js`);
await import(`/ui/modModules/beamjoy/cmps/slider/app.js`);
await import(`/ui/modModules/beamjoy/cmps/select/app.js`);
await import(`/ui/modModules/beamjoy/cmps/colorPicker/app.js`);
await import(`/ui/modModules/beamjoy/cmps/window/app.js`);
await import(`/ui/modModules/beamjoy/cmps/tabs/app.js`);
await import(`/ui/modModules/beamjoy/cmps/accordion/app.js`);
await import(`/ui/modModules/beamjoy/cmps/fade/app.js`);
await import(`/ui/modModules/beamjoy/cmps/contextMenu/app.js`);
await import(`/ui/modModules/beamjoy/cmps/sortable/app.js`);

await import(`/ui/modModules/beamjoy/windows/hud/app.js`);
await import(`/ui/modModules/beamjoy/windows/main/app.js`);
await import(`/ui/modModules/beamjoy/windows/config/app.js`);
await import(`/ui/modModules/beamjoy/windows/activity/app.js`);

beamjoyModule.component("beamjoy", {
    template: ``,
    controller: function ($rootScope, $compile, beamjoyStore, bjChat) {
        this.$onInit = () => {
            setTimeout(() => {
                const wrapper = document.querySelector("beamjoy");
                wrapper.style.position = "absolute";
                wrapper.style.zIndex = 1;
                while (wrapper.firstChild) {
                    wrapper.removeChild(wrapper.firstChild);
                }

                const el = angular.element(`
                        <bj-style></bj-style>
                        <bj-context-menu></bj-context-menu>

                        <bj-hud></bj-hud>
                        <bj-main></bj-main>
                        <bj-config></bj-config>
                        <bj-activity></bj-activity>
                    `);
                $compile(el)($rootScope);
                angular.element(wrapper).append(el);
            }, 1000);
        };

        const requestSizesAndPositions = () => {
            $rootScope.$broadcast("BJRequestWindowsSizesAndPositions");
        };
        $rootScope.$on("editApps", function (_, state) {
            const wrapper = document.querySelector("beamjoy");
            wrapper.style.zIndex = state ? "auto" : "1";
            requestSizesAndPositions();
        });
        $rootScope.$on("appContainer:addApp", requestSizesAndPositions);
        $rootScope.$on("appContainer:removeApp", requestSizesAndPositions);
        $rootScope.$on(
            "appContainer:onUIDataUpdated",
            requestSizesAndPositions
        );
        $rootScope.$on("appContainer:save", requestSizesAndPositions);
        $rootScope.$on("appContainer:resetLayout", requestSizesAndPositions);
        $rootScope.$on("appContainer:deleteLayout", requestSizesAndPositions);
        $rootScope.$on(
            "appContainer:createNewLayout",
            requestSizesAndPositions
        );
        $rootScope.$on("GameStateUpdate", requestSizesAndPositions);

        $rootScope.$on("BJUnload", () => {
            document.querySelector("beamjoy").remove();
        });
    },
});

// Mount the <beamjoy> element into the shared "BeamNG.ui" app instead of
// self-bootstrapping a second, isolated Angular app. Since 0.39, the core UI
// loader (ui/entrypoints/main/angularModules.js) auto-registers every
// /ui/modModules/<name>/<name>.js as a *dependency* of "BeamNG.ui" and
// bootstraps that single app itself - it never bootstraps ours. A separate
// `angular.bootstrap(container, ["beamjoy"])` call here creates a disconnected
// $rootScope that guihooks.trigger() (window.globalAngularRootScope.$broadcast,
// set once in BeamNG.ui's own .run() block) can never reach, so Lua-originated
// events (BJEvent, BJUpdateWindowSettings, BJActivityState...) would never
// arrive. Using .run() lets Angular inject the real, shared $rootScope/$compile.
// (Fix identified by Captain Nugget / foodcache3's 0.39 port.)
beamjoyModule.run(["$compile", "$rootScope", function ($compile, $rootScope) {
    const container = document.createElement("beamjoy");
    document.body.prepend(container);
    $compile(container)($rootScope);
}]);

export default beamjoyModule;
