"""Send a file to a JID via XEP-0363 HTTP upload on 6bit.com, as ada@6bit.com.
Usage: python send_file.py <path> <to-jid> [content-type]"""
import asyncio
import os
import sys
import urllib.request
import xml.etree.ElementTree as ET

import slixmpp

UPLOAD_NS = "urn:xmpp:http:upload:0"
OOB_NS = "jabber:x:oob"

path, to = sys.argv[1], sys.argv[2]
ctype = sys.argv[3] if len(sys.argv) > 3 else "application/octet-stream"


class Sender(slixmpp.ClientXMPP):
    def __init__(self, password):
        super().__init__("ada@6bit.com/file-send", password)
        self.ready = asyncio.Event()
        self.add_event_handler("session_start", lambda _: self.ready.set())


async def main():
    c = Sender(open("/run/secrets/ada/email-password").read().strip())
    c.connect()
    await asyncio.wait_for(c.ready.wait(), 20)

    size = os.path.getsize(path)
    iq = c.Iq(stype="get", sto="6bit.com")
    iq.append(ET.Element(f"{{{UPLOAD_NS}}}request", filename=os.path.basename(path),
                         size=str(size), **{"content-type": ctype}))
    slot = (await iq.send(timeout=20)).xml.find(f"{{{UPLOAD_NS}}}slot")
    put = slot.find(f"{{{UPLOAD_NS}}}put")
    get_url = slot.find(f"{{{UPLOAD_NS}}}get").get("url")
    headers = {h.get("name"): h.text for h in put.findall(f"{{{UPLOAD_NS}}}header")}
    headers.update({"Content-Type": ctype, "Content-Length": str(size)})

    def do_put():
        with open(path, "rb") as f:
            req = urllib.request.Request(put.get("url"), data=f.read(), method="PUT", headers=headers)
            with urllib.request.urlopen(req, timeout=120) as r:
                return r.status
    print("PUT", await asyncio.get_running_loop().run_in_executor(None, do_put))

    msg = c.make_message(mto=to, mbody=get_url, mtype="chat")
    oob = ET.SubElement(msg.xml, f"{{{OOB_NS}}}x")
    ET.SubElement(oob, f"{{{OOB_NS}}}url").text = get_url
    msg.send()
    await asyncio.sleep(1)
    c.disconnect()
    print("sent", get_url.split("/")[2])


asyncio.run(main())
