"""Print recent messages from <jid> in ada@6bit.com's MAM archive.
Usage: python read_mam.py josh@6bit.com [minutes=60]"""
import asyncio
import datetime
import sys

import slixmpp

with_jid = sys.argv[1]
minutes = int(sys.argv[2]) if len(sys.argv) > 2 else 60


class Reader(slixmpp.ClientXMPP):
    def __init__(self, password):
        super().__init__("ada@6bit.com/mam-read", password)
        self.register_plugin("xep_0313")
        self.ready = asyncio.Event()
        self.add_event_handler("session_start", lambda _: self.ready.set())


async def main():
    c = Reader(open("/run/secrets/ada/email-password").read().strip())
    c.connect()
    await asyncio.wait_for(c.ready.wait(), 20)
    start = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(minutes=minutes)
    async for rsm in c["xep_0313"].iterate(with_jid=slixmpp.JID(with_jid), start=start, total=200):
        fwd = rsm["mam_result"]["forwarded"]
        msg = fwd["stanza"]
        if msg["body"]:
            print(f"--- {fwd['delay']['stamp']} {msg['from'].bare} -> {msg['to'].bare}")
            print(msg["body"])
    c.disconnect()


asyncio.run(main())
