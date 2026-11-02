/*
 * PubsubPush: forward the notifications Discord would show to a pubsub-push
 * topic, with a link to the exact message. Modelled on Vencord's XSOverlay
 * plugin: same hook (MESSAGE_CREATE + Discord's own should-notify check, so
 * mutes and notification settings apply). Items are chat-style, grouped by
 * channel; once Discord marks a forwarded channel read (here or on any other
 * client), a clear item removes that channel's notification from the phone.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { Logger } from "@utils/Logger";
import definePlugin, { PluginNative, ReporterTestable } from "@utils/types";
import { findByCodeLazy } from "@webpack";
import { ChannelStore, GuildRoleStore, GuildStore, ReadStateStore, UserStore } from "@webpack/common";

interface Message {
    id: string;
    channel_id: string;
    content: string;
    author: { id: string; username: string; globalName?: string; global_name?: string; bot?: boolean; };
    attachments: { filename: string; url: string; content_type?: string; }[];
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

/** Channels with a notification on the phone → the newest message forwarded. */
const forwarded = new Map<string, string>();

/** Clear the phone's notification for channels read up to what was forwarded. */
function clearRead() {
    for (const [channelId, messageId] of forwarded) {
        const ack = ReadStateStore.ackMessageId(channelId);
        if (!ack || BigInt(ack) < BigInt(messageId)) continue;
        forwarded.delete(channelId);
        Native.clear(channelId)
            .then(result => logger.debug(result))
            .catch(e => logger.error("clear failed", e));
    }
}

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
    // The conversation; a DM's is the other person.
    let title = author;
    if (channel.type === GROUP_DM) {
        title = channel.name?.trim() || channel.rawRecipients?.map(r => r.username).join(", ");
    } else if (channel.type !== DM && channel.guild_id) {
        title = `#${channel.name} (${GuildStore.getGuild(channel.guild_id)?.name ?? "server"})`;
    }

    const parts = [message.referenced_message ? "(reply)" : "", readable(message, channel.guild_id)];
    for (const a of message.attachments)
        parts.push(a.content_type?.startsWith("image") ? `[image: ${a.filename}]` : `[attachment: ${a.filename}]`);
    if (message.embeds.length) parts.push("[embed]");
    if (message.sticker_items?.length) parts.push("[sticker]");

    const avatar = UserStore.getUser(message.author.id)?.getAvatarURL(undefined, 128, false);
    const image = message.attachments.find(a => a.content_type?.startsWith("image"));

    return {
        title,
        sender: author,
        body: parts.filter(Boolean).join(" ").trim(),
        url: `https://discord.com/channels/${channel.guild_id ?? "@me"}/${message.channel_id}/${message.id}`,
        group: message.channel_id,
        icon: avatar?.startsWith("https://") ? avatar : undefined,
        image: image?.url,
    };
}

export default definePlugin({
    name: "PubsubPush",
    description: "Forwards Discord notifications to your phone through a pubsub-push topic, with links to the message",
    authors: [{ name: "Ada", id: 0n }],
    enabledByDefault: true,
    reporterTestable: ReporterTestable.None,

    start() {
        ReadStateStore.addChangeListener(clearRead);
    },

    stop() {
        ReadStateStore.removeChangeListener(clearRead);
        forwarded.clear();
    },

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
                .then(result => {
                    logger.debug(result);
                    if (result === "published") forwarded.set(message.channel_id, message.id);
                })
                .catch(e => logger.error("publish failed", e));
        },
    },
});
