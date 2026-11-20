"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { useParams, useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { TableView, type SpectateProps } from "@/components/table/TableView";
import { nicknameStepHref } from "@/lib/nickname";
import { fetchNeedsNickname } from "@/lib/profileNickname";
import { setLobbyNotice } from "@/lib/lobbyNotice";
import {
  callSpectatorHeartbeat,
  callStopWatching,
  callWatchTable,
  type WatchTicket,
} from "@/lib/spectatorData";
import {
  followGame,
  heartbeatStep,
  rewatchOutcome,
  TABLE_CLOSED_TEXT,
  WATCH_RETRY_MS,
  watchRefusal,
  type RewatchOutcome,
} from "@/lib/spectators";

// THE WATCH PAGE (PRD item 40, parts B and C): a signed-in player watches a
// multiplayer table that allows spectators -- read-only.
//
// HARD RULES (scripts/test-phase3.ts scans this file and lib/spectatorData.ts):
//   * A spectator is NEVER a table_members row: nothing here writes a table,
//     and the only RPCs are watch_table, stop_watching, spectator_heartbeat
//     and get_spectator_reveals (lib/spectatorData.ts).
//   * The table is the players' own (components/table/TableView.tsx) in its
//     spectating mode: Seat 1 at the bottom, every hand face-down with its
//     count, every action off, hands and the crib only through
//     get_spectator_reveals, no sounds.
//
// THE FLOW. watch_table(code): let in -> the table. "No game yet" -> a
// waiting screen that asks again every WATCH_RETRY_MS. Seated here -> the
// player's own seat. Anything else -> its message and Back to home.
//
// STAYING (part C). Once watching, the spectator stays on the table through
// the game's end (the players' game-over screen, every action off) and a
// return to the waiting room (read-only), and follows the table's next game
// (followGame: watch_table again, quietly, for the new game). Only the host
// removing them sends them home ("The host removed you from this table.").
// The table closing shows a calm "This table has closed" screen with Back
// home, and the heartbeat stops (the table view is gone). The heartbeat
// (heartbeatStep) rides the table's safety poll and runs when the tab shows
// or the device comes back online. Closing the tab needs nothing: the place
// lapses after 90 s.

type WatchState =
  | { kind: "loading" }
  | { kind: "waiting" }
  | { kind: "watching"; ticket: WatchTicket }
  | { kind: "refused"; text: string; login: boolean }
  | { kind: "closed" };

