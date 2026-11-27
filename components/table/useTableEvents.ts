"use client";

import { useEffect, useRef, useState } from "react";
import type { RealtimeChannel } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import {
  TABLE_EVENT_KINDS,
  acceptGameEvent,
  acceptScoresEvent,
  acceptTableEvent,
  parseChatEvent,
  parseGameEvent,
  parseScoresEvent,
  parseTableEvent,
  rememberChatId,
  tableChannelJoined,
  tableEventTopic,
  type ChatEvent,
  type GameEvent,
  type GameSeen,
  type ScoresEvent,
  type ScoresSeen,
  type TableEvent,
  type TableEventRole,
} from "@/lib/tableEvents";

// TABLE EVENTS (moderation M5a): listens on the table's private broadcast
// topic table:<table_id>, where the server's triggers (nobody else) send
// { event, table_id, roster_version } when the table's people or the table
// row change (lib/tableEvents.ts). Each event that passes the version rule
// calls onEvent once; what it re-reads is TableView's (the same reads the
// safety poll makes).
//
// JOIN TIMING: Realtime checks the right to listen only when the channel is
// joined (table_topic_allows: seated there, or a current spectator). So the
// channel is opened only once `role` is set -- my seat or spectator row
// confirmed by a read -- and `role` is part of the effect's key: watching ->
// seated (or seated -> watching) leaves and joins again. A refused join
// (CHANNEL_ERROR) stays quiet: the old postgres_changes listeners and the
// safety poll keep the screen right.
//
// GAME EVENTS (moderation M5b1) arrive on the SAME channel (event 'game'),
// each through the per-game version rule (acceptGameEvent), then onGameEvent.
// SCORES EVENTS (moderation M5b2) too (event 'scores'), through
// acceptScoresEvent, then onScoresEvent -- a repair hint only.
// CHAT (moderation M5c1) too (event 'chat', sent by send_table_message):
// parseChatEvent, an id already seen at this table dropped (rememberChatId),
// then onChatEvent. Whether chat is on at all (an open HUMAN table) is
// useTableChat's to decide: at a computer table nothing sends one, and the
// chat hook ignores any that came.
// JOINED (moderation M5c1): the hook returns { joined }, true only while
// this role's channel for this table reports SUBSCRIBED (tableChannelJoined)
// -- false after CHANNEL_ERROR, TIMED_OUT or CLOSED, before the first
// join, on leave, and at once on a role or table change (it is kept per
// role and topic, so a new table never inherits the old one's true). The
// page hides chat while it is false.
// The same private-channel setup as the kick channel (useTableKicks.ts):
// supabase.realtime.setAuth() first, so the join never goes out with the
// anon key, then a session check. Removed on leave, role change and unmount.

const CHANNEL_CONFIG = { config: { private: true } };

