/*
 * PubsubPush, Electron main-process side: decides whether to forward (e.g.
 * only while the screen is locked) and runs pubsub-publish.
 *
 * Config, written by the system config (home-manager):
 *   $XDG_CONFIG_HOME/pubsub-push/discord.json
 *   {
 *     "publish": ["/nix/store/…/pubsub-publish", "--jid", "…", "--password-file", "…",
 *                 "--service", "notify.6bit.com", "--topic", "signi-discord"],
 *     "forwardIf": ["/nix/store/…/pgrep", "-xu", "josh", "i3lock-color"]   (optional)
 *   }
 * forwardIf runs first; the item is published only if it exits 0. Clears
 * (the channel was read) always go out: they only follow a forwarded item.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { execFile } from "child_process";
import { appendFileSync, mkdirSync, readFileSync } from "fs";
import { homedir } from "os";
import { join } from "path";

interface Config {
    publish: string[];
    forwardIf?: string[];
}

interface Item {
    title: string;
    sender: string;
    body: string;
    url: string;
    group: string;
    icon?: string;
    image?: string;
    groupIcon?: string;
}

const configPath = join(process.env.XDG_CONFIG_HOME || join(homedir(), ".config"), "pubsub-push", "discord.json");
const logDir = join(process.env.XDG_STATE_HOME || join(homedir(), ".local", "state"), "pubsub-push");

/** Appends to $XDG_STATE_HOME/pubsub-push/discord.log: what was forwarded and cleared, and why. */
export function log(_: unknown, line: string) {
    try {
        mkdirSync(logDir, { recursive: true });
        appendFileSync(join(logDir, "discord.log"), `${new Date().toISOString()} ${line}\n`);
    } catch { }
}

function run(argv: string[], timeout: number): Promise<number> {
    return new Promise(resolve => {
        execFile(argv[0], argv.slice(1), { timeout }, err => {
            if (!err) return resolve(0);
            const code = (err as NodeJS.ErrnoException & { code?: unknown; }).code;
            resolve(typeof code === "number" ? code : 1);
        });
    });
}

function readConfig(): Config | null {
    try {
        return JSON.parse(readFileSync(configPath, "utf8"));
    } catch (e) {
        return null;
    }
}

export async function publish(_: unknown, item: Item): Promise<string> {
    const config = readConfig();
    if (!config) return `not forwarding: no config at ${configPath}`;
    if (config.forwardIf && await run(config.forwardIf, 5_000) !== 0)
        return "not forwarding: condition not met";
    const optional = ([["icon", "--icon"], ["image", "--image"], ["groupIcon", "--group-icon"]] as const)
        .flatMap(([k, flag]) => item[k] ? [flag, item[k]!] : []);
    const code = await run([
        ...config.publish,
        "--url", item.url, "--group", item.group, "--sender", item.sender, ...optional,
        "--", item.title, item.body,
    ], 60_000);
    return code === 0 ? "published" : `pubsub-publish exited ${code}`;
}

export async function clear(_: unknown, group: string): Promise<string> {
    const config = readConfig();
    if (!config) return `not clearing: no config at ${configPath}`;
    const code = await run([...config.publish, "--clear", "--group", group], 60_000);
    return code === 0 ? "cleared" : `pubsub-publish exited ${code}`;
}
