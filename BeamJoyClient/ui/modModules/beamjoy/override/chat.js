// BeamNG 0.39 / BeamMP 4.22.1: BeamMP replaced its HTML chat overlay with an imgui window.
// The globals this override used to build on (addMessage, storeChatMessage, fadeNode,
// scrollToLastMessage) and the #chat-list DOM node no longer exist. Colored chat messages now
// reach the imgui chat window from Lua (beamjoy/chat.lua addImguiMessage, caret color codes),
// so this service is kept only as a stable extension point for a future BeamJoy-owned HTML
// chat window; it deliberately does no DOM work anymore.
angular.module("beamjoy").service("bjChat", function ($rootScope) {
    // messages kept in memory for any future BeamJoy chat UI (payload = JSON string
    // {sender?: {text, color, tag?, tagColor?}, message: {text, color}})
    const history = [];
    const HISTORY_LIMIT = 70;

    $rootScope.$on("BJChat", (_, message) => {
        try {
            history.push({ time: Date.now(), payload: JSON.parse(message) });
            if (history.length > HISTORY_LIMIT) history.shift();
        } catch (e) {
            console.warn("Invalid chat message", message, e);
        }
    });

    $rootScope.$on("BJUnload", () => {
        history.length = 0;
    });

    this.getHistory = () => history;
});
