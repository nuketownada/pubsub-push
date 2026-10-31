"""slixmpp clients: a fake UnifiedPush distributor (what Conversations does)
and a pubsub publisher (what kago-notify will do)."""
import asyncio
import base64
import hashlib
import json
import logging
import xml.etree.ElementTree as ET

import slixmpp
from slixmpp.xmlstream import ElementBase, register_stanza_plugin
from slixmpp.xmlstream.handler import Callback
from slixmpp.xmlstream.matcher import MatchXPath
from slixmpp.stanza import Iq

from conftest import PASSWORD

UP_NS = "http://gultsch.de/xmpp/drafts/unified-push"
JSON_NS = "urn:xmpp:json:0"

logging.getLogger("slixmpp").setLevel(logging.WARNING)


def h(s):
    return base64.b64encode(hashlib.sha256(s.encode()).digest()).decode()


class Client(slixmpp.ClientXMPP):
    def __init__(self, server, user, resource="test"):
        super().__init__(f"{user}@localhost/{resource}", PASSWORD)
        self.srv = server
        self.enable_plaintext = True
        self.enable_starttls = False
        self.enable_direct_tls = False
        self["feature_mechanisms"].unencrypted_plain = True
        self.register_plugin("xep_0060")
        self.ready = asyncio.Event()
        self.reply = "result"
        self.add_event_handler("session_start", self._start)

    async def _start(self, _):
        self.send_presence()
        self.ready.set()

    async def online(self):
        self.connect("127.0.0.1", self.srv.c2s)
        await asyncio.wait_for(self.ready.wait(), 10)
        return self

    async def offline(self):
        # Anything arriving while the stream closes gets what an unreachable
        # device would produce.
        self.reply = "recipient-unavailable"
        mark = self.srv.log_size()
        await self.disconnect()
        await self.srv.wait_log(f"Unbinding resource for {self.boundjid.full}", mark)


class Distributor(Client):
    """Registers like Conversations and receives push iqs.

    reply: "result" to acknowledge, or an error condition to reject."""

    def __init__(self, server, user="josh", resource="Conversations.test", app="io.example.notify"):
        super().__init__(server, user, resource)
        self.application, self.instance = h(app), h("default")
        self.pushes = asyncio.Queue()
        self.reply = "result"
        self.register_handler(Callback("up push", MatchXPath(f"{{jabber:client}}iq/{{{UP_NS}}}push"), self._push))

    def _push(self, iq):
        el = iq.xml.find(f"{{{UP_NS}}}push")
        if self.reply == "result":
            iq.reply().send()
            self.pushes.put_nowait(json.loads(base64.b64decode(el.text)))
        else:
            r = iq.reply(clear=True)  # in place: call once
            r["type"] = "error"
            r["error"]["type"] = "cancel"
            r["error"]["condition"] = self.reply
            r.send()

    async def register_up(self):
        iq = self.Iq(stype="set", sto="localhost")
        reg = ET.Element(f"{{{UP_NS}}}register", application=self.application, instance=self.instance)
        iq.append(reg)
        res = await iq.send()
        return res.xml.find(f"{{{UP_NS}}}registered").get("endpoint")

    async def next_push(self, timeout=10):
        return await asyncio.wait_for(self.pushes.get(), timeout)

    async def no_push(self, wait=1.5):
        try:
            p = await asyncio.wait_for(self.pushes.get(), wait)
        except asyncio.TimeoutError:
            return
        raise AssertionError(f"unexpected push {p}")


class Publisher(Client):
    async def publish(self, node, data, item_id=None):
        el = ET.Element(f"{{{JSON_NS}}}json")
        el.text = json.dumps(data)
        return await self["xep_0060"].publish("notify.localhost", node, id=item_id, payload=el)
