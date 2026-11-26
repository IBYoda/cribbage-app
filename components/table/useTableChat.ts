"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { RealtimeChannel } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import {
  CHAT_EVENT,
  OWN_CARD_MS,
  addChatMessage,
  chatTopic,
  cleanChatText,
  createChatThrottle,
  createPerSenderThrottle,
  ownChatCard,
  withoutSenders,
  type ChatMessage,
} from "@/lib/tableChat";

// TABLE CHAT's channels (PRD item 39; the rules: lib/tableChat.ts and, on the
// server, docs/sql/table-chat.sql).
//
// ON only when `enabled`: the page passes an OPEN, HUMAN table (not a
// computer table) that I am seated at -- or, spectator chat, that I am a
// CURRENT spectator of -- on the table screen, signed in. Then:
//   * MY channel, chatTopic(table, me): I send on it, never listen (self:
//     false).
//   * every OTHER roster entry's channel -- the seated players and the
//     current spectators: I listen, never send.
// THE ROSTER IS THE CUTOFF. Realtime checks a channel's permission when it
// is joined (and at a token refresh), not per message, so a spectator who
// was removed or went stale may still be able to send for a while. What
// this screen SHOWS is decided here: a sender who is not in the roster is
// dropped, and their channel is left as soon as the roster loses them (the
// page's list refresh, or at once on the host's screen after Remove).
// All private (the server's policies decide), broadcast event "msg", acked.
// A player joining adds their channel; one leaving drops theirs. Off -- I
// leave, the table ends, the page goes, I sign out -- removes every channel
// and forgets every message.
//
// THE TOKEN: a private channel is joined with the Realtime socket's access
// token. supabase-js keeps it in step with the session itself (on the
// initial session, sign-in and every refresh), which is all the table's own
// members channel relies on. Chat adds one step before its first join:
// supabase.realtime.setAuth() with no argument, which asks the client for the
// current session's token, so a private join can never go out with the anon
// key in its place. Then it checks a session is really there.
//
// WHO SENT IT is the channel it arrived on: only that player may send there
// (the server's rule). Name and avatar come from the roster as it arrives --
// nothing is read from the message but `text`, which is cleaned
// (cleanChatText) and throttled per sender; anything else is dropped.
//
// MUTED SENDERS (moderation M2/M2c): `muted` -- the people I muted at this
// table plus
// the people on my Block List (lib/tableChat.ts mutedSenders). Their
// messages are dropped as they arrive, before anything is stored (so the
// stack never shows them and the screen reader never reads them); any that
// arrived before the set changed are filtered out of what the hook returns,
// and dropSender (a Mute) forgets them for good. Their
// channels stay joined: muting changes nothing anyone else sees.
//
// MY OWN MESSAGE: once a send is ACKed "ok", `own` holds it for OWN_CARD_MS
// (lib/tableChat.ts) -- one at a time, apart from `messages`.
//
// NEVER BREAKS THE GAME: a channel that can't join or errors only makes chat
// unavailable (my own channel) or quiet for that player (theirs). Nothing is
// thrown and nothing is shown: `available` goes false and the page hides
// the button. realtime-js rejoins on its own after a drop (airplane mode),
// and `available` comes back with it.

// spectator: a current spectator (their messages carry the eye).
export type ChatRosterEntry = { user_id: string; nickname: string | null; avatar_url: string | null; spectator?: boolean };
export type ChatSendResult = "ok" | "throttled" | "failed";

const CHANNEL_CONFIG = { config: { private: true, broadcast: { self: false, ack: true } } };

// A channel being removed keeps its topic until removeChannel resolves, and
// supabase.channel() hands back an existing channel of the same topic -- one
// that is closing. So a rejoin of a topic waits for its removal to finish.
const removing = new Map<string, Promise<unknown>>();
function removeChatChannel(topic: string, channel: RealtimeChannel) {
  const done = supabase
    .removeChannel(channel)
    .catch(() => null)
    .finally(() => {
      if (removing.get(topic) === done) removing.delete(topic);
    });
  removing.set(topic, done);
}

