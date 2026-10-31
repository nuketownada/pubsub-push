# pubsub-push: XMPP pubsub topics delivered over UnifiedPush

Authors: Ada, Joshua Perry · Status: bridge + patch built and tested locally (`tests/`); app not started · 2026-10-31

## Goal

Push notifications to josh's phone from machines and services we run (kago's
disk alarms, signi forwarding Discord desktop notifications, webhooks), where:

- the phone needs **no extra connection**: delivery rides the XMPP connection
  Conversations already keeps open, via UnifiedPush;
- senders are authenticated by the **XMPP identities** they already have
  (kago@6bit.com, signi@6bit.com), or a per-topic secret for webhooks;
- delivery is **store-and-forward**: a notification published while the phone
  is offline arrives when it comes back;
- tapping a notification **opens a URL**, so it can deep-link into an app that
  doesn't speak UnifiedPush itself (discord.com/channels/... opens Discord).

Non-goals: a general ntfy replacement, multi-tenant hosting, end-to-end
encryption of payloads (Prosody sees them; it's our server).

## Overview

```
 kago / signi ──XMPP publish──┐
                              ├─► pubsub node   ──item-published──► bridge ──push iq──► Conversations ──► app
 webhook ──HTTP (pubsub_post)─┘   notify.6bit.com   (stores items)   (cursor per            (UP distributor)   (notification,
                                  (topics, ACLs)                     registration)                              tap → URL)
                                                         ▲
                              app ──HTTPS register {endpoint, topics}──┘
```

Almost all of it is stock Prosody. The custom parts are one small module (the
bridge), a few-line patch to `mod_unified_push`, and a minimal Android app.

| Piece | Source | Role |
|---|---|---|
| `mod_pubsub` on `notify.6bit.com` | Prosody core | Topics (nodes), persistent items, publisher ACLs |
| `mod_pubsub_post` | prosody-modules (Stable) | Optional HTTP/webhook publishing |
| `mod_unified_push` (+ patch) | prosody-modules | Issues endpoints to Conversations; delivers push iqs |
| `mod_pubsub_unified_push` | **new**, this repo | UnifiedPush application server for pubsub: registrations, cursors, delivery, catch-up |
| Android app | **new**, this repo | Registers with the distributor, registers topics with the bridge, shows notifications |

## Background: what `mod_unified_push` does

Read from the module as shipped in liver's Prosody 13.0.6 (prosody-modules
rev `15a7749c7acb`), 215 lines:

- **Registration** (`handle_register`): Conversations sends an iq with two
  32-byte hashes, `instance` and `application`. The module signs
  `{instance, application, sub = <sender full JID>, exp = now + ttl}` into a
  token; the endpoint is `<http_external_url>/push/<token>`.
- **Token backends**: `paseto` (v3 local: encrypted, self-contained; the default
  when `util.paseto` exists, as in 13.x), `storage` (random id, data in the
  module store), or `jwt` (needs `unified_push_secret`). Liver sets none, so
  presumably paseto. Nothing is stored per registration.
- **Expiry**: `unified_push_registration_ttl`, default 86400. Every renewal
  mints a new token, so **endpoints change at least daily**.
