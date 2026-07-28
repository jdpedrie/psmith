# imagegen

One tool, `generate_image`, that turns a text prompt into an image and returns
it as a tool attachment.

## How it works

The only persisted config is a `model` field of `MODEL_PICKER` type. At
`ExecuteTool` time the plugin resolves that `(provider_id, model_id)` pair
through the `host.ProviderResolver` on the dispatch context, picks the upstream
API from the resolved provider type, and returns the image as a
`pluginapi.ToolAttachment`.

Generated images ride the existing tool-result attachment pipeline. They persist
on the assistant message with `role_hint=tool_result`, and on Anthropic and
Google they go back into the next round's wire prefix, so the model can look at
what it made and iterate.

Provider dispatch:

- **openai-compatible**: `POST /v1/images/generations`. Works for real OpenAI
  with `gpt-image-1` or `dall-e-3`, and for any gateway speaking the same shape.
- **google**: `POST /v1beta/models/{model}:generateContent` with
  `responseModalities: ["TEXT","IMAGE"]`, which covers
  `gemini-2.5-flash-image-preview`.

Anything else returns a clear error naming the supported set, so a misconfigured
model fails legibly instead of silently mid-tool-call.

## Capabilities

| Interface | Why |
|---|---|
| `pluginapi.Configurable` | Model picker plus per-call defaults. |
| `pluginapi.ToolProvider` | Implies a `ToolUse` model requirement. |

The model picker's filter sets `RequiresGeneratesImages`, so the chooser only
surfaces models that can actually do this.

## Config

| Field | Notes |
|---|---|
| `model` | Required. Filtered to image-generating models. |
| `size` | Default when the call does not specify. |
| `quality` | Same. |

## Failure modes

Each returns a distinct message, because "image generation failed" is useless
when there are six ways to get there.

- **`model` unset.** "model is not configured".
- **No `ProviderResolver` on the context.** Server not wired.
- **Resolved provider has no API key.** Names the provider type.
- **Unsupported provider type.** Names the supported set.
- **Empty prompt.** Rejected before the HTTP call.
- **Upstream non-200.** Status plus a 240-character body excerpt.
- **200 with no image.** "response missing image data" for OpenAI, "no image
  parts" for Google. Both providers can return a successful response containing
  only a refusal.
