import asyncio

import pytest
from slixmpp.exceptions import IqError

from clients import Distributor, Publisher
from conftest import run


async def setup(server, topics=("kago",)):
    phone = await Distributor(server).online()
    endpoint = await phone.register_up()
    status, body = server.http_json("POST", "/pubsub_push/register",
                                    {"endpoint": endpoint, "topics": list(topics)})
    assert status == 200, status
    kago = await Publisher(server, "kago").online()
    return phone, kago, endpoint, body


def test_registration_topic_results(server):
    async def t():
        phone, kago, _, body = await setup(server, ["kago", "secret", "nope"])
        assert body["topics"] == {"kago": "ok", "secret": "forbidden", "nope": "item-not-found"}
    run(t())


def test_bad_endpoints_rejected(server):
    assert server.http_json("POST", "/pubsub_push/register", {"endpoint": "x", "topics": []})[0] == 400
    assert server.http_json("POST", "/pubsub_push/register",
                            {"endpoint": "http://localhost/push/forged", "topics": ["kago"]})[0] == 403


def test_publish_is_pushed(server):
    async def t():
        phone, kago, _, _ = await setup(server)
        await kago.publish("kago", {"title": "md array degraded", "body": "[UU_]", "url": "https://kago.local:9090/"})
        p = await phone.next_push()
        assert p["topic"] == "kago" and p["title"] == "md array degraded"
        assert p["body"] == "[UU_]" and p["url"] == "https://kago.local:9090/" and p["id"]
        await phone.no_push()
    run(t())


def test_no_history_replay_on_register(server):
    async def t():
        kago = await Publisher(server, "kago").online()
        await kago.publish("kago", {"title": "old"})
        phone = await Distributor(server).online()
        endpoint = await phone.register_up()
        server.http_json("POST", "/pubsub_push/register", {"endpoint": endpoint, "topics": ["kago"]})
        await phone.no_push()
        await kago.publish("kago", {"title": "new"})
        assert (await phone.next_push())["title"] == "new"
    run(t())


def test_only_publishers_may_publish(server):
    async def t():
        mallory = await Publisher(server, "mallory").online()
        with pytest.raises(IqError):
            await mallory.publish("kago", {"title": "spoofed"})
    run(t())


def test_offline_then_catch_up_in_order(server):
    async def t():
        phone, kago, _, _ = await setup(server)
        await phone.offline()
        for n in (1, 2):
            await kago.publish("kago", {"title": f"n{n}"})
        phone2 = await Distributor(server).online()  # same resource, new session
        assert [(await phone2.next_push())["title"] for _ in range(2)] == ["n1", "n2"]
        await phone2.no_push()
    run(t())


def test_rejected_push_retried(server):
    async def t():
        phone, kago, _, _ = await setup(server)
        phone.reply = "internal-server-error"
        await kago.publish("kago", {"title": "retry me"})
        await asyncio.sleep(1)
        phone.reply = "result"
        # retry timer (2s, then backoff 2s) picks it up
        assert (await phone.next_push(10))["title"] == "retry me"
        await phone.no_push()
    run(t())


def test_gap_notice_when_retention_exceeded(server):
    async def t():
        phone, kago, _, _ = await setup(server)
        await phone.offline()
        for n in range(1, 6):  # max_items = 3
            await kago.publish("kago", {"title": f"n{n}"})
        phone2 = await Distributor(server).online()
        first = await phone2.next_push()
        assert first == {"topic": "kago", "gap": True}
        assert [(await phone2.next_push())["title"] for _ in range(3)] == ["n3", "n4", "n5"]
        await phone2.no_push()
    run(t())


def test_renewal_keeps_cursor(server):
    async def t():
        phone, kago, endpoint, _ = await setup(server)
        await kago.publish("kago", {"title": "a"})
        await phone.next_push()
        endpoint2 = await phone.register_up()
        assert endpoint2 != endpoint
        assert server.http_json("POST", "/pubsub_push/register",
                                {"endpoint": endpoint2, "topics": ["kago"]})[0] == 200
        await phone.no_push()  # "a" not redelivered
        await kago.publish("kago", {"title": "b"})
        assert (await phone.next_push())["title"] == "b"
    run(t())


def test_registrations_survive_restart(server):
    async def t1():
        phone, kago, _, _ = await setup(server)
        await kago.publish("kago", {"title": "before"})
        await phone.next_push()
        await phone.offline()
        await kago.offline()
    run(t1())
    server.stop()
    server.start()

    async def t2():
        kago = await Publisher(server, "kago").online()
        await kago.publish("kago", {"title": "after"})
        phone = await Distributor(server).online()
        assert (await phone.next_push())["title"] == "after"
        await phone.no_push()
    run(t2())


