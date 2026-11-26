"use client";

import { useEffect, useRef } from "react";
import type { RealtimeChannel } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import { KICK_EVENT, kickTopic, parseKickNotice, type KickNotice } from "@/lib/kicks";

// THE KICK NOTICE (moderation M3): listens on the table's private broadcast
// topic kicks:<table_id>, where kick_player (the server, nobody else) sends
// { kicked_id, nickname, at } when the host kicks someone. Who may listen is
// the server's rule (kick_topic_allows: seated at the table, or a current
// spectator); a channel that can't join just stays quiet -- nothing is
// shown and nothing breaks.
//
// Broadcasts are never stored or replayed: a screen that opens (or reloads)
// after a kick never hears it. onKick gets each notice once; what it does
// with it (ask whether to block, or leave if it is me) is lib/kicks.ts's
// kickNoticeAction, in TableView.

const CHANNEL_CONFIG = { config: { private: true } };

export function useTableKicks({
  enabled,
  tableId,
  onKick,
}: {
  enabled: boolean;
  tableId: string | null;
  onKick: (notice: KickNotice) => void;
}) {
  // The latest handler, read when a notice arrives (no rejoin when it
  // changes).
  const onKickRef = useRef(onKick);
  useEffect(() => {
    onKickRef.current = onKick;
  }, [onKick]);

  useEffect(() => {
    if (!enabled || !tableId) return;
    const topic = kickTopic(tableId);
    let cancelled = false;
    let channel: RealtimeChannel | null = null;
    (async () => {
      try {
        await supabase.realtime.setAuth();
        const { data } = await supabase.auth.getSession();
        if (cancelled || !data.session) return;
        channel = supabase.channel(topic, CHANNEL_CONFIG);
        channel.on("broadcast", { event: KICK_EVENT }, ({ payload }) => {
          if (cancelled) return;
          const notice = parseKickNotice(payload);
          if (notice) onKickRef.current(notice);
        });
        channel.subscribe();
      } catch {
        // Quiet: the notice is a courtesy; the kick itself never depends on it.
      }
    })();
    return () => {
      cancelled = true;
      if (channel) void supabase.removeChannel(channel).catch(() => null);
    };
  }, [enabled, tableId]);
}