export default function WatchPage() {
  const params = useParams<{ code: string }>();
  const code = params.code;
  const router = useRouter();
  const [session, setSession] = useState<Session | null>(null);
  const [authRead, setAuthRead] = useState(false);
  const [state, setState] = useState<WatchState>({ kind: "loading" });
  // The place being watched (watch_table's answer: the table and the game
  // followed now), and whether this page has already left the table view.
  const ticketRef = useRef<WatchTicket | null>(null);
  const exitedRef = useRef(false);

  // Signed in, and the nickname step first if this player has none (the
  // host will see spectators by name).
  useEffect(() => {
    let cancelled = false;
    supabase.auth.getSession().then(async ({ data }) => {
      if (cancelled) return;
      if (data.session && (await fetchNeedsNickname(data.session.user.id)) === true) {
        if (!cancelled) router.replace(nicknameStepHref(`/watch/${code}`));
        return;
      }
      if (cancelled) return;
      setSession(data.session);
      setAuthRead(true);
    });
    return () => {
      cancelled = true;
    };
  }, [code, router]);

  // WATCH_TABLE: once signed in, and again every WATCH_RETRY_MS while there
  // is no game yet.
  useEffect(() => {
    if (!session) return;
    let cancelled = false;
    let timer: number | null = null;
    const attempt = async () => {
      const result = await callWatchTable(code);
      if (cancelled) return;
      if ("ok" in result) {
        ticketRef.current = result.ok;
        setState({ kind: "watching", ticket: result.ok });
        return;
      }
      const refusal = watchRefusal(result.refused);
      if (refusal.kind === "seated") {
        router.replace(`/tables/${code}`);
        return;
      }
      if (refusal.kind === "waiting") {
        setState({ kind: "waiting" });
        timer = window.setTimeout(attempt, WATCH_RETRY_MS);
        return;
      }
      setState({ kind: "refused", text: refusal.text, login: refusal.kind === "login" });
    };
    attempt();
    return () => {
      cancelled = true;
      if (timer !== null) window.clearTimeout(timer);
    };
  }, [session, code, router]);

  // LEAVING THE TABLE VIEW, once: home (only for a removal), the closed
  // screen, or a refusal's screen.
  const leave = useCallback(
    (outcome: { kind: "home"; text: string | null } | { kind: "closed" } | { kind: "screen"; text: string }) => {
      if (exitedRef.current) return;
      exitedRef.current = true;
      if (outcome.kind === "home") {
        if (outcome.text) setLobbyNotice(outcome.text);
        router.replace("/");
      } else if (outcome.kind === "closed") {
        setState({ kind: "closed" });
      } else {
        setState({ kind: "refused", text: outcome.text, login: false });
      }
    },
    [router]
  );

  // A QUIET watch_table: after not_watching, or to follow a new game. In ->
  // the ticket moves on; refused -> rewatchOutcome ("no game yet" stays).
  const rewatch = useCallback(async () => {
    const again = await callWatchTable(code);
    if ("ok" in again) {
      ticketRef.current = again.ok;
      return;
    }
    const outcome: RewatchOutcome = rewatchOutcome(again.refused);
    if (outcome.kind !== "continue") leave(outcome);
  }, [code, leave]);

  // THE HEARTBEAT (heartbeatStep, lib/spectators.ts). One at a time; none
  // once the table view is gone.
  const beatingRef = useRef(false);
  const heartbeat = useCallback(async () => {
    const ticket = ticketRef.current;
    if (!ticket || beatingRef.current || exitedRef.current) return;
    beatingRef.current = true;
    try {
      const step = heartbeatStep(await callSpectatorHeartbeat(ticket.tableId));
      if (step.kind === "continue") return;
      if (step.kind === "rewatch") await rewatch();
      else leave(step);
    } finally {
      beatingRef.current = false;
    }
  }, [rewatch, leave]);

  // FOLLOWING THE GAME: the table view reports the live game on screen; a
  // new one (followGame) is watched quietly -- watch_table again, so the
  // place is fresh for it, and the ticket's game moves on. The reveals
  // already read the game on screen.
  const onLiveGame = useCallback(
    (gameId: string) => {
      const ticket = ticketRef.current;
      if (!ticket || exitedRef.current || !followGame(ticket.gameId, gameId)) return;
      ticketRef.current = { ...ticket, gameId };
      void rewatch();
    },
    [rewatch]
  );

  const spectate: SpectateProps = useMemo(
    () => ({
      heartbeat: () => {
        void heartbeat();
      },
      onLiveGame,
      onTableEnded: () => leave({ kind: "closed" }),
      onStop: () => {
        const ticket = ticketRef.current;
        if (exitedRef.current) return;
        // Best effort: if it fails, the place lapses after 90 s anyway.
        (ticket ? callStopWatching(ticket.tableId).catch(() => {}) : Promise.resolve()).then(() =>
          leave({ kind: "home", text: null })
        );
      },
    }),
    [heartbeat, onLiveGame, leave]
  );

  if (!authRead && state.kind === "loading") {
    return (
      <main className="table-loading flex flex-1 items-center justify-center">
        <p>Loading...</p>
      </main>
    );
  }

  if (!session || (state.kind === "refused" && state.login)) {
    return (
      <CardRoomFrame backHome={false}>
        <p>You need to be logged in to watch a table.</p>
        <Link href="/login" className="peg-btn peg-btn--brass">
          Log in
        </Link>
      </CardRoomFrame>
    );
  }

  if (state.kind === "waiting") {
    return (
      <CardRoomFrame backHome={false}>
        <p role="status">Waiting for the next game...</p>
        <p className="text-sm">Table {code}. You&apos;ll be watching as soon as it starts.</p>
        <Link href="/" className="peg-btn peg-btn--ghost">
          Back to home
        </Link>
      </CardRoomFrame>
    );
  }

  // THE TABLE CLOSED: calm, no redirect, no more heartbeats.
  if (state.kind === "closed") {
    return (
      <CardRoomFrame backHome={false}>
        <p role="status">{TABLE_CLOSED_TEXT}</p>
        <p className="text-sm">Table {code} is no longer open. Thanks for watching.</p>
        <Link href="/" className="peg-btn peg-btn--brass">
          Back home
        </Link>
      </CardRoomFrame>
    );
  }

  if (state.kind === "refused") {
    return (
      <CardRoomFrame backHome={false}>
        <p>{state.text}</p>
        <Link href="/" className="peg-btn peg-btn--brass">
          Back to home
        </Link>
      </CardRoomFrame>
    );
  }

  if (state.kind === "watching") return <TableView spectate={spectate} />;

  return (
    <main className="table-loading flex flex-1 items-center justify-center">
      <p>Loading...</p>
    </main>
  );
}
