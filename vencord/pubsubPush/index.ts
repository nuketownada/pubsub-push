/*
 * PubsubPush: forward the notifications Discord would show to a pubsub-push
 * topic, with a link to the exact message. Modelled on Vencord's XSOverlay
 * plugin: same hook (MESSAGE_CREATE + Discord's own should-notify check, so
 * mutes and notification settings apply).
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Logger } from "@utils/Logger";
import definePlugin, { PluginNative, ReporterTestable } from "@utils/types";
import { findByCodeLazy } from "@webpack";
import { ChannelStore, GuildRoleStore, GuildStore, UserStore } from "@webpack/common";

interface Message {
    id: string;
    channel_id: string;
    content: string;
    author: { id: string; username: string; globalName?: string; global_name?: string; bot?: boolean; };
    attachments: { filename: string; content_type?: string; }[];
    embeds: unknown[];
    sticker_items?: unknown[];
    mention_roles: string[];
    referenced_message?: unknown;
}

const DM = 1;
const GROUP_DM = 3;

const logger = new Logger("PubsubPush");
const discordShouldNotify = findByCodeLazy(".SUPPRESS_NOTIFICATIONS))return!1");
const Native = VencordNative.pluginHelpers.PubsubPush as PluginNative<typeof import("./native")>;

function displayName(user: Message["author"]) {
    return user.globalName || user.global_name || user.username;
}

/** Mentions, roles, channels and custom emoji as text. */
function readable(message: Message, guildId?: string) {
    return message.content
        .replace(/<@!?(\d{17,20})>/g, (_, id) => {
            const user = UserStore.getUser(id);
            return `@${user ? displayName(user as Message["author"]) : "unknown-user"}`;
        })
        .replace(/<@&(\d{17,20})>/g, (_, id) => `@${(guildId && GuildRoleStore.getRole(guildId, id)?.name) || "role"}`)
        .replace(/<#(\d{17,20})>/g, (_, id) => `#${ChannelStore.getChannel(id)?.name ?? "channel"}`)
        .replace(/<a?:(\w+):\d+>/g, ":$1:");
}

function describe(message: Message) {
    const channel = ChannelStore.getChannel(message.channel_id);
    const author = displayName(message.author);
    let title = author;
    if (channel.type === GROUP_DM) {
        const name = channel.name?.trim() || channel.rawRecipients?.map(r => r.username).join(", ");
        title = `${author} (${name})`;
    } else if (channel.type !== DM && channel.guild_id) {
        title = `${author} (${GuildStore.getGuild(channel.guild_id)?.name ?? "server"}, #${channel.name})`;
    }
    if (message.referenced_message) title += " (reply)";

    const parts = [readable(message, channel.guild_id)];
    for (const a of message.attachments)
        parts.push(a.content_type?.startsWith("image") ? `[image: ${a.filename}]` : `[attachment: ${a.filename}]`);
    if (message.embeds.length) parts.push("[embed]");
    if (message.sticker_items?.length) parts.push("[sticker]");

    return {
        title,
        body: parts.filter(Boolean).join(" ").trim(),
        url: `https://discord.com/channels/${channel.guild_id ?? "@me"}/${message.channel_id}/${message.id}`,
        group: message.channel_id,
    };
}

export default definePlugin({
    name: "PubsubPush",
    description: "Forwards Discord notifications to your phone through a pubsub-push topic, with links to the message",
    authors: [{ name: "Ada", id: 0n }],
    enabledByDefault: true,
    reporterTestable: ReporterTestable.None,

    flux: {
        MESSAGE_CREATE({ message, optimistic }: { message: Message; optimistic: boolean; }) {
            if (optimistic) return;
            if (message.author.id === UserStore.getCurrentUser()?.id) return;
            if (!discordShouldNotify(message, message.channel_id)) return;
            let item;
            try {
                item = describe(message);
            } catch (e) {
                logger.error("Couldn't describe message", e);
                return;
            }
            Native.publish(item)
                .then(result => logger.debug(result))
                .catch(e => logger.error("publish failed", e));
        },
    },
});
