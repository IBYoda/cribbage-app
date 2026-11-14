"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { RealtimeChannel } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import {
  CHAT_EVENT,
  addChatMessage,
  chatTopic,
  cleanChatText,
  createChatThrottle,
  createPerSenderThrottle,
  type ChatMessage,
} from "@/lib/tableChat";

// TABLE CHAT's channels (PRD item 39; the rules: lib/tableChat.ts and, on the
// server, docs/sql/table-chat.sql).
//
// ON only when `enabled`: the page passes an OPEN, HUMAN table (not a
// computer table) that I am seated at, on the table screen, signed in. Then:
//   * MY channel, chatTopic(table, me): I send on it, never listen (self:
//     false).
//   * every OTHER seated player's channel: I listen, never send.
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
// NEVER BREAKS THE GAME: a channel that can't join or errors only makes chat
// unavailable (my own channel) or quiet for that player (theirs). Nothing is
// thrown and nothing is shown: `available` goes false and the page hides
// the button. realtime-js rejoins on its own after a drop (airplane mode),
// and `available` comes back with it.

export type ChatRosterEntry = { user_id: string; nickname: string | null; avatar_url: string | null };
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

export function useTableChat({
  enabled,
  tableId,
  myUserId,
  roster,
}: {
  enabled: boolean;
  tableId: string | null;
  myUserId: string | null;
  roster: readonly ChatRosterEntry[];
}) {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [available, setAvailable] = useState(false);
  const [signedOut, setSignedOut] = useState(false);

  const rosterRef = useRef(roster);
  useEffect(() => {
    rosterRef.current = roster;
  }, [roster]);

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
      if (ownRef.current === channel) ownRef.current = null;
      if (channel) removeChatChannel(topic, channel);
    };
  }, [on, tableId, myUserId]);

  // THEIR CHANNELS: one per other seated player, keyed by topic, added and
  // dropped as the roster changes; the rest stay joined.
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
              const member = rosterRef.current.find((m) => m.user_id === senderId);
              if (!member) return; // left meanwhile
              if (!receiveThrottle.current.take(senderId, Date.now())) return;
              setMessages((list) =>
                addChatMessage(list, {
                  id: `chat-${Date.now()}-${++idSeq}`,
                  senderId,
                  name: member.nickname || "Unnamed player",
                  avatarUrl: member.avatar_url,
                  text,
                  at: Date.now(),
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
      const result = await channel.send({ type: "broadcast", event: CHAT_EVENT, payload: { text } });
      return result === "ok" ? "ok" : "failed";
    } catch {
      return "failed";
    }
  }, []);

  const dismiss = useCallback((id: string) => {
    setMessages((list) => list.filter((m) => m.id !== id));
  }, []);
  const closeAll = useCallback(() => setMessages([]), []);

  return { messages, send, dismiss, closeAll, available: on && available };
}
