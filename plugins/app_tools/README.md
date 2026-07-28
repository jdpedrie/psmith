# app_tools

Exposes the tools that live on the user's device (Calendar, Reminders, Health)
to the model. The server never touches the OS itself. It advertises a tool
catalog, and when the model calls one, the request rides down the open stream
to whichever client is connected and comes back as an ordinary tool result.

The name is deliberate. "device_tools" is what the plumbing is called;
"app_tools" is what the user is choosing when they tick the boxes.

## How it works

`Tools()` returns the server-side catalog filtered three ways, in this order:

1. The per-tool `enabled` config, resolved through the usual
   parent → child → conversation merge chain.
2. The connected client's advertised support set. HealthKit tools do not
   appear when only a Mac is attached, and vice versa.
3. The catalog itself, which is the source of truth. A tool that is not in the
   catalog can never be exposed, however stale config says otherwise.

`ExecuteTool` hands the call to the `host.DeviceToolBroker` on the dispatch
context. The broker emits a `CHUNK_TYPE_DEVICE_TOOL_USE` chunk and blocks until
the client POSTs a response back.

Tools missing from the `enabled` map fall back to the catalog's per-tool
`DefaultEnabled` flag, so a newly shipped tool gets a sensible default without
forcing every existing profile to re-save.

## Capabilities

| Interface | Why |
|---|---|
| `pluginapi.Configurable` | One boolean per catalog tool, grouped by `Category` so the form reads as Calendar / Health / Reminders rather than one flat list. |
| `pluginapi.ToolProvider` | The whole point. Implies a `ToolUse` model requirement. |

## Config

Twelve `enabled.<tool>` booleans across three categories. Nothing else. There is
no API key and no endpoint, because the device is the backend.

## Failure modes

- **No broker on the context.** `ExecuteTool` returns "no DeviceToolBroker in
  context, server not wired". This is a wiring bug, not a user error.
- **No client connected.** The broker call times out. The model sees the error
  as a tool result and can retry or route around it.
- **Tool disabled.** Returns an explicit "disabled for this profile" error
  rather than pretending the tool does not exist, so the model's next move is
  informed.

## Related

`files` uses the same device-tool wire but keeps its own catalog and its own
settings page. See its README for why they are separate.
