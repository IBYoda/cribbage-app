"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import { loadJoinableTables, loadMyTables, type JoinableTable, type MyTable } from "@/lib/openTables";
import { HomeMenu, type OpenTablesState } from "@/components/brand/HomeMenu";
import { LandingView } from "@/components/brand/LandingView";
import { NicknameStep } from "@/components/brand/NicknameStep";
import { needsNickname } from "@/lib/nickname";
import { useWingsOn } from "@/components/Wings";
import { getGodWins } from "@/lib/godWins";
import { displayTier, initSeenTier, type GodWinsTier, type WingsTier } from "@/lib/wings";

// How often Open Tables re-reads while the tab is visible (was 15 s; 45 s
// to cut request volume -- the Refresh button reads at once).
const REFRESH_MS = 45_000;

// THE SIGNED-IN HOME: reads what the main menu shows, then renders HomeMenu.
// Read-only, through the existing RLS, and each part can fail on its own:
//   * the profile (nickname, avatar) -- falls back to the email's name; no
//     profile row or a blank nickname shows the Pick-a-nickname step
//     (NicknameStep) instead of the menu, straight to the menu once saved;
//   * admin_users, the player's own row only -- the Admin link shows only if
//     that read succeeds and finds the row;
//   * "Open Tables" (lib/openTables.ts): the open tables the player is
//     seated at, and the public tables they could join -- two independent
//     reads, refreshed every 45 seconds while the tab is visible.
// Nothing here touches the Appearance settings or the game tables' data.
export function HomeView({ session, onLogout }: { session: Session; onLogout: () => void }) {
  const userId = session.user.id;
  const emailName = session.user.email?.split("@")[0] ?? "player";

  const [nickname, setNickname] = useState<string | null>(null);
  const [avatarUrl, setAvatarUrl] = useState<string | null>(null);
  const [isAdmin, setIsAdmin] = useState(false);
  // The nickname gate: "pending" until the profile read answers, "needs"
  // for no profile row or a blank nickname (the Pick-a-nickname step shows
  // instead of the menu), "ok" otherwise -- a failed read included, so a
  // player is never stuck behind a read that didn't work.
  const [gate, setGate] = useState<"pending" | "needs" | "ok">("pending");

  useEffect(() => {
    let cancelled = false;

    supabase
      .from("profiles")
      .select("nickname, avatar_url")
      .eq("id", userId)
      .maybeSingle()
      .then(
        ({ data, error }) => {
          if (cancelled) return;
          if (error) {
            setGate("ok");
            return;
          }
          setGate(needsNickname(data) ? "needs" : "ok");
          if (!data) return;
          setNickname(data.nickname?.trim() || null);
          setAvatarUrl(data.avatar_url ?? null);
        },
        () => {
          if (!cancelled) setGate("ok");
        }
      );

    supabase
      .from("admin_users")
      .select("user_id")
      .eq("user_id", userId)
      .maybeSingle()
      .then(({ data, error }) => {
        if (!cancelled) setIsAdmin(!error && !!data);
      });

    return () => {
      cancelled = true;
    };
  }, [userId]);

  const openTables = useOpenTables(userId);

  // My wings for the greeting. A player's first read here is what sets the
  // milestone's starting point (initSeenTier).
  const wingsOn = useWingsOn();
  const [myWings, setMyWings] = useState<GodWinsTier | null>(null);
  useEffect(() => {
    let cancelled = false;
    getGodWins([userId]).then((found) => {
      const mine = found.get(userId);
      if (cancelled || !mine) return;
      initSeenTier(userId, mine.count);
      setMyWings(mine.tier);
    });
    return () => {
      cancelled = true;
    };
  }, [userId]);

  // Until the profile read answers: the card room as it was while the
  // session was read (LandingView, buttons held back), so a player without
  // a nickname never sees the menu flash past on the way to the step.
  if (gate === "pending") return <LandingView signedOut={false} />;

  if (gate === "needs") {
    return (
      <NicknameStep
        userId={userId}
        onSaved={(saved) => {
          setNickname(saved);
          setGate("ok");
        }}
        onLogout={onLogout}
      />
    );
  }

  return (
    <HomeMenu
      name={nickname ?? emailName}
      avatarUrl={avatarUrl}
      wings={wingsOn ? displayTier(userId, myWings) : null}
      isAdmin={isAdmin}
      openTables={openTables}
      onLogout={onLogout}
    />
  );
}

// The Open Tables list's data. Every REFRESH_MS while the tab is visible,
// paused while it's hidden, at once when it comes back; one refresh at a
// time; each read keeps its last good rows if it fails, so nothing already
// on screen is wiped or flickers.
function useOpenTables(userId: string): OpenTablesState {
  const [mine, setMine] = useState<MyTable[] | null>(null);
  const [joinable, setJoinable] = useState<JoinableTable[] | null>(null);
  const [hostWings, setHostWings] = useState<Record<string, WingsTier | null>>({});
  const wingsOn = useWingsOn();
  const [failed, setFailed] = useState(false);
  const [refreshing, setRefreshing] = useState(false);
  const [readAt, setReadAt] = useState(0);
  const inFlight = useRef(false);
  const mounted = useRef(true);

  // Starts a refresh; state changes only when its answers arrive (in the
  // promise callback), so this can run straight from the effect below. A
  // thrown error counts as a failed read, so inFlight can't get stuck.
  const refresh = useCallback(() => {
    if (inFlight.current) return;
    inFlight.current = true;
    Promise.all([
      loadMyTables(userId).catch(() => null),
      // With their wings, so each row arrives whole.
      loadJoinableTables(userId)
        .catch(() => null)
        .then(async (rows) => ({ rows, wins: await getGodWins((rows ?? []).flatMap((t) => t.hostId ?? [])) })),
    ]).then(([nextMine, { rows: nextJoinable, wins }]) => {
      inFlight.current = false;
      if (!mounted.current) return;
      setRefreshing(false);
      if (nextMine) setMine(nextMine);
      if (nextJoinable) {
        // Every host, so the creator's show even when the count can't be read.
        setHostWings(
          Object.fromEntries(
            nextJoinable.flatMap((t) => (t.hostId ? [[t.hostId, displayTier(t.hostId, wins.get(t.hostId)?.tier)]] : []))
          )
        );
        setJoinable(nextJoinable);
        setReadAt(Date.now());
      }
      setFailed(nextMine === null || nextJoinable === null);
    });
  }, [userId]);

  // The Refresh button: "Refreshing..." until the answer. Ignored while a
  // refresh (timed or not) is already running.
  const onRefresh = useCallback(() => {
    if (inFlight.current) return;
    setRefreshing(true);
    refresh();
  }, [refresh]);

  useEffect(() => {
    mounted.current = true;
    let timer: number | null = null;
    const start = () => {
      if (timer === null) timer = window.setInterval(refresh, REFRESH_MS);
    };
    const stop = () => {
      if (timer !== null) window.clearInterval(timer);
      timer = null;
    };
    const onVisibility = () => {
      if (document.visibilityState === "visible") {
        refresh();
        start();
      } else {
        stop();
      }
    };

    refresh();
    if (document.visibilityState === "visible") start();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      mounted.current = false;
      stop();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, [refresh]);

  return { mine, joinable, failed, refreshing, readAt, onRefresh, hostWings: wingsOn ? hostWings : {} };
}