- **Delivery** (`handle_push`): a POST to the endpoint decodes the token and
  sends `<push xmlns='http://gultsch.de/xmpp/drafts/unified-push'
  instance=… application=…>base64(body)</push>` in an iq to `sub`. The HTTP
  status mirrors the iq result: 201 delivered (acknowledged by Conversations),
  404 rejected/unknown, 503 recipient unavailable, 500 anything else
  (including `send_iq`'s 120s timeout). Payload max 4096 bytes.
- **No queueing.** A push to an offline phone is lost; retrying is the
  application server's job.
- **Two bugs** (found by the harness, fixed in our patch, see below): a push to
  an *offline* full JID is reported as delivered (201) and silently lost, and
  every error reply or timeout raises in the result handler instead of mapping
  to 404/503/500.
- **ACL**: by default any account on the host may register.

## Topics: pubsub nodes on `notify.6bit.com`

A `Component "notify.6bit.com" "pubsub"` on liver. One node per topic, e.g.
`kago`, `signi-discord`, `liver`.

Node configuration:

| Option | Value | Why |
|---|---|---|
| `persist_items` | true (default) | The store in store-and-forward |
| `max_items` | 100 (service cap `pubsub_max_items`, default 256) | Retention bound for an offline phone |
| `publish_model` | `publishers` | Only JIDs with publisher affiliation (kago@, signi@) |
| `access_model` | `whitelist` | Only listed members may read, which the bridge also uses to authorise topic registrations |

Items are stored in Prosody's archive store (`pubsub.lib.lua`
`archive_itemstore`); `service:get_items()` iterates newest-first up to
`max_items`.

Nobody holds a *real* pubsub subscription to these nodes: if josh@ subscribed,
pubsub would also send its own `<message>` event to Conversations for every item,
showing up as chat clutter. The bridge listens to the service's events in-process
instead.

### Item payload

XEP-0335 JSON container, the same wrapping `mod_pubsub_post` produces:

```xml
<item id='…'>
  <json xmlns='urn:xmpp:json:0'>{"title":"md array degraded","body":"…","url":"https://kago.local:9090/","priority":"high"}</json>
</item>
```

Fields: `title` (required), `body`, `url` (tap action), `priority`
(`low`/`default`/`high` → Android notification importance), `group` (optional
collapse key).

**Item ids must be unique.** An XMPP publish without an id gets a server UUID
(`pubsub.lib.lua`, `uuid_generate()`). `mod_pubsub_post` uses the JSON's `id`
field if present but otherwise **`"current"`**, which replaces the previous
item and breaks the cursor. Webhook publishers must send an `id`.

### Publishing

- **XMPP** (machines): a standard XEP-0060 publish iq from the machine's JID.
  `go-sendxmpp --raw` can send it, so `kago-notify` stays a one-liner.
- **HTTP** (webhooks): `mod_pubsub_post` at `/pubsub_post/<node>`, with a
  per-node HMAC secret (`pubsub_post_secrets`) and a publisher JID mapping
  (`pubsub_post_actors`). Its siblings (`mod_pubsub_alertmanager`,
  `_forgejo`, `_github`) are ready-made publishers too.

## Bridge: `mod_pubsub_unified_push`

A UnifiedPush application server whose application is pubsub. Loaded on the
**user host** (`6bit.com`), next to `mod_unified_push` (`module:depends`), so
its HTTP route is served exactly like `/push/`, and the reconnect hooks are
local. It reaches the pubsub service on `notify.6bit.com` through
`modulemanager.get_module(host, "pubsub").service`, attaching on
`server-started` and lazily wherever it needs it, since load order between
hosts isn't fixed.

### Registration API

`POST https://xmpp.6bit.com/pubsub_push/register` (served by Prosody's HTTP
server through the existing nginx `xmpp.6bit.com` proxy):

```json
{ "endpoint": "https://xmpp.6bit.com/push/<token>", "topics": ["kago", "signi-discord"] }
```

1. Decode the token with `mod_unified_push`'s verifier (patch below). This
   gives `sub`, `application`, `instance` and `exp`. A token that doesn't decode
   is rejected: possessing a valid endpoint is the credential.
2. Authorise: for each topic, `service:may(node, bare(sub), "get_items")`, which
   is the node's whitelist. Unknown or forbidden topics are rejected individually
   in the response, not silently dropped.
3. Upsert the registration keyed by **(bare(sub), application, instance)**.
   That key survives the daily endpoint renewal, so a renewal updates the stored
   token and keeps the cursors.
4. Attempt delivery of anything pending (below).

Response: `200 {"topics": {"kago": "ok", "liver": "forbidden"}}`.

