"use client";

import { useCallback, useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { supabase } from "@/lib/supabase";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { FilteredLeaderboard } from "@/components/brand/FilteredLeaderboard";
import { type GodAvatar, type LeaderboardRow, type LeaderboardStatus } from "@/components/brand/Leaderboard";
import type { ComputerLevel } from "@/lib/computer/config";
import { readSoloLeaderboard } from "@/lib/leaderboardFilter";
import { computerFaces, type ComputerFace } from "@/lib/soloStats";

// THE LEADERBOARD ("Leaderboard" on the main menu): every player's wins,
// losses, skunks and Beat God, from get_leaderboard() -- a security definer
// function, signed-in players only (docs/sql/leaderboard-l2-function.sql).
// Read once on arrival and again on Refresh; no realtime.
//
// God's avatar for the Beat God chip: the 'hard' row of
// get_computer_profiles(), as the opponent chooser reads it. If that call
// fails, the chip shows without an avatar.
//
// THE FILTERS (PRD item 35, S4): Multiplayer is this page's own read, as
// before; the computer boards (?vs=<level>) are read by FilteredLeaderboard.
// The same get_computer_profiles() call gives the filter chips their names
// and avatars (LEVEL_INFO's names and initials if it fails).
export default function LeaderboardPage() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [status, setStatus] = useState<LeaderboardStatus>("loading");
  const [rows, setRows] = useState<LeaderboardRow[]>([]);
  const [god, setGod] = useState<GodAvatar>(null);
  const [faces, setFaces] = useState<Record<ComputerLevel, ComputerFace>>(() => computerFaces([]));
  const [refreshing, setRefreshing] = useState(false);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });
  }, []);

  // Keeps the rows on screen while a Refresh runs; a failed Refresh with
  // rows already shown leaves them, and only a failure with nothing to show
  // becomes the error state.
  const load = useCallback(async () => {
    setRefreshing(true);
    const { data, error } = await supabase.rpc("get_leaderboard");
    if (error || !Array.isArray(data)) {
      setStatus((current) => (current === "ready" ? "ready" : "error"));
    } else {
      setRows(data as LeaderboardRow[]);
      setStatus("ready");
    }
    setRefreshing(false);
  }, []);

  useEffect(() => {
    if (!session) return;
    let cancelled = false;
    // Deferred a tick, so no state is set synchronously inside the effect.
    Promise.resolve().then(() => {
      if (!cancelled) load();
    });
    supabase.rpc("get_computer_profiles").then(
      ({ data, error }) => {
        if (cancelled || error || !Array.isArray(data)) return;
        const profiles = data as { level: string; nickname: string | null; avatar_url: string | null }[];
        const hard = profiles.find((r) => r.level === "hard");
        if (hard) setGod({ name: hard.nickname || "God", url: hard.avatar_url ?? null });
        setFaces(computerFaces(profiles));
      },
      () => {} // a network failure: no avatar on the chip
    );
    return () => {
      cancelled = true;
    };
  }, [session, load]);

  if (loading) {
    return (
      <CardRoomFrame backHome={false}>
        <p className="text-center">Loading...</p>
      </CardRoomFrame>
    );
  }

  if (!session) {
    return (
      <CardRoomFrame backHome={false}>
        <p>You need to be logged in to see the leaderboard.</p>
        <Link href="/login" className="peg-btn peg-btn--brass">
          Log in
        </Link>
      </CardRoomFrame>
    );
  }

  return (
    <CardRoomFrame compact>
      <FilteredLeaderboard
        main={{ status, rows, refreshing, onRefresh: load }}
        meId={session.user.id}
        god={god}
        faces={faces}
        readLevel={readSoloLeaderboard}
      />
    </CardRoomFrame>
  );
}
