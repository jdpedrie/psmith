# API overview

Spalt's API is ConnectRPC over HTTP/2, defined entirely by the protobuf schema in `proto/spalt/v1/`. This document covers the conventions that hold across every service: transport, auth, error codes, the streaming shapes, sparse updates, and the service list. The per-service detail is in [services.md](services.md); the handful of plain HTTP endpoints that are not RPCs are in [non-rpc-endpoints.md](non-rpc-endpoints.md).

The protobuf schema is the source of truth. Generate clients from it ([building-and-codegen.md](../operations/building-and-codegen.md)); this prose describes the surface, the schema defines it.

## Transport

The server speaks the Connect protocol with a protobuf codec over h2c (cleartext HTTP/2), with TLS terminated by whatever the operator puts in front. The Go server stubs are generated into `gen/spalt/v1/spaltv1connect`; the Swift client stubs into `clients/SpaltSwift/Sources/SpaltKit/Generated`. There are three RPC shapes in use: unary (most calls), server-streaming (`SubscribeStream`, `SubscribeAccountEvents`), and client-streaming (`UploadFile`).

## The request/response convention

Every RPC has its own dedicated request and response message. No RPC returns a domain message directly (never a bare `Conversation` or `Profile`), and none returns `google.protobuf.Empty`. Even an RPC with nothing to say returns a `FooResponse {}`. This is a wire-compatibility rule: any response can grow a field later without breaking the schema. When you read the per-service tables, every entry is `FooRequest` to `FooResponse` even where the response is empty today.

## Authentication

Auth is a bearer token. Log in through `AuthService.Login` (or validate a server first with `AuthService.Probe`), get a session token, and send it as `Authorization: Bearer <token>` on every subsequent request. A server interceptor validates the token against the sessions table and attaches the user to the request context before the handler runs; handlers never take a user id in the request, they read it from the context. See [auth-and-users.md](../design/auth-and-users.md).

Only two procedures are unauthenticated: `AuthService.Login` and `AuthService.Probe`. Everything else, including the non-RPC HTTP endpoints, requires a valid session. A missing or invalid token returns `Unauthenticated` (HTTP 401 on the plain endpoints).

## Authorization and ownership

Authentication establishes identity; ownership scoping enforces access. Almost every object carries a `user_id`, and handlers scope every read and write to the caller. A cross-user access attempt returns `NotFound`, not `PermissionDenied`, so the API never confirms whether another user's object exists. Admin-only operations (user management) check the caller's admin flag in the handler and return `PermissionDenied` for a non-admin.

## Error codes

Spalt uses standard Connect error codes with consistent meanings:

- `Unauthenticated` — no valid session.
- `PermissionDenied` — authenticated but not allowed (admin-only operations).
- `NotFound` — the object does not exist, or exists but is not the caller's (the two are deliberately indistinguishable).
- `InvalidArgument` — a malformed request (an unparseable id, a missing required field, a bad upload sequence).
- `FailedPrecondition` — the request is well-formed but the state is wrong: a model that lacks a required capability, a profile missing its compression or title config, a send against a conversation with an in-flight stream.
- `Unimplemented` — a handler whose dependencies are not wired (seen in tests and partial deployments).
- `Internal` — an unexpected server-side failure.

## Sparse updates

Update RPCs are sparse. A field left unset means "leave unchanged"; a field set means "use this value." To distinguish "leave unchanged" from "set to empty / revert to inherited," update requests carry a `clear_fields` list naming the fields to reset. A client must honor the distinction: omitting `title` and clearing `title` are different operations. This pattern appears on `UpdateProfile`, `UpdateConversation`, `UpdateUser`, `UpdateUserModel`, and the config updates.

## Streaming

Two server-streaming RPCs and one client-streaming RPC:

- **`StreamsService.SubscribeStream`** carries a run id and a `from_sequence`; the server replays persisted chunks from that sequence, live-tails new ones, then emits a terminal stream-run event and closes. Each response is a oneof of a chunk or the terminal run. This is the resumable stream the whole client model is built on; the contract is in [client-spec.md](../clients/client-spec.md) and the mechanism in [streaming.md](../design/streaming.md).
- **`EventsService.SubscribeAccountEvents`** pushes account-level changes (today, profile mutations). No replay; a reconnect starts fresh.
- **`FilesService.UploadFile`** is client-streaming: a header message then byte chunks.

Note that `SendMessage` and `Compact` are *not* streaming RPCs. They are unary calls that return a stream-run record; the client then subscribes to that run through `SubscribeStream`. The launch and the watching are separate calls on purpose, which is what decouples a run's lifetime from any one connection.

## Enums worth knowing

The schema defines several enums clients must handle (all follow the proto3 `_UNSPECIFIED = 0` convention):

- **`MessageRole`**: `SYSTEM`, `CONTEXT`, `USER`, `ASSISTANT`, `COMPRESSION_SUMMARY`.
- **`ChunkType`**: `TEXT_DELTA`, `THINKING_DELTA`, `TOOL_USE_START`, `TOOL_USE_DELTA`, `TOOL_USE_END`, `TOOL_RESULT`, `THINKING_SIGNATURE`, `USAGE`, `ELICIT`, `DEVICE_TOOL_USE`, `ERROR`, `DONE`.
- **`StreamRunStatus`**: `RUNNING`, `COMPLETED`, `ERRORED`, `CANCELLED`, `INTERRUPTED`.
- **`StreamRunPurpose`**: `ASSISTANT_RESPONSE`, `COMPRESSION`.
- **`CompressionMode`**: `REPLACE`, `APPEND`.
- **`MetadataSource`**: `CATALOG`, `DRIVER`, `MANUAL`.
- **`DeviceFactKey`**: `LOCALE`, `TIMEZONE`, `PLATFORM`, `LOCATION_CITY`, `LOCATION_COORDS`.

## The services

Eleven proto files define ten services plus the shared types:

| Service | Purpose |
|---|---|
| `AuthService` | Sessions, password management, admin user management. |
| `ConversationsService` | Conversations, contexts, the message tree, sending, editing, branching, compaction, per-conversation plugins. |
| `StreamsService` | Subscribe to and cancel streaming runs; query active runs. |
| `FilesService` | Content-addressed upload, signed URLs, file listing. |
| `ProfilesService` | Profiles, plugin pipelines, plugin types, per-user plugin settings. |
| `ModelProvidersService` | Provider instances, model discovery and enablement, testing, cost rollups. |
| `EmbedderService` | Per-user embedder config and stats. |
| `LangfuseService` | Per-user Langfuse config. |
| `DeviceToolsService` | Device-tool capability registration, catalog, audit log. |
| `EventsService` | Account-scoped server push. |

`types.proto` holds the shared domain messages (`User`, `Profile`, `Conversation`, `Context`, `Message`, `CallSettings`, `StreamRun`, `Chunk`, and the rest). Per-service detail is in [services.md](services.md).
