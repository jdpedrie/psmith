# Profile sharing

A profile is the interesting half of a Psmith setup: the system message, the
model defaults, the plugin pipeline and its config. Sharing one means moving
all of that between accounts, which are otherwise completely isolated. This
document covers the bundle format, the two things that never travel, and how
references to per-user rows survive the trip.

## The bundle

`ExportProfile` returns bytes: a magic prefix, then a serialized
`ProfileBundle`. `ImportProfile` takes them back.

The prefix earns its place. `proto.Unmarshal` succeeds on plenty of arbitrary
input, so without it a user who picks the wrong file gets a confusing empty
import instead of an error. The version field refuses a newer format outright
rather than guessing at a shape it does not understand, which is how you
silently drop half a profile.

Clients write the payload to a file. Base64 works for pasting a small profile
into a chat, but a deep chain with long system messages gets large, so a file
is the primary transport. It is the same bytes either way.

## What never travels

A bundle never carries a credential. Two independent paths could leak one and
both are closed in the export walk, not at the boundary, because a caller who
forgets is a caller who ships someone's API key.

**Plugin config keys the plugin declares `Global` or `Secret`.** Global values
belong to `user_plugin_settings` and are not the profile's to give away. Secret
values are credentials wherever they live. The set comes from the plugin's own
`ConfigFields` at runtime, so a new plugin with a new credential field is
covered without touching the export code.

**Registered MCP servers.** Their specs hold env vars and auth headers,
encrypted at rest precisely because they are secret. The attachment exports as
the server's *name* and the spec is never read.

One case cannot be inspected key by key: a config row for a plugin this build
does not have registered. Its config is dropped whole, because "I do not know
which of these keys is an API key" has exactly one safe answer.

The export tells the sharer what it withheld, so they know what the recipient
will still need to supply.

## Portable handles

A profile carries four references to per-user rows: `compression_provider_id`,
`title_provider_id`, `default_settings.default_provider_id`, and any
`mcp:<id>` pipeline entries. All are UUIDs that mean nothing in another
account.

Dropping them would work and would leave every shared profile half-configured.
Instead they travel as handles that can be resolved on the other side. Provider
references become `(driver type, model id)` pairs, so `(anthropic,
claude-sonnet-4-5)` finds whichever Anthropic provider the importer has. MCP
references become the server name, which `UNIQUE (user_id, name)` makes a
stable handle.

Import resolves each independently. Anything that does not match is left null,
which the schema already reads as "inherit", and reported as a warning. A
missing provider is recoverable; failing the whole import over one is not. So a
profile whose title model is missing still keeps its default model.

Model ids are not validated against the provider's catalog. A model the user
has not enabled yet is a situation they can fix, and refusing the import over
it would be worse than importing a profile they then adjust.

## Flatten or preserve

Flattened is the default. The chain is resolved at export time into one
self-contained profile carrying the fully inherited values, so the recipient
gets a single profile that behaves identically. Preserving would instead add
four or five rows to their list, most of them `parent_only` scaffolding they
did not ask for.

`preserve_chain` keeps the structure: each ancestor exports as its own profile,
root first, and import recreates the chain and rewires each parent onto the row
it just created. That is the right choice for a backup, where the layering is
the point, and for sharing a set of profiles meant to be extended.

The two differ in one more place. A flattened export needs the *merged*
effective pipeline, since one profile stands in for the whole chain: leaf-most
row per plugin name wins, a disabled row subtracts, ordered by ordinal then
name. A chain-preserving export gives each profile its own rows and lets the
merge happen on the other side, the way it normally does.

## Import semantics

Import never overwrites. Every profile in the bundle becomes a new row owned by
the caller, with a new id. Importing can add clutter; it cannot destroy
anything.

Colliding names get suffixed, `Shared` becoming `Shared (2)`, and the rename is
reported. The whole thing runs in one transaction.

`dry_run` performs the same resolution without writing, so a client can show
the warnings and any renames before the user commits. Both clients use it: the
decision happens with the consequences on screen.