export function useTableEvents({
  role,
  tableId,
  onEvent,
  onGameEvent,
  onScoresEvent,
  onChatEvent,
}: {
  role: TableEventRole | null;
  tableId: string | null;
  onEvent: (event: TableEvent) => void;
  onGameEvent: (event: GameEvent) => void;
  onScoresEvent: (event: ScoresEvent) => void;
  onChatEvent: (event: ChatEvent) => void;
}) {
  // The latest handler, read when an event arrives (no rejoin when it
  // changes).
  const onEventRef = useRef(onEvent);
  useEffect(() => {
    onEventRef.current = onEvent;
  }, [onEvent]);
  const onGameEventRef = useRef(onGameEvent);
  useEffect(() => {
    onGameEventRef.current = onGameEvent;
  }, [onGameEvent]);
  const onScoresEventRef = useRef(onScoresEvent);
  useEffect(() => {
    onScoresEventRef.current = onScoresEvent;
  }, [onScoresEvent]);
  const onChatEventRef = useRef(onChatEvent);
  useEffect(() => {
    onChatEventRef.current = onChatEvent;
  }, [onChatEvent]);

  // The highest version seen, per table. Kept across a rejoin of the same
  // table (a role change), forgotten for another table.
  const seenRef = useRef<{ tableId: string | null; version: number | null }>({ tableId: null, version: null });
  // The newest (hand, state_version) seen per game id, for this table.
  const gamesSeenRef = useRef<{ tableId: string | null; games: Map<string, GameSeen> }>({ tableId: null, games: new Map() });
  // The newest scores event seen, for this table.
  const scoresSeenRef = useRef<{ tableId: string | null; last: ScoresSeen | undefined }>({ tableId: null, last: undefined });
  // Which channel (role + topic) last reported SUBSCRIBED, or null.
  const [joinedKey, setJoinedKey] = useState<string | null>(null);
  // The chat message ids seen, for this table (a bounded list).
  const chatSeenRef = useRef<{ tableId: string | null; seen: string[] }>({ tableId: null, seen: [] });

  useEffect(() => {
    if (!role || !tableId) return;
    if (seenRef.current.tableId !== tableId) seenRef.current = { tableId, version: null };
    if (gamesSeenRef.current.tableId !== tableId) gamesSeenRef.current = { tableId, games: new Map() };
    if (scoresSeenRef.current.tableId !== tableId) scoresSeenRef.current = { tableId, last: undefined };
    if (chatSeenRef.current.tableId !== tableId) chatSeenRef.current = { tableId, seen: [] };
    const topic = tableEventTopic(tableId);
    const key = `${role}|${topic}`;
    let cancelled = false;
    let channel: RealtimeChannel | null = null;
    (async () => {
      try {
        await supabase.realtime.setAuth();
        const { data } = await supabase.auth.getSession();
        if (cancelled || !data.session) return;
        channel = supabase.channel(topic, CHANNEL_CONFIG);
        for (const kind of TABLE_EVENT_KINDS) {
          channel.on("broadcast", { event: kind }, ({ payload }) => {
            if (cancelled) return;
            const event = parseTableEvent(payload, tableId);
            if (!event) return;
            const step = acceptTableEvent(seenRef.current.version, event);
            seenRef.current = { tableId, version: step.lastSeen };
            if (step.accept) onEventRef.current(event);
          });
        }
        channel.on("broadcast", { event: "game" }, ({ payload }) => {
          if (cancelled) return;
          const event = parseGameEvent(payload);
          if (!event) return;
          const games = gamesSeenRef.current.games;
          const step = acceptGameEvent(games.get(event.gameId), event);
          games.set(event.gameId, step.last);
          if (step.accept) onGameEventRef.current(event);
        });
        channel.on("broadcast", { event: "scores" }, ({ payload }) => {
          if (cancelled) return;
          const event = parseScoresEvent(payload);
          if (!event) return;
          const step = acceptScoresEvent(scoresSeenRef.current.last, event);
          scoresSeenRef.current = { tableId, last: step.last };
          if (step.accept) onScoresEventRef.current(event);
        });
        channel.on("broadcast", { event: "chat" }, ({ payload }) => {
          if (cancelled) return;
          const event = parseChatEvent(payload);
          if (!event) return;
          const step = rememberChatId(chatSeenRef.current.seen, event.id);
          chatSeenRef.current = { tableId, seen: step.seen };
          if (step.fresh) onChatEventRef.current(event);
        });
        channel.subscribe((status) => {
          if (cancelled) return;
          setJoinedKey(tableChannelJoined(status) ? key : null);
        });
      } catch {
        // Quiet: the old listeners and the safety poll still keep the screen right.
      }
    })();
    return () => {
      cancelled = true;
      setJoinedKey((current) => (current === key ? null : current));
      if (channel) void supabase.removeChannel(channel).catch(() => null);
    };
  }, [role, tableId]);

  const joined = !!role && !!tableId && joinedKey === `${role}|${tableEventTopic(tableId)}`;
  return { joined };
}
