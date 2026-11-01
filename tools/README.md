# tools

Small slixmpp scripts used while developing against liver, run from the
default devShell (`nix develop -c python -I tools/<script>`). They log in as
ada@6bit.com with the password from `/run/secrets/ada/email-password`
(ada's nuketown secret on signi).

- `publish.py <topic> <title> [body] [url] [priority]` — publish an item to a
  topic on notify.6bit.com.
- `send_file.py <path> <jid> [content-type]` — XEP-0363 upload + send as a file
  message (how APKs reach josh's phone; go-sendxmpp can't find liver's upload
  service because it's on the host, not a component).
- `read_mam.py <jid> [minutes]` — print recent messages with <jid> from ada's
  archive (e.g. crash traces pasted in Conversations).
- `live_test.py` — end-to-end check of the bridge on liver with a fake
  distributor as ada@ (`test` topic), cleaning up after itself.