`DELETE` with the same body unregisters. Registrations whose token expired more
than 7 days ago without renewal are dropped.

### State

`module:open_store("pubsub_unified_push")`, one record per registration:

```lua
{
  token = "<current endpoint token>", sub = "josh@6bit.com/Conversations.ReL2",
  topics = { "kago", "signi-discord" },
  cursor = { kago = "<last delivered item id>", ["signi-discord"] = "" },
  first = { ["signi-discord"] = "<first item published since cursor \"\">" },
  updated = 1761900000,
}
```

That's all the state. Items live in pubsub, so the bridge holds pointers, not
messages.

A registration's cursor for a newly added topic starts at the node's current
last item (`service:get_last_item`), so subscribing doesn't replay history.
Cursor `""` means "everything retained is due": the node was empty at
registration, or a gap notice was just delivered. In that state `first`
records the first item published since (from the publish event; after a gap,
the oldest retained item), so a later loss is still detected.

### Delivery

For each pending (registration, topic): collect retained items newer than the
cursor (iterate `get_items`, which is newest-first, stop at the cursor, then
deliver oldest-first), and for each one:

```json
{ "topic": "kago", "id": "<item id>", "title": "…", "body": "…", "url": "…", "priority": "high" }
```

(No publish timestamp: `get_items` doesn't expose the archive's. The app uses
arrival time.)

The body is truncated so the JSON fits the 4096-byte limit. Delivery uses
`mod_unified_push`'s own push path (patch below), and the cursor advances only on
"delivered" (201). Anything else leaves the cursor where it is and stops that
registration's run. Deliveries are serialised per registration to keep order.

If the cursor id (or `first`, when the cursor is `""`) is no longer retained
(more than `max_items` published while offline), the bridge delivers
everything retained, preceded by a synthetic
`{"topic":"kago","gap":true}` notice the app shows as "some notifications were
missed".

**Semantics: at-least-once, in order, per topic, within retention.** The
acknowledgement means Conversations received the push and handed it to the app,
not that a notification was displayed. A push that timed out (500) may still
arrive later, so the app de-duplicates on `(topic, id)`.

### Triggers

- `item-published` on the pubsub service: deliver to registrations with that topic.
- `resource-bind` and `smacks-hibernation-end` on `6bit.com` for a registration's
  bare JID: catch up as soon as the phone reconnects (Conversations usually
  *resumes* a session rather than binding a new one, hence both).
- Registration POST: catch up immediately.
- A timer (every 5 min, backing off per registration up to 1h) for anything
  still pending.

## Patch to `mod_unified_push`

Two parts, both upstreamable to prosody-modules:

1. **Bug fix** (commit `8c92fa0`): `send_iq` *resolves* with an error the server
   returns through the origin (`service-unavailable` for an offline full JID),
   so check the result's type; and map rejections from the `util.error`'s
   fields rather than a nonexistent `.stanza`. Affects every user of the
   module, Tusky-via-Mastodon included: today an offline push is lost.
2. **Exposure** (commit `47cc240`): the bridge needs two things the module only
   has as locals, decoding a token and delivering a push:

- expose `verify_token(token) -> ok, data` (wraps `backends[backend].verify`);
- split the body of `handle_push` into `push(token, payload) -> promise(status)`,
  which `handle_push` and other modules both call.

Other modules reach these through the module environment, the same way
`mod_pubsub_post` uses `module:depends("pubsub").service`. Until upstream takes
it, we carry it as a small patch over the vendored module (via
`services.prosody.extraPluginPaths` on liver).

