"""Live end-to-end test of pubsub-push on liver, as ada@6bit.com.

Fake distributor: registers for UnifiedPush like Conversations, registers
topics with the bridge, publishes to `test`, expects the push. Cleans up its
registration. Usage: python live_test.py
"""
import asyncio
import base64
import hashlib
import json
import logging
import urllib.error
import urllib.request
import uuid
import xml.etree.ElementTree as ET

import slixmpp
from slixmpp.xmlstream.handler import Callback
from slixmpp.xmlstream.matcher import MatchXPath

UP_NS = "http://gultsch.de/xmpp/drafts/unified-push"
JSON_NS = "urn:xmpp:json:0"
BRIDGE = "https://xmpp.6bit.com/pubsub_push/register"
logging.basicConfig(level=logging.WARNING)


def h(s):
    return base64.b64encode(hashlib.sha256(s.encode()).digest()).decode()


def http(method, body):
    req = urllib.request.Request(BRIDGE, method=method, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            data = r.read()
            return r.status, json.loads(data) if data else None
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:200]


class Phone(slixmpp.ClientXMPP):
    def __init__(self, password):
        super().__init__("ada@6bit.com/pubsub-push-livetest", password)
        self.register_plugin("xep_0060")
        self.pushes = asyncio.Queue()
        self.ready = asyncio.Event()
        self.add_event_handler("session_start", lambda _: (self.send_presence(), self.ready.set()))
        self.register_handler(Callback("up", MatchXPath(f"{{jabber:client}}iq/{{{UP_NS}}}push"), self._push))

    def _push(self, iq):
        el = iq.xml.find(f"{{{UP_NS}}}push")
        iq.reply().send()
        self.pushes.put_nowait(json.loads(base64.b64decode(el.text)))


async def main():
    password = open("/run/secrets/ada/email-password").read().strip()
    phone = Phone(password)
    phone.connect()
    await asyncio.wait_for(phone.ready.wait(), 20)
    print("connected as", phone.boundjid.full)

    iq = phone.Iq(stype="set", sto="6bit.com")
    iq.append(ET.Element(f"{{{UP_NS}}}register", application=h("pubsub-push-livetest"), instance=h("default")))
    res = await iq.send(timeout=15)
    endpoint = res.xml.find(f"{{{UP_NS}}}registered").get("endpoint")
    print("UP endpoint:", endpoint.split("/push/")[0] + "/push/…")

    status, body = http("POST", {"endpoint": endpoint, "topics": ["test", "kago", "nope"]})
    print("register:", status, body)
    assert status == 200 and body["topics"] == {"test": "ok", "kago": "forbidden", "nope": "item-not-found"}, body

    marker = str(uuid.uuid4())
    el = ET.Element(f"{{{JSON_NS}}}json")
    el.text = json.dumps({"title": "pubsub-push live test", "body": marker, "url": "https://xmpp.6bit.com/"})
    await phone["xep_0060"].publish("notify.6bit.com", "test", payload=el)
    print("published to test")

    p = await asyncio.wait_for(phone.pushes.get(), 20)
    print("push received:", {k: p[k] for k in ("topic", "title", "url")})
    assert p["topic"] == "test" and p["body"] == marker, p

    # Forged endpoint must be refused.
    print("forged endpoint:", http("POST", {"endpoint": "https://xmpp.6bit.com/push/forged", "topics": ["test"]})[0])

    print("unregister:", http("DELETE", {"endpoint": endpoint})[0])
    phone.disconnect()
    print("OK")


asyncio.run(main())
