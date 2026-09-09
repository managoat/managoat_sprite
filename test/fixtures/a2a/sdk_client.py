"""Pinned official client against a real local HTTP service and ACP subprocess.
Only synthetic credentials and prompts. No external network or inference calls.
"""
import asyncio
import sys
from importlib.metadata import version

import httpx
from google.protobuf.json_format import ParseDict
from a2a.client.card_resolver import A2ACardResolver
from a2a.utils.errors import UnsupportedOperationError, TaskNotCancelableError
from a2a.client.transports.jsonrpc import JsonRpcTransport
from a2a.types.a2a_pb2 import (
    AgentCard, Message, Part, ROLE_USER, SendMessageRequest,
    SendMessageConfiguration, GetTaskRequest, ListTasksRequest,
    SubscribeToTaskRequest, CancelTaskRequest,
    TASK_STATE_WORKING, TASK_STATE_COMPLETED, TASK_STATE_CANCELED,
)

async def main(base):
    assert version("a2a-sdk") == "1.0.3"
    async with httpx.AsyncClient(timeout=25, trust_env=False) as anonymous:
        raw = await anonymous.get(base + "/.well-known/agent-card.json")
        raw.raise_for_status()
        # Strict protobuf parsing in addition to the resolver's compatibility parser.
        ParseDict(raw.json(), AgentCard())
        card = await A2ACardResolver(anonymous, base).get_agent_card()
        assert card.supported_interfaces[0].protocol_version == "1.0"
        assert card.supported_interfaces[0].url == "https://agent.example/a2a"
        assert (await anonymous.post(base + "/a2a", json={})).status_code == 401
    async with httpx.AsyncClient(timeout=25, trust_env=False, headers={
        "Authorization": "Bearer test-secret", "A2A-Version": "1.0"
    }) as http:
        # Test-only local transport override: card still advertises the configured HTTPS origin.
        client = JsonRpcTransport(http, card, base + "/a2a")
        def message(mid, context=""):
            return Message(message_id=mid, context_id=context, role=ROLE_USER, parts=[Part(text="Synthetic SDK task")])
        async def approval(context, tid):
            for _ in range(150):
                page = (await http.get(base + f"/api/conversations/{context}/events?blocks=true")).json()
                asks = [b for e in page["data"] if e["turn_id"] == tid for b in e["blocks"] if b.get("kind") == "permission_request"]
                if asks:
                    rid = asks[-1]["request_id"]
                    response = await http.post(base + f"/api/conversations/{context}/requests/{rid}", json={"option_id": "yes"})
                    assert response.status_code == 200
                    return
                await asyncio.sleep(.05)
            raise AssertionError("No real ACP approval request")
        first_request = SendMessageRequest(message=message("sdk-one"))
        events = []
        async for event in client.send_message_streaming(first_request):
            events.append(event)
            if event.HasField("task"):
                first = event.task
                duplicate_live = await client.send_message(SendMessageRequest(
                    message=message("sdk-one"), configuration=SendMessageConfiguration(return_immediately=True)))
                assert duplicate_live.task.id == first.id
                try:
                    await client.send_message(SendMessageRequest(message=message("sdk-busy")))
                except UnsupportedOperationError:
                    pass
                else:
                    raise AssertionError("Busy workspace accepted another task")
                approve = asyncio.create_task(approval(first.context_id, first.id))
        await approve
        assert any(e.HasField("status_update") and e.status_update.status.state == TASK_STATE_COMPLETED for e in events)
        assert any(e.HasField("artifact_update") and e.artifact_update.artifact.parts[0].text == "hello" for e in events)
        task = await client.get_task(GetTaskRequest(id=first.id))
        assert task.status.state == TASK_STATE_COMPLETED
        assert task.artifacts[0].artifact_id == first.id + "-text"
        assert task.artifacts[0].parts[0].text == "hello"
        duplicate = await client.send_message(first_request)
        assert duplicate.task.id == first.id
        # Follow-up is a new task in the original durable context.
        follow = await client.send_message(SendMessageRequest(message=message("sdk-two", first.context_id),
            configuration=SendMessageConfiguration(return_immediately=True)))
        assert follow.task.id != first.id and follow.task.context_id == first.context_id
        # Disconnect an actual SSE socket, then resubscribe and reconcile.
        stream = client.subscribe(SubscribeToTaskRequest(id=follow.task.id))
        snapshot = await anext(stream)
        assert snapshot.task.id == follow.task.id
        await stream.aclose()
        replay = []
        async for event in client.subscribe(SubscribeToTaskRequest(id=follow.task.id)):
            replay.append(event)
            if event.HasField("task"):
                approve = asyncio.create_task(approval(first.context_id, follow.task.id))
        await approve
        assert any(e.HasField("status_update") and e.status_update.status.state == TASK_STATE_COMPLETED for e in replay)
        listing = await client.list_tasks(ListTasksRequest(context_id=first.context_id, page_size=1, include_artifacts=True))
        assert listing.total_size == 2 and listing.next_page_token
        second_page = await client.list_tasks(ListTasksRequest(context_id=first.context_id, page_size=1,
            include_artifacts=True, page_token=listing.next_page_token))
        assert not second_page.next_page_token and second_page.tasks[0].id != listing.tasks[0].id
        third = await client.send_message(SendMessageRequest(message=message("sdk-cancel", first.context_id),
            configuration=SendMessageConfiguration(return_immediately=True)))
        for _ in range(150):
            current = await client.get_task(GetTaskRequest(id=third.task.id))
            if current.status.state == TASK_STATE_WORKING:
                break
            await asyncio.sleep(.05)
        else:
            raise AssertionError("Task did not dispatch")
        try:
            await client.cancel_task(CancelTaskRequest(id=first.id))
        except TaskNotCancelableError:
            pass
        else:
            raise AssertionError("Old task cancellation succeeded")
        current = await client.get_task(GetTaskRequest(id=third.task.id))
        assert current.status.state == TASK_STATE_WORKING
        canceled = await client.cancel_task(CancelTaskRequest(id=third.task.id))
        assert canceled.status.state == TASK_STATE_CANCELED
        turns = (await http.get(base + f"/api/conversations/{first.context_id}/turns")).json()["data"]
        assert [t["status"] for t in turns] == ["completed", "completed", "interrupted"]
    print("Official a2a-sdk 1.0.3: discovery, streaming, get, list, follow-up, dedup, reconnect and cancel passed")

asyncio.run(main(sys.argv[1]))