def test_unregister(server):
    async def t():
        phone, kago, endpoint, _ = await setup(server)
        assert server.http_json("DELETE", "/pubsub_push/register", {"endpoint": endpoint})[0] == 204
        await kago.publish("kago", {"title": "x"})
        await phone.no_push()
    run(t())


def test_long_body_truncated_to_fit(server):
    async def t():
        phone, kago, _, _ = await setup(server)
        await kago.publish("kago", {"title": "big", "body": "é" * 5000})
        p = await phone.next_push()
        assert p["body"].endswith("…") and len(p["body"].encode()) < 4096
    run(t())


def test_chat_fields_passed(server):
    async def t():
        phone, kago, _, _ = await setup(server)
        await kago.publish("kago", {"title": "#general (srv)", "body": "hi", "group": "123", "sender": "bob",
                                    "icon": "https://cdn/a.png", "image": "https://cdn/i.png"})
        p = await phone.next_push()
        assert (p["group"], p["sender"], p["icon"], p["image"]) == ("123", "bob", "https://cdn/a.png", "https://cdn/i.png")
        assert "clear" not in p
        await kago.publish("kago", {"clear": True, "group": "123"})
        p = await phone.next_push()
        assert p["clear"] is True and p["group"] == "123"
    run(t())


def test_catch_up_after_timeout_and_smacks_resume(server_slow_retry):
    """Airplane mode with Conversations: the session hibernates, the push
    times out (unified_push_timeout = 2), then the client resumes. Catch-up
    must come from the resume hook (retry timer is 120s here); the timed-out
    push is also replayed by smacks, so expect it twice and both items."""
    server = server_slow_retry

    async def t():
        phone = await Distributor(server, smacks=True).online()
        endpoint = await phone.register_up()
        server.http_json("POST", "/pubsub_push/register", {"endpoint": endpoint, "topics": ["kago"]})
        kago = await Publisher(server, "kago").online()
        await phone.drop()
        mark = server.log_size()
        await kago.publish("kago", {"title": "off1"})
        await kago.publish("kago", {"title": "off2"})
        await server.wait_log("failed (500)", mark)
        await phone.resume()
        titles = [(await phone.next_push(8))["title"] for _ in range(3)]
        # smacks replays off1; the bridge then redelivers off1 (the app
        # de-duplicates on id) and delivers off2.
        assert titles.count("off1") == 2 and titles[-1] == "off2", titles
        await phone.no_push()
    run(t())


def test_pubsub_publish_cli(server, tmp_path):
    """tools/pubsub_publish.py: delivered on success, exit codes on failure."""
    import subprocess
    import sys
    import urllib.request
    from conftest import PASSWORD, REPO

    pw = tmp_path / "pw"
    pw.write_text(PASSWORD + "\n")
    bad = tmp_path / "bad"
    bad.write_text("wrong\n")

    def cli(user, pwfile, topic, *extra, stdin=None):
        return subprocess.run(
            [sys.executable, str(REPO / "tools/pubsub_publish.py"), "--jid", f"{user}@localhost",
             "--password-file", str(pwfile), "--service", "notify.localhost", "--topic", topic,
             "--server", f"127.0.0.1:{server.c2s}", "--plaintext", "--timeout", "5", *extra],
            input=stdin, capture_output=True, text=True, timeout=60)

    async def t():
        phone, kago, _, _ = await setup(server)
        r = await asyncio.to_thread(cli, "kago", pw, "kago", "--priority", "high",
                                    "--url", "https://kago.local:9090/", "md array degraded", "-",
                                    stdin="[UU_]\n")
        assert r.returncode == 0, r.stderr
        p = await phone.next_push()
        assert (p["title"], p["body"], p["priority"], p["url"]) == \
            ("md array degraded", "[UU_]\n", "high", "https://kago.local:9090/")
        img = tmp_path / "graph.png"
        img.write_bytes(b"\x89PNG fake")
        r = await asyncio.to_thread(cli, "kago", pw, "kago", "--image", str(img), "--sender", "kago",
                                    "--group", "md", "with picture")
        assert r.returncode == 0, r.stderr
        p = await phone.next_push()
        assert p["sender"] == "kago" and p["image"].startswith("http://localhost:"), p
        get = urllib.request.Request(p["image"].replace("localhost", "127.0.0.1", 1), headers={"Host": "localhost"})
        with urllib.request.urlopen(get) as resp:
            assert resp.read() == b"\x89PNG fake"
        r = await asyncio.to_thread(cli, "kago", pw, "kago", "--clear", "--group", "md")
        assert r.returncode == 0, r.stderr
        assert (await phone.next_push())["clear"] is True
        r = await asyncio.to_thread(cli, "mallory", pw, "kago", "spoofed")
        assert r.returncode == 3, (r.returncode, r.stderr)
        r = await asyncio.to_thread(cli, "kago", bad, "kago", "x")
        assert r.returncode == 2, (r.returncode, r.stderr)
        await phone.no_push()
    run(t())
