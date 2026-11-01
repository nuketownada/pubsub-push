"""Publish a notification to a pubsub-push topic.

Exits 0 only once the pubsub service has accepted the item, so callers can
fall back to something else on failure: 1 timeout/connection, 2 auth,
3 publish refused (e.g. not a publisher of the topic).

  pubsub-publish --jid kago@6bit.com --password-file /run/secrets/pw \\
      --service notify.6bit.com --topic kago --priority high \\
      --url https://kago.local:9090/ "md array degraded" - < /proc/mdstat
"""
import argparse
import asyncio
import json
import logging
import sys
import xml.etree.ElementTree as ET

import slixmpp
from slixmpp.exceptions import IqError, IqTimeout

JSON_NS = "urn:xmpp:json:0"


class Publisher(slixmpp.ClientXMPP):
    def __init__(self, args, item):
        with open(args.password_file) as f:
            super().__init__(args.jid, f.read().strip())
        self.args, self.item = args, item
        self.result = None
        self.register_plugin("xep_0060")
        if args.plaintext:
            self.enable_plaintext = True
            self.enable_starttls = False
            self.enable_direct_tls = False
            self["feature_mechanisms"].unencrypted_plain = True
        self.add_event_handler("session_start", self._publish)
        self.add_event_handler("failed_auth", self._failed_auth)

    async def _publish(self, _):
        el = ET.Element(f"{{{JSON_NS}}}json")
        el.text = json.dumps(self.item)
        try:
            await self["xep_0060"].publish(self.args.service, self.args.topic,
                                           payload=el, timeout=self.args.timeout)
            self.result = 0
        except IqError as e:
            print(f"publish refused: {e.condition} {e.text or ''}".strip(), file=sys.stderr)
            self.result = 3
        except IqTimeout:
            print("publish timed out", file=sys.stderr)
            self.result = 1
        self.disconnect()

    def _failed_auth(self, _):
        print("authentication failed", file=sys.stderr)
        self.result = 2
        self.disconnect()


def parse_args(argv):
    p = argparse.ArgumentParser(prog="pubsub-publish", description=__doc__.split("\n\n")[0])
    p.add_argument("--jid", required=True)
    p.add_argument("--password-file", required=True)
    p.add_argument("--service", required=True, help="pubsub service, e.g. notify.6bit.com")
    p.add_argument("--topic", required=True)
    p.add_argument("--priority", choices=["low", "default", "high"])
    p.add_argument("--url", help="opened when the notification is tapped")
    p.add_argument("--group", help="notification group (default: the topic)")
    p.add_argument("--timeout", type=float, default=30)
    p.add_argument("--server", help="host:port to connect to instead of DNS lookup")
    p.add_argument("--plaintext", action="store_true", help="no TLS (local test servers only)")
    p.add_argument("title")
    p.add_argument("body", nargs="?", help="'-' reads it from stdin")
    return p.parse_args(argv)


async def run(args):
    body = sys.stdin.read() if args.body == "-" else args.body
    item = {"title": args.title}
    for key, val in (("body", body), ("url", args.url), ("priority", args.priority), ("group", args.group)):
        if val:
            item[key] = val
    client = Publisher(args, item)
    if args.server:
        host, _, port = args.server.rpartition(":")
        client.connect(host, int(port))
    else:
        client.connect()
    try:
        await asyncio.wait_for(client.disconnected, args.timeout + 15)
    except asyncio.TimeoutError:
        print("timed out", file=sys.stderr)
        return 1
    return 1 if client.result is None else client.result


def main(argv=None):
    logging.basicConfig(level=logging.CRITICAL)
    return asyncio.run(run(parse_args(sys.argv[1:] if argv is None else argv)))


if __name__ == "__main__":
    sys.exit(main())
