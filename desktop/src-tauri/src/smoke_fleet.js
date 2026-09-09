// Fixed, opt-in native packaging probe. Only synthetic loopback services.
async function (fixtures) {
  let stage = "startup";
  const find = selector => document.querySelector(selector);
  const wait = async (predicate, timeout = 30000) => {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      const value = predicate();
      if (value) return value;
      await new Promise(resolve => setTimeout(resolve, 75));
    }
    throw new Error("timeout");
  };
  const click = async selector => (await wait(() => find(selector))).click();
  const fill = (form, values) => {
    for (const [name, value] of Object.entries(values)) {
      const input = form.elements.namedItem(name);
      input.value = value;
      input.dispatchEvent(new Event("input", {bubbles: true}));
      input.dispatchEvent(new Event("change", {bubbles: true}));
    }
  };
  const submit = async (selector, values) => {
    const form = await wait(() => find(selector));
    fill(form, values);
    form.requestSubmit();
  };
  const report = async name => {
    if (!find("#workspace-form")) await click("#settings-open");
    await submit("#workspace-form", {name});
    await wait(() => find("#workspace-name")?.textContent === name && !find("#workspace-form"));
  };
  const select = async name => {
    const button = await wait(() => Array.from(document.querySelectorAll("#agent-rail button"))
      .find(button => button.textContent.includes(name)));
    button.click();
    await wait(() => find("#agent-view h1")?.textContent === name);
  };
  const prompt = async text => {
    await wait(() => find("#send:not([disabled])"));
    await submit("#composer", {prompt: text});
    await wait(() => find(".permission button:not([disabled])"));
  };
  try {
    await wait(() => find("[data-phx-main].phx-connected"));
    stage = "credential settings";
    await click("#settings-open");
    await submit("#credential-form", {provider: "openai", secret: "synthetic-native-key"});
    await wait(() => find("#credential-openai")?.textContent.includes("Saved"));
    await wait(() => find('#credential-form input[name="secret"]')?.value === "");
    await click("#credential-openai button");
    await wait(() => !find("#credential-openai button"));
    await report("Native fleet: settings passed");
    stage = "connect two agents";
    for (const [name, url] of [["Alpha", fixtures[0]], ["Beta", fixtures[1]]]) {
      await click('[aria-label="Connect agent"]');
      await submit("#connect-form", {name, url, secret: "synthetic-" + name});
      await wait(() => !find("#connect-form"));
      await select(name);
      await wait(() => find("#send:not([disabled])"));
    }
    stage = "A2A card URL discovery";
    await wait(() => find("#agent-card-url")?.value === "https://agent.example/.well-known/agent-card.json");
    stage = "copy A2A card URL";
    // Reproduce WebKit's browser-clipboard refusal while exercising the native
    // command through the real button. Python verifies the system pasteboard.
    const browserCopy = document.execCommand;
    const browserClipboard = navigator.clipboard.writeText;
    document.execCommand = () => false;
    navigator.clipboard.writeText = async () => { throw new Error("browser clipboard unavailable"); };
    await click("#copy-agent-card-url");
    await wait(() => {
      const status = find("#agent-card-copy-status")?.textContent;
      if (status === "Select and copy the URL above.") {
        stage = "A2A clipboard write rejected";
        throw new Error("clipboard rejected");
      }
      return status === "URL copied";
    });
    document.execCommand = browserCopy;
    navigator.clipboard.writeText = browserClipboard;
    stage = "native clipboard rejects credential URLs";
    for (const url of ["https://user:synthetic@agent.example/.well-known/agent-card.json",
      "https://agent.example/.well-known/agent-card.json?key=synthetic", "http://127.0.0.1/.well-known/agent-card.json"]) {
      let rejected = false;
      try { await window.__TAURI__.core.invoke("copy_agent_card_url", {url}); } catch (_) { rejected = true; }
      if (!rejected) throw new Error("unsafe clipboard URL accepted");
    }
    await report("Native fleet: connections and A2A copy passed");
    stage = "independent approvals";
    for (const name of ["Alpha", "Beta"]) {
      await select(name);
      await prompt("Work on " + name);
    }
    await click("#fleet-nav");
    await wait(() => find("#attention-count")?.textContent.trim() === "2");
    await report("Demo fleet");
    await new Promise(resolve => setTimeout(resolve, 1800));
    await select("Beta");
    await click('.permission button[phx-value-option="allow"]:not([disabled])');
    await wait(() => find(".stage")?.textContent.includes("completed"));
    await wait(() => find("#transcript")?.textContent.includes("Beta completed independently"));
    await report("Native fleet: parallel approval passed");
    stage = "continuation";
    await prompt("Continue Beta");
    await click('.permission button[phx-value-option="allow"]:not([disabled])');
    await wait(() => Array.from(document.querySelectorAll(".stage"))
      .filter(element => element.textContent.includes("completed")).length === 2);
    await report("Native fleet: continuation passed");
    stage = "interruption";
    await select("Alpha");
    await click("#interrupt");
    await wait(() => find(".stage")?.textContent.includes("interrupted"));
    await click("#fleet-nav");
    await wait(() => find("#attention-count")?.textContent.trim() === "0");
    stage = "remove local connection";
    await select("Alpha");
    await click('[phx-click="remove_agent"]');
    await click('[phx-click="confirm_remove"]');
    await wait(() => document.querySelectorAll("#agent-rail button").length === 1);
    await select("Beta");
    await wait(() => document.querySelectorAll(".stage").length === 2);
    if (fixtures.length === 3) {
      stage = "creation credentials";
      await click("#settings-open");
      for (const [provider, secret] of [["sprites", "test-org/token/synthetic-secret"], ["openai", "synthetic-native-key"]]) {
        await submit("#credential-form", {provider, secret});
        await wait(() => find("#credential-" + provider)?.textContent.includes("Saved"));
        await wait(() => find('#credential-form input[name="secret"]')?.value === "");
      }
      await report("Native fleet: creation keys saved");
      stage = "discovery and private creation";
      await click("#fleet-nav");
      await click("#platform-open");
      await click("#discover-sprites");
      await wait(() => document.querySelectorAll(".catalogue-row").length === 2);
      await submit("#create-sprite-form", {name: "native-created", organization: "test-org", display_name: "Gamma", runtime: "codex", permissions: "ask", url_auth: "sprite"});
      await wait(() => find('#platform-operations button[phx-click="select_agent"]'), 60000);
      await select("Gamma");
      await wait(() => find("#send:not([disabled])"));
      await report("Native fleet: private creation passed");
      await submit("#composer", {prompt: "Review the project files and summarize the working tree changes."});
      await wait(() => find(".stage")?.textContent.includes("completed"));
      stage = "file inspector";
      await click("#refresh-inspector");
      await wait(() => find('#workspace-files button[phx-value-path="proof.txt"]'));
      if (!find('#workspace-files button[phx-value-path="outside-link"][disabled]')) throw new Error("symlink enabled");
      await click('#workspace-files button[phx-value-path="proof.txt"]');
      await wait(() => find("#workspace-file pre")?.textContent === "baseline\nstaged\nunstaged\n");
      await report("Demo files");
      await new Promise(resolve => setTimeout(resolve, 1800));
      stage = "Git inspector";
      await click("#inspector-tab-changes");
      await click("#refresh-inspector");
      await wait(() => find("#workspace-changes")?.textContent.includes("proof.txt"));
      await click('#workspace-changes button[phx-value-action="diff"]:not([phx-value-staged])');
      await wait(() => find("#workspace-diff pre")?.textContent.includes("+unstaged"));
      await report("Demo changes");
      await new Promise(resolve => setTimeout(resolve, 1800));
      await click("#inspector-tab-changes");
      await wait(() => find("#workspace-changes"));
      await click('#workspace-changes button[phx-value-staged="true"]');
      await wait(() => find("#workspace-diff pre")?.textContent.includes("+staged"));
      if (find("#workspace-diff pre").textContent.includes("+unstaged")) throw new Error("mixed staged diff");
      await select("Beta");
      await select("Gamma");
      await wait(() => find("#workspace-files"));
      await report("Native fleet: inspector passed");
      await click("#settings-open");
      await click("#credential-openai button");
      await wait(() => !find("#credential-openai button"));
    }
    await report("Native fleet passed");
  } catch (_) {
    await report("Native fleet failed: " + stage);
  }
}
