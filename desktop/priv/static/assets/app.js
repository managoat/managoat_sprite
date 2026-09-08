const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {params: {_csrf_token: csrfToken}});
liveSocket.connect();
window.addEventListener("phx:clear-secrets", () => document.querySelectorAll("input[type=password]").forEach(input => { input.value = ""; }));
window.addEventListener("phx:clear-prompt", () => { const input = document.querySelector("#prompt"); if (input) input.value = ""; });
// A real websocket round trip is the native packaging smoke-test boundary.
window.addEventListener("phx:page-loading-stop", () => document.documentElement.dataset.live = "connected");
