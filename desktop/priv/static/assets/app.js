const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
const liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {params: {_csrf_token: csrfToken}});
liveSocket.connect();
window.addEventListener("phx:clear-secrets", () => document.querySelectorAll("input[type=password]").forEach(input => { input.value = ""; }));
window.addEventListener("phx:clear-prompt", () => { const input = document.querySelector("#prompt"); if (input) input.value = ""; });
// A real websocket round trip is the native packaging smoke-test boundary.
window.addEventListener("phx:page-loading-stop", () => document.documentElement.dataset.live = "connected");

document.addEventListener("click", async event => {
  const button = event.target.closest("#copy-agent-card-url");
  if (!button) return;
  const input = document.getElementById(button.dataset.copyTarget);
  const status = document.getElementById("agent-card-copy-status");
  if (!input || !status) return;
  let copied = false;
  // Native WebKit may reject browser clipboard APIs even in a focused window.
  if (window.__TAURI__) {
    try { await window.__TAURI__.core.invoke("copy_agent_card_url", {url: input.value}); copied = true; } catch (_) {}
  }
  if (!copied) {
    input.focus();
    input.select();
    try { copied = document.execCommand("copy"); } catch (_) {}
  }
  if (!copied && navigator.clipboard) {
    try { await navigator.clipboard.writeText(input.value); copied = true; } catch (_) {}
  }
  status.textContent = copied ? "URL copied" : "Select and copy the URL above.";
});
