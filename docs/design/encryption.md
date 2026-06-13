# Encryption

Reeve encrypts the secrets it holds on a user's behalf (provider credentials, plugin secrets, Langfuse and embedder API keys) at rest, with a single master key. The scheme is deliberately narrow: AES-256-GCM, one key, no per-row key derivation, no envelope wrapping. This document covers what is encrypted and what is not, the cipher, the master key, the file-URL signing sub-key, and the threat tiers the design does and does not address.

## What is encrypted

Encryption covers credentials and secrets, not content. Encrypted at rest:

- Provider instance credentials (the API key for an Anthropic, OpenAI-compatible, or Google connection).
- Plugin secrets (for example a Brave Search API key) in plugin config.
- The Langfuse secret key.
- The embedder API key.

Not encrypted: message bodies, thinking, tool calls, titles, and the rest of the conversation content live in Postgres as plaintext. The reasoning is that the database is the trust boundary. If an attacker has the database they have the conversations regardless, and encrypting bodies with a key that also sits on the same host buys little. What encryption protects is the blast radius of a leaked database backup or a stray dump: the secrets that would let an attacker spend the user's money or impersonate them upstream stay unreadable without the separately-held master key.

Each secret is stored in its own `*_encrypted BYTEA` column, kept apart from the non-secret config (base URLs, model names, dimensions) that sits in plaintext JSONB. The split means a key rotation or a secret change touches only the encrypted column, and a plain read that does not need the secret never decrypts.

## The cipher

`internal/crypto` is the whole surface. The `Cipher` interface is two methods, `Encrypt` and `Decrypt`. Two implementations:

- **AESGCM** is the production cipher: AES-256-GCM with a fresh random 12-byte nonce per encryption, laid out as `[nonce 12B][ciphertext + 16B auth tag]` in one allocation. GCM authenticates as well as encrypts, so a tampered ciphertext fails to open rather than decrypting to garbage. A nil plaintext maps to nil output, so callers can encrypt an absent value without special-casing.
- **Nop** is a passthrough used in tests and as the fallback when no master key is configured and the deployment opts into running without encryption.

The key must be exactly 32 bytes; anything else is a construction error. There is no per-row key and no key hierarchy beyond the one sub-key below. The simplicity is the point: one key to manage, one algorithm to reason about.

## The master key

The master key comes from `REEVE_MASTER_KEY`, a base64-encoded 32-byte value ([configuration.md](../operations/configuration.md)). It is the root of all at-rest secret encryption. Lose it and every encrypted secret becomes unrecoverable; the user has to re-enter every provider credential and API key. Leak it together with a database dump and the secrets are exposed. So the operational contract is: generate it once, store it somewhere durable and separate from the database backups, and supply it to the process through the environment.

If no master key is configured, the deployment can opt into the Nop cipher and run with secrets stored in the clear. That is a development convenience, not a production posture; a real deployment sets the key.

## The file-URL signing sub-key

File download URLs are signed so a short-lived URL grants read access to one file without a session ([api/non-rpc-endpoints](../api/non-rpc-endpoints.md)). The signing key for those URLs is not the master key directly; it is derived from it with an HMAC over a fixed domain-separation label (`"reeve.fileurl.v1"`). Deriving a sub-key keeps URL signing out of the secret-encryption pipeline, so the two concerns can be audited and, if ever needed, rotated independently. A signed URL token is an HMAC over the file id, the user id, and an expiry; flipping any field invalidates it, and every verification failure returns the same generic "invalid token" so the endpoint leaks nothing about why a token was rejected.

## Threat tiers

What the scheme defends against, and what it does not:

- **Defended: a leaked database or backup.** The secrets are AES-256-GCM ciphertext keyed by a master key held outside the database. A dump without the key yields no usable credentials.
- **Defended: tampering with a stored secret.** GCM authentication means an altered ciphertext fails to decrypt rather than silently producing a wrong key.
- **Not defended: a compromised host with the running process.** The master key is in the process environment, so an attacker who owns the host can read it and decrypt everything. This is out of scope by design; the trust boundary is the host.
- **Not defended: content confidentiality against database access.** Message bodies are plaintext. Anyone with the database reads the conversations.
- **Not addressed yet: tiered encryption, per-user keys, and a sharing model.** These are open threads in the architecture, not shipped. The current design is the floor (protect the credentials that cost money or grant impersonation), and the richer tiers are deliberately deferred rather than half-built.