Alternatives considered: reading `mod_unified_push`'s paseto key from its store
(coupled to private internals); switching it to the `storage` backend and
reading records (couples to the storage format); POSTing to the endpoint over
HTTP from the bridge (no decode, so no topic authorisation, and it depends on
Prosody's HTTP host routing).

## Android app

Minimal, Kotlin, UnifiedPush connector library:

- **Register** with the distributor (Conversations) at first start.
  `onNewEndpoint` → `POST /pubsub_push/register {endpoint, topics}`, retried
  with backoff until it succeeds. It also fires on every renewal, which is what
  keeps the daily endpoint change transparent.
- **Settings**: one screen listing topics (typed in, with the per-topic result
  from the last registration shown). Editing re-POSTs.
- **`onMessage`**: parse the JSON, de-duplicate on `(topic, id)` (keep the last
  ~500), post a notification on a per-topic channel (so Android's per-channel
  controls work), importance from `priority`. Tap → `PendingIntent.getActivity`
  with `ACTION_VIEW` on `url`, launched directly from the notification:
  Android 12+ blocks trampolines through receivers or services.
- `POST_NOTIFICATIONS` runtime permission (Android 13+).
- No account, no XMPP, no network connection of its own besides the
  registration POST.

Build: reproducible with Nix (exact Gradle-in-Nix approach open), sideloaded.

## Senders

- **kago**: `kago-notify` publishes to node `kago` instead of messaging josh@
  directly; same call sites (alarm timer, `kago-notify-failure@`, boot).
  The direct XMPP message can stay as a fallback during rollout.
- **signi**: a user service watching the session D-Bus for notifications from
  Discord, publishing `{title, body, url}` to `signi-discord`. The channel URL
  may not be recoverable from a desktop notification; fallback `url` is
  `https://discord.com/app`.

## Deployment (liver)

- `extraConfig`: `"pubsub_unified_push"` in the `6bit.com` VirtualHost's
  modules, with `pubsub_unified_push_service = "notify.6bit.com"` and the node
  config; `Component "notify.6bit.com" "pubsub"` (plus `"pubsub_post"` when
  needed) and `pubsub_max_items`.
- Module and patched `mod_unified_push` from this repo via `extraPluginPaths`.
- Nodes created declaratively at startup by the bridge from config
  (`pubsub_unified_push_nodes = { kago = { publishers = {"kago@6bit.com"}, members = {"josh@6bit.com"} } }`),
  so the ACLs live in mynix rather than in Prosody's data: declared affiliations
  are set and undeclared publisher/member ones removed on attach.
- DNS: `notify.6bit.com` already resolves via the `*.6bit.com` wildcard;
  only local users talk to it, so no SRV record needed.

## Open questions (to settle while prototyping)

1. **Liver's token backend.** Confirm paseto (the `_private` key in the
   `unified_push` store), since the patch's `verify_token` path depends on it.
2. **Conversations renewal.** How often it re-registers, and whether
   `instance`/`application` stay stable across renewals (the registration key
   assumes they do). Watch two days of liver logs.
3. **Hibernated sessions.** A push iq to a smacks-hibernated Conversations
   session: queued and acknowledged on resume, or timed out at 120s (500)?
   It decides whether resume-triggered catch-up produces duplicates (the app
   copes either way).
4. **Tusky** (side issue). If its notifications stop about 24h after
   registration, it isn't following endpoint renewals; raise
   `unified_push_registration_ttl` on liver.
5. **Gradle under Nix** for the app.

## Plan

1. ~~Local Prosody test harness; patch `mod_unified_push`; bridge registration
   and delivery against a fake distributor.~~ Done: `nix develop -c pytest
   tests`, Prosody 13.0.6 (same nixpkgs as mynix), slixmpp as distributor and
   publisher.
2. ~~Catch-up, gap handling and triggers; tests for cursor logic.~~ Done for
   reconnect (new session), retry/backoff, gaps, renewal, restart, unregister,
   truncation. Not yet covered: smacks resume (`smacks-hibernation-end`),
   expiry of stale registrations.
3. Android app; end-to-end on the phone against the harness.
4. Deploy to liver; move `kago-notify` onto it.
5. signi Discord forwarder.
6. Send the `mod_unified_push` patch upstream.
