"""Publish a notification to a pubsub-push topic.

Exits 0 only once the pubsub service has accepted the item, so callers can
fall back to something else on failure: 1 timeout/connection, 2 auth,
3 publish refused (e.g. not a publisher of the topic), 4 upload failed.

  pubsub-publish --jid kago@6bit.com --password-file /run/secrets/pw \\
      --service notify.6bit.com --topic kago --priority high \\
      --url https://kago.local:9090/ "md array degraded" - < /proc/mdstat

--image, --icon and --group-icon take a URL, or a local file, which is first uploaded with
XEP-0363 HTTP upload on the publishing account's server (--upload-service) and
replaced by its download URL. Chat-style items set --sender and --group (the
conversation); --clear --group G removes that conversation's notification.
"""
import argparse
import asyncio
import json
import logging
import mimetypes
import os
import sys
import urllib.request
import xml.etree.ElementTree as ET

import slixmpp
from slixmpp.exceptions import IqError, IqTimeout

JSON_NS = "urn:xmpp:json:0"
UPLOAD_NS = "urn:xmpp:http:upload:0"


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

    async def _upload(self, path):
        """XEP-0363: request a slot, PUT the file, return the GET URL."""
        size = os.path.getsize(path)
        ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
        iq = self.Iq(stype="get", sto=self.args.upload_service or self.boundjid.domain)
        iq.append(ET.Element(f"{{{UPLOAD_NS}}}request", filename=os.path.basename(path),
                             size=str(size), **{"content-type": ctype}))
        slot = (await iq.send(timeout=self.args.timeout)).xml.find(f"{{{UPLOAD_NS}}}slot")
        put = slot.find(f"{{{UPLOAD_NS}}}put")
        headers = {h.get("name"): h.text for h in put.findall(f"{{{UPLOAD_NS}}}header")}
        headers.update({"Content-Type": ctype, "Content-Length": str(size)})

        def do_put():
            with open(path, "rb") as f:
                req = urllib.request.Request(put.get("url"), data=f.read(), method="PUT", headers=headers)
                urllib.request.urlopen(req, timeout=self.args.timeout).close()
        await asyncio.get_running_loop().run_in_executor(None, do_put)
        return slot.find(f"{{{UPLOAD_NS}}}get").get("url")

    async def _publish(self, _):
        for key in ("image", "icon", "group_icon"):
            path = self.item.get(key)
            if path and not path.startswith(("https://", "http://")):
                try:
                    self.item[key] = await self._upload(path)
                except (OSError, IqError, IqTimeout, AttributeError) as e:
                    print(f"upload of {path} failed: {e}", file=sys.stderr)
                    self.result = 4
                    self.disconnect()
                    return
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
    p.add_argument("--group", help="notification group or chat conversation (default: the topic)")
    p.add_argument("--sender", help="chat style: who said it; messages with the same --group stack up")
    p.add_argument("--icon", help="large icon (e.g. the sender's avatar): URL or file to upload")
    p.add_argument("--image", help="picture to show: URL or file to upload")
    p.add_argument("--group-icon", help="chat style: the conversation's icon (e.g. a server's): URL or file")
    p.add_argument("--clear", action="store_true", help="remove --group's notification instead")
    p.add_argument("--upload-service", help="XEP-0363 upload service (default: the account's server)")
    p.add_argument("--timeout", type=float, default=30)
    p.add_argument("--server", help="host:port to connect to instead of DNS lookup")
    p.add_argument("--plaintext", action="store_true", help="no TLS (local test servers only)")
    p.add_argument("title", nargs="?")
    p.add_argument("body", nargs="?", help="'-' reads it from stdin")
    args = p.parse_args(argv)
    if args.clear and not args.group:
        p.error("--clear needs --group")
    if not args.clear and args.title is None:
        p.error("a title is required")
    return args


async def run(args):
    body = sys.stdin.read() if args.body == "-" else args.body
    if args.clear:
        item = {"clear": True, "group": args.group}
    else:
        item = {"title": args.title}
        for key, val in (("body", body), ("url", args.url), ("priority", args.priority), ("group", args.group),
                         ("sender", args.sender), ("icon", args.icon), ("image", args.image),
                         ("group_icon", args.group_icon)):
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
