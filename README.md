# pubsub-push

Push notifications to your phone from your own machines, over the XMPP
connection your phone already keeps open.

```
 servers, desktops ──XMPP publish──► pubsub topic ──► bridge ──► Conversations ──► Push Topics app
 webhooks ─────HTTP (optional)─────► (Prosody)        (Prosody)   (UnifiedPush       (notification,
                                                                    distributor)       tap → URL)
```

- **No extra connection or Google services on the phone.** Conversations is
  the [UnifiedPush](https://unifiedpush.org) distributor; works on GrapheneOS
  without Play.
- **Store and forward.** Topics are XMPP pubsub nodes; a phone that was
  offline gets what it missed, in order, when it reconnects (or a "some were
  missed" notice past a topic's retention).
- **Publishers are XMPP accounts.** A machine publishes as its own JID;
  topic ACLs say who may publish and whose devices may subscribe.
- **Per-topic Android channels.** Each topic (and priority) is its own
  notification channel, so popups, sound and DND are set per topic in
  Android's settings. Tapping opens the item's URL in whichever app owns it.

Design and the reasoning behind it: [docs/design.md](docs/design.md).

## Pieces

| | Where | What |
|---|---|---|
| Prosody modules | `prosody/` | `mod_pubsub_unified_push` (the bridge) and a patched `mod_unified_push` (fixes: offline pushes were reported delivered and lost; error results crashed) |
| NixOS module | `nixosModules.prosody` | `services.pubsub-push.prosody`: adds both to an existing `services.prosody`, plus the topics |
| Publisher | `packages.*.pubsub-publish` | `pubsub-publish --topic … "title" "body"`; exits 0 only once accepted |
| Android app | `android/` | Push Topics: registers topics with the bridge, shows notifications |
| Discord | `homeManagerModules.discord` | Discord + Vencord with the `PubsubPush` plugin: forwards what Discord would notify, with links to the exact message |
| Overlay | `overlays.default` | all the packages, built from your package set |

## Using it (Nix flakes)

```nix
inputs.pubsub-push = {
  url = "github:nuketownada/pubsub-push";
  inputs.nixpkgs.follows = "nixpkgs";   # build against your nixpkgs
};
```

Following your nixpkgs means you'll occasionally hit breakage (Vencord and
Discord move fast); pin `pubsub-push` to a revision you know works if that
matters more to you.

### Server: Prosody

You need a working `services.prosody` whose users run Conversations.

```nix
imports = [ inputs.pubsub-push.nixosModules.prosody ];

services.pubsub-push.prosody = {
  enable = true;
  service = "notify.example.com";       # pubsub component; local only, no DNS needed
  topics = {
    server = { publishers = [ "server@example.com" ]; members = [ "me@example.com" ]; };
    discord = { publishers = [ "desktop@example.com" ]; members = [ "me@example.com" ]; };
  };
};

# Prosody must serve HTTP (pushes and app registrations), at
# http_external_url. Behind a reverse proxy that forwards a Host header that
# isn't one of Prosody's hosts, also set http_default_host to the user host,
# or every HTTP route answers "Unknown host" 404:
services.prosody.extraConfig = ''
  http_external_url = "https://xmpp.example.com/"
  http_default_host = "example.com"
'';
```

Don't also list `unified_push` in the Prosody package's
`withCommunityModules`; the module brings the patched one (it asserts this).

### Phone

1. Conversations: Settings → UnifiedPush Distributor → your account, and
   push server = your XMPP domain (e.g. `example.com`, not a hostname).
2. Install Push Topics (`android/`, see Development), enter topics one per
   line, tap Save and register. Status shows the result per topic.

### Publishing

```sh
pubsub-publish --jid server@example.com --password-file /run/secrets/xmpp \
  --service notify.example.com --topic server \
  --priority high --url https://grafana.example.com/ \
  "disk failing" - < smartctl-report.txt
```

`--priority`: `low` (silent), `default`, `high` (pops up). Exit codes: 0
accepted, 1 timeout or connection, 2 auth, 3 refused (e.g. not a publisher).
Over HTTP instead, enable prosody-modules' `mod_pubsub_post` on the
component; send JSON `{"id", "title", "body", "url", "priority"}` and always
a unique `id` (without one it overwrites a single item).

### Discord → phone (home-manager)

```nix
imports = [ inputs.pubsub-push.homeManagerModules.discord ];

programs.pubsub-push.discord = {
  enable = true;
  jid = "desktop@example.com";
  passwordFile = "/run/secrets/xmpp";   # readable by you
  service = "notify.example.com";
  topic = "discord";
  # Optional: only forward while the screen is locked.
  forwardIf = [ "${pkgs.procps}/bin/pgrep" "-xu" "me" "i3lock" ];
};
```

Installs Discord (unfree: allow `discord`) running Vencord with the
PubsubPush plugin, which hooks Discord's own should-notify check, so your
mutes and notification settings decide. Tapping the notification opens
Discord at that message (on Android, enable Discord's links: Settings →
Apps → Discord → Open by default → Add link).

Caveats: client mods are against Discord's terms (rarely enforced against
Vencord, but not zero risk); Discord updates its code at runtime, and a
change can break the plugin's hook until Vencord catches up.

## Development

- Tests (throwaway Prosody, slixmpp as distributor and publisher):
  `nix develop -c bash -c 'cd tests && python -m pytest'`
- Lint the bridge: `nix run .#luacheck -- --std lua52 --globals module prosody prosody/`
- App: `nix develop .#android -c gradle -p android assembleDebug`. Signing:
  `restore-signing-key` (sops, for the maintainers) or use your own key at
  `android/signing/pubsub-push.keystore`; without one Gradle's debug key is
  used.
- `tools/`: scripts for poking a live deployment (`tools/README.md`).

## License

`prosody/mod_unified_push` is from
[prosody-modules](https://hg.prosody.im/prosody-modules) (MIT, see its
`COPYING`). The Vencord plugin is GPL-3.0-or-later, like Vencord.
