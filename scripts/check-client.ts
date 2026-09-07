// Run with Bun against a live installation. This makes paid inference requests.
// Uses the existing template client's actual code; never prints its API key.
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import assert from "node:assert/strict";

const checkout = process.env.FOUNTAIN_CLIENT_ROOT;
const baseUrl = process.env.MANAGOAT_BASE_URL;
const keyFile = process.env.MANAGOAT_KEY_FILE;
assert(checkout && baseUrl && keyFile, "set FOUNTAIN_CLIENT_ROOT, MANAGOAT_BASE_URL and MANAGOAT_KEY_FILE");
const { FountainClient } = await import(resolve(checkout, "src/api/client.ts"));
const apiKey = (await readFile(keyFile, "utf8")).trim();
const client = new FountainClient({ baseUrl, apiKey, via: "paste" });
const headers = { authorization: `Bearer ${apiKey}` };
const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
async function eventually<T>(operation: () => Promise<T>, predicate: (value: T) => boolean): Promise<T> {
  for (let i = 0; i < 180; i++) {
    const value = await operation();
    if (predicate(value)) return value;
    await sleep(1000);
  }
  throw new Error("client acceptance timed out");
}
assert.equal((await fetch(`${baseUrl}/api/agents`)).status, 401);
const preflight = await fetch(`${baseUrl}/api/conversations`, {
  method: "OPTIONS", headers: { origin: "http://localhost:5173", "access-control-request-method": "POST",
    "access-control-request-headers": "authorization,content-type" },
});
assert.equal(preflight.status, 204);
assert.equal(preflight.headers.get("access-control-allow-origin"), "http://localhost:5173");
assert.equal((await client.listAgents())[0].id, "default");
const controller = new AbortController();
const streamed: any[] = [];
let opened = false;
const streaming = client.stream({ lastEventId: null, signal: controller.signal,
  onOpen: () => { opened = true; }, onEvent: (event: any) => streamed.push(event),
  onClose: (error: unknown) => { if (error) throw error; },
});
try {
  await eventually(async () => opened, Boolean);
  const conversation = await client.createConversation({ agent_id: "default",
    prompt: "Remember this token in this conversation: MANAGOAT_MAPLE_581. Do not write files or use tools. Reply READY." });
  const id = conversation.id;
  await eventually(() => client.listTurns(id), (turns: any[]) => turns.at(-1)?.status === "completed");
  await eventually(async () => streamed, (events: any[]) => events.some(e => e.conversation_id === id && e.kind === "output"));
  const firstEvents = await client.listEvents(id);
  const cursor = firstEvents.at(-1).id;
  assert.equal((await client.sendPrompt(id, "What token did I ask you to remember? Reply with only that token. Do not use tools.")).status, "queued");
  await eventually(() => client.listTurns(id), (turns: any[]) => turns.length === 2 && turns[1].status === "completed");
  const events = await client.listEvents(id);
  const reply = events.filter((e: any) => e.id > cursor)
    .flatMap((e: any) => e.blocks || []).filter((b: any) => b.kind === "text")
    .map((b: any) => b.body || "").join("");
  assert(reply.includes("MANAGOAT_MAPLE_581"));
  assert(events.every((e: any, index: number) => index === 0 || e.id > events[index - 1].id));
  const replay = await fetch(`${baseUrl}/api/events/stream?blocks=true&wait=false`, {
    headers: { ...headers, "last-event-id": String(cursor) },
  });
  const replayText = await replay.text();
  const ids = [...replayText.matchAll(/^id: (\d+)$/gm)].map(match => Number(match[1]));
  assert(ids.length && ids.every(id => id > cursor));
  const busy = await client.createConversation({ agent_id: "default",
    prompt: "Use a shell tool to run sleep 120. Do not do other work." });
  await eventually(() => client.listEvents(busy.id), (events: any[]) =>
    events.some(e => e.blocks?.some((b: any) => b.kind === "tool_use")));
  await client.interrupt(busy.id);
  await eventually(() => client.listTurns(busy.id), (turns: any[]) => turns.at(-1)?.status === "interrupted");
  console.log(JSON.stringify({ authenticated: true, cors: true, templateClient: true,
    globalStreaming: true, paginatedHistory: true, followupContext: true,
    cursorReplay: true, interruption: true, conversationId: id }, null, 2));
} finally {
  controller.abort();
  await streaming;
}
