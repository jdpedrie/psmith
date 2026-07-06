# Auth and users

Psmith is multi-user and self-hosted. Authentication is deliberately plain: username and password, a bcrypt hash, and an opaque bearer session token. There is no OAuth, no external identity provider, no email verification. The threat model is a small set of known users on an operator's own server, so the design favors simplicity and operability over the machinery a public SaaS would need. This document covers the session model, the interceptor that guards every RPC, bootstrap and user creation, the admin distinction, and ownership scoping.

## Sessions

`Login` takes a username and password, looks up the user, and compares the password against the stored bcrypt hash. On success it generates an opaque token, inserts a session row with a TTL, and returns the token. The client sends that token as `Authorization: Bearer <token>` on every subsequent request. `Logout` deletes the session row; `WhoAmI` returns the authenticated user. Passwords are hashed with bcrypt at the default cost, and a password change re-hashes.

A post-login hook runs synchronously after a successful login (token generated, session inserted). It is wired in `main.go` so the auth package stays free of the dependencies the hook needs; it is how login-time side effects attach without the auth service knowing about them.

The session is the whole auth state. There is no refresh token and no rotation; a session lives until its TTL expires or the user logs out. A client holds the token and re-presents it; losing it means logging in again.

## The interceptor

Every RPC is guarded by a Connect interceptor that authenticates the bearer token before the handler runs. It pulls the `Authorization` header, runs `AuthenticateBearer` against the sessions table, and on success attaches the resolved user to the request context. Handlers read the user with `auth.MustFromContext`, which panics if it is absent, so a handler can assume an authenticated user without re-checking. A failed check returns `Unauthenticated` (and the equivalent HTTP 401 on the non-RPC endpoints).

Two procedures are on the unauthenticated allowlist: `AuthService.Login` (you cannot present a token before you have one) and `AuthService.Probe` (an unauthenticated identity ping clients use to confirm a server is a Psmith server and reachable before login). Everything else requires a valid session. The allowlist is explicit per-procedure, built from the generated procedure constants, so adding an unauthenticated endpoint is a deliberate one-line change rather than a pattern match that might over-match.

The same bearer check guards the non-RPC HTTP endpoints (`/mcp`, the file download, the device-tool and elicitation respond endpoints), reading the same sessions table so there is one auth surface, not two. See [api/non-rpc-endpoints](../api/non-rpc-endpoints.md).

## Bootstrap

On first run, `Bootstrap` creates an admin user if none exists, from the bootstrap username and password supplied via environment ([configuration.md](../operations/configuration.md)). It is a no-op when any user already exists, so it is safe to leave configured across restarts. This is the seam that gets a fresh install to a state where someone can log in; without it a brand-new database would have no users and no way to make one over the wire.

## Creating users

Beyond bootstrap, users are created through `AuthService.CreateUser`, an authenticated admin RPC. The operator CLI's `psmith useradd` is a thin client over that same RPC, so it works against a fresh or remote server the same way the app would. There is no open sign-up endpoint; user creation is an administrative action by design, matching the small-known-set threat model.

## Admin

A user is either an admin or not (`is_admin` on the row). Admin gates the user-management surface: creating users, listing them, toggling another user's admin flag. The check is explicit in the handlers (`PermissionDenied` for a non-admin), not interceptor-level, because most RPCs are available to any authenticated user and only the user-management ones are restricted. The bootstrapped first user is an admin so the system is administrable from the start.

## Ownership

Authentication answers "who are you"; ownership answers "can you touch this row." Almost every domain object (conversation, profile, provider, file, embedder config, and so on) carries a `user_id`, and handlers scope every read and write to the caller's id. The consistent posture for a cross-user access attempt is to return `NotFound` rather than `PermissionDenied`, so the endpoint cannot be used to probe whether another user's object exists. This shows up everywhere: the file download returns 404 for a wrong-owner file, the device-tool respond endpoint returns 404 for a conversation the caller does not own, the MCP tools scope every query to the authenticated user. The rule is that a user sees their own data and learns nothing about anyone else's, including whether it exists.
