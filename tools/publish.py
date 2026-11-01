"""Publish one item to a topic on notify.6bit.com as ada@6bit.com.
Usage: python publish.py <topic> <title> [body] [url] [priority]"""
import asyncio
import json
import sys
import xml.etree.ElementTree as ET

import slixmpp

topic, title = sys.argv[1], sys.argv[2]
data = {"title": title}
for key, val in zip(("body", "url", "priority"), sys.argv[3:]):
    if val:
        data[key] = val


class Pub(slixmpp.ClientXMPP):
    def __init__(self, password):
        super().__init__("ada@6bit.com/publish", password)
        self.register_plugin("xep_0060")
        self.ready = asyncio.Event()
        self.add_event_handler("session_start", lambda _: self.ready.set())


async def main():
    c = Pub(open("/run/secrets/ada/email-password").read().strip())
    c.connect()
    await asyncio.wait_for(c.ready.wait(), 20)
    el = ET.Element("{urn:xmpp:json:0}json")
    el.text = json.dumps(data)
    res = await c["xep_0060"].publish("notify.6bit.com", topic, payload=el)
    print("published", res["pubsub"]["publish"]["item"]["id"])
    c.disconnect()


asyncio.run(main())
