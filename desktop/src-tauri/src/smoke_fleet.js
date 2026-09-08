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
    await report("Native fleet: connections passed");
    stage = "independent approvals";
    for (const name of ["Alpha", "Beta"]) {
      await select(name);
      await prompt("Work on " + name);
    }
    await click("#fleet-nav");
    await wait(() => find("#attention-count")?.textContent.trim() === "2");
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
    await report("Native fleet passed");
  } catch (_) {
    await report("Native fleet failed: " + stage);
  }
}