let idSeq = 0;
const NOBODY_MUTED: ReadonlySet<string> = new Set();

export function useTableChat({
  enabled,
  tableId,
  myUserId,
  roster,
  muted = NOBODY_MUTED,
}: {
  enabled: boolean;
  tableId: string | null;
  myUserId: string | null;
  roster: readonly ChatRosterEntry[];
  muted?: ReadonlySet<string>;
}) {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [available, setAvailable] = useState(false);
  const [signedOut, setSignedOut] = useState(false);
  // My own last message, echoed for OWN_CARD_MS after an OK ack (apart from
  // `messages`, which are only the others': the stack never counts it and
  // the announcer never reads it).
  const [own, setOwn] = useState<ChatMessage | null>(null);

  const rosterRef = useRef(roster);
  const meRef = useRef(myUserId);
  useEffect(() => {
    rosterRef.current = roster;
    meRef.current = myUserId;
  }, [roster, myUserId]);

  // Muted senders: read at arrival from the ref (dropped, never stored).
  const mutedRef = useRef(muted);
  useEffect(() => {
    mutedRef.current = muted;
  }, [muted]);

  // My own card goes by itself after OWN_CARD_MS (a newer one restarts it).
  useEffect(() => {
    if (!own) return;
    const t = window.setTimeout(() => setOwn((cur) => (cur?.id === own.id ? null : cur)), OWN_CARD_MS);
    return () => window.clearTimeout(t);
  }, [own]);

  // Signing out anywhere (this tab or another) turns chat off at once.
  useEffect(() => {
    const { data } = supabase.auth.onAuthStateChange((event) => {
      if (event === "SIGNED_OUT") setSignedOut(true);
      else if (event === "SIGNED_IN") setSignedOut(false);
    });
    return () => data.subscription.unsubscribe();
  }, []);

  const on = enabled && !signedOut && !!tableId && !!myUserId;
  // The other players, as one stable key, so a roster refresh that changes
  // nothing (a score) rejoins nothing.
  const others = on ? roster.map((m) => m.user_id).filter((id) => id !== myUserId).sort() : [];
  const othersKey = others.join(",");

  const ownRef = useRef<RealtimeChannel | null>(null);
  const sendThrottle = useRef(createChatThrottle());
  const receiveThrottle = useRef(createPerSenderThrottle());

  // MY CHANNEL: joined while on.
  useEffect(() => {
    if (!on || !tableId || !myUserId) return;
    const topic = chatTopic(tableId, myUserId);
    let cancelled = false;
    let channel: RealtimeChannel | null = null;
    (async () => {
      try {
        await removing.get(topic);
        await supabase.realtime.setAuth();
        const { data } = await supabase.auth.getSession();
        if (cancelled || !data.session) return;
        channel = supabase.channel(topic, CHANNEL_CONFIG);
        ownRef.current = channel;
        channel.subscribe((status) => {
          if (cancelled) return;
          setAvailable(status === "SUBSCRIBED");
        });
      } catch {
        if (!cancelled) setAvailable(false);
      }
    })();
    return () => {
      cancelled = true;
      setAvailable(false);
      // Chat off (or another table): every message is forgotten.
      setMessages([]);
      setOwn(null);
      if (ownRef.current === channel) ownRef.current = null;
      if (channel) removeChatChannel(topic, channel);
    };
  }, [on, tableId, myUserId]);

  // THEIR CHANNELS: one per other roster entry (players and current
  // spectators), keyed by topic, added and dropped as the roster changes;
  // the rest stay joined.
  type Listening = { channel: RealtimeChannel | null; cancelled: boolean };
  const listenRef = useRef(new Map<string, Listening>());
  useEffect(() => {
    const listening = listenRef.current;
    const want = new Map<string, string>(); // topic -> sender id
    if (tableId && othersKey) {
      for (const senderId of othersKey.split(",")) want.set(chatTopic(tableId, senderId), senderId);
    }
    // Gone, another table, or chat off: leave that channel.
    for (const [topic, entry] of listening) {
      if (want.has(topic)) continue;
      entry.cancelled = true;
      if (entry.channel) removeChatChannel(topic, entry.channel);
      listening.delete(topic);
    }
    for (const [topic, senderId] of want) {
      if (listening.has(topic)) continue;
      const entry: Listening = { channel: null, cancelled: false };
      listening.set(topic, entry);
      (async () => {
        try {
          await removing.get(topic);
          await supabase.realtime.setAuth();
          const { data } = await supabase.auth.getSession();
          if (entry.cancelled || !data.session) return;
          const channel = supabase.channel(topic, CHANNEL_CONFIG);
          entry.channel = channel;
          channel
            .on("broadcast", { event: CHAT_EVENT }, (message: { payload?: unknown }) => {
              if (entry.cancelled) return;
              // The sender is this channel's player. Only `text` is read.
              const payload = message.payload;
              const text = cleanChatText(
                payload && typeof payload === "object" ? (payload as { text?: unknown }).text : undefined
              );
              if (text === null) return;
              // Hidden or blocked by me (moderation M2): dropped, never stored.
              if (mutedRef.current.has(senderId)) return;
              const member = rosterRef.current.find((m) => m.user_id === senderId);
              // Not in the roster (left, removed, no longer watching): dropped.
              if (!member) return;
              if (!receiveThrottle.current.take(senderId, Date.now())) return;
              setMessages((list) =>
                addChatMessage(list, {
                  id: `chat-${Date.now()}-${++idSeq}`,
                  senderId,
                  name: member.nickname || "Unnamed player",
                  avatarUrl: member.avatar_url,
                  text,
                  at: Date.now(),
                  spectator: member.spectator === true,
                })
              );
            })
            .subscribe();
        } catch {
          // Quiet: this player's messages just don't arrive.
        }
      })();
    }
  }, [othersKey, tableId]);

  // The page going: leave every channel still held.
  useEffect(() => {
    const listening = listenRef.current;
    return () => {
      for (const [topic, entry] of listening) {
        entry.cancelled = true;
        if (entry.channel) removeChatChannel(topic, entry.channel);
      }
      listening.clear();
    };
  }, []);

  const send = useCallback(async (input: string): Promise<ChatSendResult> => {
    const text = cleanChatText(input);
    const channel = ownRef.current;
    // Only on a joined channel: realtime-js would otherwise fall back to a
    // REST send.
    if (text === null || !channel || channel.state !== "joined") return "failed";
    if (!sendThrottle.current.take(Date.now())) return "throttled";
    try {
      const ack = await channel.send({ type: "broadcast", event: CHAT_EVENT, payload: { text } });
      const result: ChatSendResult = ack === "ok" ? "ok" : "failed";
      // Delivered: I see it too, briefly (a failed send shows no card).
      const myUserId = meRef.current;
      const card = myUserId
        ? ownChatCard({
            result,
            text,
            me: rosterRef.current.find((m) => m.user_id === myUserId),
            myUserId,
            now: Date.now(),
            id: `own-${Date.now()}-${++idSeq}`,
          })
        : null;
      if (card) setOwn(card);
      return result;
    } catch {
      return "failed";
    }
  }, []);

  const dismiss = useCallback((id: string) => {
    setMessages((list) => list.filter((m) => m.id !== id));
  }, []);
  const closeAll = useCallback(() => setMessages([]), []);
  const dismissOwn = useCallback(() => setOwn(null), []);
  // A Mute (moderation M2c): that sender's messages go from memory at once,
  // so an Unmute later doesn't bring old ones back.
  const dropSender = useCallback((senderId: string) => {
    setMessages((list) => withoutSenders(list, new Set([senderId])));
  }, []);

  // What shows: never a muted sender's message -- also one that arrived
  // before they were muted (a block made on the Profile page in another tab).
  const shown = useMemo(() => withoutSenders(messages, muted), [messages, muted]);

  return { messages: shown, own: on ? own : null, send, dismiss, closeAll, dismissOwn, dropSender, available: on && available };
}
