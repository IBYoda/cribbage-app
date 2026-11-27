"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { supabase } from "@/lib/supabase";
import {
  OWN_CARD_MS,
  addChatMessage,
  chatEventIsMine,
  chatSendOutcome,
  cleanChatText,
  createChatThrottle,
  ownChatCard,
  withoutSenders,
  type ChatMessage,
  type ChatSendResult,
} from "@/lib/tableChat";
import type { ChatEvent } from "@/lib/tableEvents";

// TABLE CHAT (PRD item 39), THROUGH THE SERVER (moderation M5c1; the rules:
// lib/tableChat.ts, and on the server docs/sql/moderation-m5c1-part1.sql).
//
// ON only when `enabled`: the page passes an OPEN, HUMAN table (not a
// computer table) that I am seated at -- or, spectator chat, that I am a
// CURRENT spectator of -- on the table screen, signed in. Then:
//   * SENDING: supabase.rpc("send_table_message", { p_table_id, p_text }).
//     The server checks who may send, cleans the text again, limits the
//     rate (1 in 2 s, 3 in 10 s), sets the sender itself and broadcasts on
//     the table's private topic. Its answer is { id, at }; NBC04 is "Slow
//     down", anything else "Couldn't send" (chatSendOutcome).
//   * RECEIVING: this hook opens NO channel. The table's one channel
//     (components/table/useTableEvents.ts) hears 'chat' there, checks its
//     shape and drops a repeated id, and the page hands each message to
//     `receive`. The old per-sender chat:<table>:<sender> channels are gone
//     (Walt's HARD CUT, 2026-11-26).
// Off -- I leave, the table ends, the page goes, I sign out -- forgets
// every message; a message arriving while off is ignored (a computer
// table's channel never carries one anyway).
//
// THE ROSTER IS THE CUTOFF, as before: a sender who is not in the roster
// (the seated players and the current spectators) is dropped, so a
// spectator who left the list leaves everyone's chat at once. Name and
// avatar come from the roster as the message arrives -- from the message
// only its server-set sender_id (who), its id and its text.
//
// MUTED SENDERS (moderation M2/M2c): `muted` -- the people I muted at this
// table plus the people on my Block List (lib/tableChat.ts mutedSenders).
// Their messages are dropped as they arrive, before anything is stored (so
// the stack never shows them and the screen reader never reads them); any
// that arrived before the set changed are filtered out of what the hook
// returns, and dropSender (a Mute) forgets them for good. Muting changes
// nothing anyone else sees.
//
// MY OWN MESSAGE: once send_table_message answers OK, `own` holds it for
// OWN_CARD_MS (lib/tableChat.ts) -- one at a time, apart from `messages`,
// with the server's id. The server's broadcast reaches me too: it is
// matched by that id (or, if it beats the answer, by its sender being me)
// and never becomes a second card (chatEventIsMine).
//
// HEARD (moderation M5c1 review): `heard` is whether the table's channel is
// joined right now (useTableEvents' `joined`). While it isn't, chat is not
// available -- the button hides -- and a send is "failed" without being
// made: you could send, but never hear the replies.
//
// NEVER BREAKS THE GAME: a failed send only shows its note; nothing is
// thrown.

// spectator: a current spectator (their messages carry the eye).
export type ChatRosterEntry = { user_id: string; nickname: string | null; avatar_url: string | null; spectator?: boolean };
export type { ChatSendResult };

// How many of my own sent ids are kept to match their echoes.
const OWN_IDS_MAX = 20;

let idSeq = 0;
const NOBODY_MUTED: ReadonlySet<string> = new Set();

export function useTableChat({
  enabled,
  tableId,
  myUserId,
  roster,
  heard,
  muted = NOBODY_MUTED,
}: {
  enabled: boolean;
  tableId: string | null;
  myUserId: string | null;
  roster: readonly ChatRosterEntry[];
  heard: boolean;
  muted?: ReadonlySet<string>;
}) {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [signedOut, setSignedOut] = useState(false);
  // My own last message, echoed for OWN_CARD_MS after an OK answer (apart
  // from `messages`, which are only the others': the stack never counts it
  // and the announcer never reads it).
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
  // Read by receive and send, which never change identity.
  const liveRef = useRef<{ on: boolean; tableId: string | null; heard: boolean }>({ on, tableId, heard });
  useEffect(() => {
    liveRef.current = { on, tableId, heard };
  }, [on, tableId, heard]);

  const sendThrottle = useRef(createChatThrottle());
  // My own sent ids, newest last (for matching their echoes).
  const ownIdsRef = useRef<string[]>([]);

  // Chat off, or another table: every message is forgotten.
  useEffect(() => {
    if (!on || !tableId) return;
    return () => {
      setMessages([]);
      setOwn(null);
      ownIdsRef.current = [];
    };
  }, [on, tableId]);

  // A message from the table's channel (already shape-checked, not a
  // repeat). Dropped unless chat is on here, and it is someone else's,
  // from someone I haven't muted, who is in the roster.
  const receive = useCallback((event: ChatEvent) => {
    if (!liveRef.current.on) return;
    if (chatEventIsMine(event, meRef.current, ownIdsRef.current)) return;
    const senderId = event.senderId;
    const text = cleanChatText(event.text);
    if (text === null) return;
    // Hidden or blocked by me (moderation M2): dropped, never stored.
    if (mutedRef.current.has(senderId)) return;
    const member = rosterRef.current.find((m) => m.user_id === senderId);
    // Not in the roster (left, removed, no longer watching): dropped.
    if (!member) return;
    setMessages((list) =>
      list.some((m) => m.id === event.id)
        ? list
        : addChatMessage(list, {
            id: event.id,
            senderId,
            name: member.nickname || "Unnamed player",
            avatarUrl: member.avatar_url,
            text,
            at: Date.now(),
            spectator: member.spectator === true,
          })
    );
  }, []);

  const send = useCallback(async (input: string): Promise<ChatSendResult> => {
    const text = cleanChatText(input);
    const { on: isOn, tableId: sentTo, heard: hearing } = liveRef.current;
    // Never while deaf: the replies would never arrive.
    if (text === null || !isOn || !sentTo || !hearing) return "failed";
    // The first guard: the server's own limit, without a round trip.
    if (!sendThrottle.current.take(Date.now())) return "throttled";
    let outcome: ReturnType<typeof chatSendOutcome>;
    try {
      const { data, error } = await supabase.rpc("send_table_message", { p_table_id: sentTo, p_text: text });
      outcome = chatSendOutcome(error, data);
    } catch {
      return "failed";
    }
    const result = outcome.result;
    // Sent: I see it too, briefly (a refused send shows no card) -- unless
    // chat went off or moved to another table meanwhile.
    const myUserId = meRef.current;
    if (result === "ok" && myUserId && liveRef.current.on && liveRef.current.tableId === sentTo) {
      const id = outcome.id ?? `own-${Date.now()}-${++idSeq}`;
      if (outcome.id) ownIdsRef.current = [...ownIdsRef.current, outcome.id].slice(-OWN_IDS_MAX);
      const card = ownChatCard({
        result,
        text,
        me: rosterRef.current.find((m) => m.user_id === myUserId),
        myUserId,
        now: Date.now(),
        id,
      });
      if (card) setOwn(card);
    }
    return result;
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

  return { messages: shown, own: on ? own : null, send, receive, dismiss, closeAll, dismissOwn, dropSender, available: on && heard };
}
