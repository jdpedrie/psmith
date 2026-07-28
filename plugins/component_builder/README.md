# component_builder

Lets a user define structured-output recipes without writing Go. It is the
generic form of the pattern `lettered_choices` hard-codes: teach the model to
wrap something in tags, then parse those tags into a rendered UI component.

## How it works

Each definition pairs three things:

- A system-message snippet teaching the model when and how to emit the
  component: the open and close tags, the body shape, the situations that call
  for it.
- An optional `[system_reminder ...]` tail injected into the head user message
  every turn, so a long-context model does not drift off the convention after a
  few exchanges.
- A `ContentRenderer` parser that scans the assistant's post-display content for
  the tag pair, decodes the body as the component's props JSON, and emits a
  `UIFragment` in place of the text block.

All definitions live on one config field, `components`. There is no useful way
to express a recipe through plain `ConfigField`s, so the Mac and iOS settings
pages dispatch on this plugin's name and render a structured editor instead of
the generic form.

## Capabilities

| Interface | Why |
|---|---|
| `pluginapi.Configurable` | Holds the definitions array. |
| `pluginapi.SystemPrompter` | Appends each definition's instruction snippet. |
| `pluginapi.HistoryTransformer` | Injects the per-turn reminder onto the head user message. Wire prefix only, never persisted. |
| `pluginapi.ContentRenderer` | Parses the tags back into fragments at display time. |

## Config

One field, `components`: an array of `(name, component, tags, instructions,
reminder)` recipes, stored verbatim. The custom client form CRUDs against that
shape.

## Failure modes

- **Model emits malformed JSON in the body.** The renderer leaves the text
  block alone. A visible tag is a better outcome than a swallowed message.
- **Unclosed tag.** Same. No fragment, text passes through.
- **Component name the client does not know.** The fragment arrives and renders
  as nothing. Client and config have to agree; the server does not validate the
  component name because it has no registry of what a given client build can
  draw.
- **No definitions configured.** Every hook no-ops. Safe to attach and leave
  empty.
