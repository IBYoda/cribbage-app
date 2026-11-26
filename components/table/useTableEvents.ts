"use client";

import { useEffect, useRef } from "react";
import type { RealtimeChannel } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import { TABLE_EVENT_KINDS, acceptTableEvent, parseTableEvent, tableEventTopic, type TableEvent, type TableEventRole } from "@/lib/tableEvents";

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
// The same private-channel setup as the kick channel (useTableKicks.ts):
// supabase.realtime.setAuth() first, so the join never goes out with the
// anon key, then a session check. Removed on leave, role change and unmount.

const CHANNEL_CONFIG = { config: { private: true } };

export function useTableEvents({
  role,
  tableId,
  onEvent,
}: {
  role: TableEventRole | null;
  tableId: string | null;
  onEvent: (event: TableEvent) => void;
}) {
  // The latest handler, read when an event arrives (no rejoin when it
  // changes).
  const onEventRef = useRef(onEvent);
  useEffect(() => {
    onEventRef.current = onEvent;
  }, [onEvent]);

  // The highest version seen, per table. Kept across a rejoin of the same
  // table (a role change), forgotten for another table.
  const seenRef = useRef<{ tableId: string | null; version: number | null }>({ tableId: null, version: null });

  useEffect(() => {
    if (!role || !tableId) return;
    if (seenRef.current.tableId !== tableId) seenRef.current = { tableId, version: null };
    const topic = tableEventTopic(tableId);
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
        channel.subscribe();
      } catch {
        // Quiet: the old listeners and the safety poll still keep the screen right.
      }
    })();
    return () => {
      cancelled = true;
      if (channel) void supabase.removeChannel(channel).catch(() => null);
    };
  }, [role, tableId]);
}
