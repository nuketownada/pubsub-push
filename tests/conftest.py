"""Throwaway Prosody with mod_unified_push + mod_pubsub_unified_push.

Each test gets a fresh server: VirtualHost "localhost" (users josh, kago,
mallory) and a pubsub component "notify.localhost" with nodes:
  kago   publisher kago@,  member josh@, max_items 3
  secret publisher kago@,  no members (josh may not register for it)
"""
import asyncio
import json
import os
import socket
import subprocess
import time
import urllib.error
import urllib.request
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
PASSWORD = "password"

CONFIG = """
pidfile = "{dir}/prosody.pid"
data_path = "{dir}/data"
plugin_paths = {{ "{repo}/prosody" }}
log = {{ debug = "{dir}/prosody.log" }}

c2s_ports = {{ {c2s} }}
c2s_interfaces = {{ "127.0.0.1" }}
http_ports = {{ {http} }}
http_interfaces = {{ "127.0.0.1" }}
https_ports = {{}}
http_external_url = "http://localhost:{http}/"

authentication = "internal_hashed"
c2s_require_encryption = false
allow_unencrypted_plain_auth = true

modules_enabled = {{
  "roster"; "saslauth"; "disco"; "ping"; "smacks"; "http";
  "pubsub_unified_push";
}}
modules_disabled = {{ "s2s"; "tls" }}

pubsub_unified_push_service = "notify.localhost"
pubsub_unified_push_retry_interval = 2
pubsub_unified_push_reconnect_delay = 0.5
pubsub_unified_push_nodes = {{
  kago = {{ publishers = {{ "kago@localhost" }}, members = {{ "josh@localhost" }}, max_items = 3 }};
  secret = {{ publishers = {{ "kago@localhost" }} }};
}}

VirtualHost "localhost"

Component "notify.localhost" "pubsub"
"""


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_port(port, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            socket.create_connection(("127.0.0.1", port), 0.2).close()
            return
        except OSError:
            time.sleep(0.05)
    raise TimeoutError(f"port {port} not listening")


class Server:
    def __init__(self, tmp):
        self.dir = tmp
        self.c2s, self.http = free_port(), free_port()
        self.cfg = tmp / "prosody.cfg.lua"
        (tmp / "data").mkdir()
        self.cfg.write_text(CONFIG.format(dir=tmp, repo=REPO, c2s=self.c2s, http=self.http))
        for user in ("josh", "kago", "mallory"):
            subprocess.run(["prosodyctl", "--config", str(self.cfg), "register", user, "localhost", PASSWORD],
                           check=True, capture_output=True)
        self.start()

    def start(self):
        self.proc = subprocess.Popen(["prosody", "--config", str(self.cfg), "-F"],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
        wait_port(self.c2s)
        wait_port(self.http)

    def stop(self):
        self.proc.terminate()
        self.proc.wait(10)

    def log(self):
        return (self.dir / "prosody.log").read_text()

    def log_size(self):
        return (self.dir / "prosody.log").stat().st_size

    async def wait_log(self, needle, since=0, timeout=10):
        deadline = time.time() + timeout
        while time.time() < deadline:
            with open(self.dir / "prosody.log", errors="replace") as f:
                f.seek(since)
                if needle in f.read():
                    return
            await asyncio.sleep(0.05)
        raise TimeoutError(f"{needle!r} not in prosody log")

    def http_json(self, method, path, body):
        req = urllib.request.Request(f"http://localhost:{self.http}{path}", method=method,
                                     data=json.dumps(body).encode(),
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                data = r.read()
                return r.status, json.loads(data) if data else None
        except urllib.error.HTTPError as e:
            return e.code, None


@pytest.fixture
def server(tmp_path):
    s = Server(tmp_path)
    yield s
    s.stop()
    if os.environ.get("SHOW_PROSODY_LOG"):
        print(s.log())


def run(coro, timeout=30):
    return asyncio.run(asyncio.wait_for(coro, timeout))
