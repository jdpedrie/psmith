# Architecture (moved)

This file has been superseded by the documentation tree under [docs/](README.md).

Start with [design/overview.md](design/overview.md) for what Reeve is, what it optimizes for, and how a turn flows end to end. The old single-file architecture doc has been split into one document per subsystem under [design/](README.md), with the wire contract under [api/](README.md), the schema under [schema/database.md](schema/database.md), and operations under [operations/](README.md).

Code comments that point here should be read as pointing at the relevant design doc:

- Data model, contexts, message roles, thinking -> [design/data-model.md](design/data-model.md) and [design/history-builder.md](design/history-builder.md)
- Providers, drivers, catalog, caching -> [design/providers.md](design/providers.md)
- Streaming, chunks, the supervisor -> [design/streaming.md](design/streaming.md)
- Plugins and the pipeline -> [design/plugins.md](design/plugins.md)
- Tools, device tools, elicitation -> [design/tools.md](design/tools.md)
- Compression -> [design/compression.md](design/compression.md)
- Encryption -> [design/encryption.md](design/encryption.md)
