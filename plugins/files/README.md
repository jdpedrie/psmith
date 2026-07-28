# files

Read and write access to a folder of markdown or text files the user has
granted. An Obsidian vault is the flagship use, so content stays plain markdown
and frontmatter is preserved verbatim, but any notes folder works.

## How it works

Same wire as `app_tools`: `ExecuteTool` hands the call to the
`host.DeviceToolBroker`, which dispatches to the connected client. The client
holds a security-scoped bookmark and does the actual filesystem work. The server
never sees a path it can open.

It is a separate plugin rather than a category inside `app_tools` for two
reasons. The folder gets its own settings page instead of burying five toggles
in a long list of every device tool. And future per-folder settings (a default
scratch target, frontmatter templates) have somewhere to live that is not the
generic device-tools config.

The tool catalog is defined locally rather than imported from
`server/devicetools`, so per-plugin metadata stays with the plugin.

## Capabilities

| Interface | Why |
|---|---|
| `pluginapi.Configurable` | One boolean per tool, all under a `Folder` category. |
| `pluginapi.ToolProvider` | Implies a `ToolUse` model requirement. |

## Config

| Field | Default |
|---|---|
| `enabled.files_list_notes` | on |
| `enabled.files_read_note` | on |
| `enabled.files_search_text` | on |
| `enabled.files_append_note` | off |
| `enabled.files_create_note` | off |

Reads on, writes off. A tool absent from the config map takes the catalog's
`defaultEnabled`, so a fresh attach is immediately useful and cannot mutate
anything until the user opts in.

If the model reports that files are read-only, this is why. The write tools are
off until switched on.

## Failure modes

- **No broker on the context.** "no DeviceToolBroker in context, server not
  wired". A wiring bug.
- **Tool disabled.** Explicit "disabled for this profile" error, so the model
  knows the difference between a tool that does not exist and one it is not
  allowed to use.
- **No client connected.** The broker call times out.
- **Bookmark stale.** The client fails the call and the reason comes back as the
  tool result. Re-granting the folder is a client-side action.
