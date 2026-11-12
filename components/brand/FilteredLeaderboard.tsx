"use client";

import { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { LeaderboardFilterBar } from "@/components/brand/LeaderboardFilterBar";
import {
  LeaderboardPanel,
  type GodAvatar,
  type LeaderboardRow,
  type LeaderboardStatus,
} from "@/components/brand/Leaderboard";
import type { ComputerLevel } from "@/lib/computer/config";
import {
  computerBoardText,
  filterFromSearch,
  leaderboardChips,
  searchForFilter,
  type LeaderboardFilter,
} from "@/lib/leaderboardFilter";
import type { ComputerFace } from "@/lib/soloStats";

// THE LEADERBOARD WITH ITS FILTERS (PRD item 35, slice S4).
//
//   Multiplayer   the main board, read by the page (get_leaderboard()) and
//                 passed in as `main` -- shown exactly as before S4.
//   a computer    readLevel(level) (get_solo_leaderboard) the first time its
//                 chip is chosen, then kept until Refresh.
//
// THE URL: ?vs=<level> (lib/leaderboardFilter.ts), read through
// useSyncExternalStore (the table page's ?layout= pattern), so a shared link
// opens on that board and Back/Forward follow it. A chip REPLACES the
// history entry (window.history.replaceState, which Next.js supports), so
// clicking through the chips doesn't fill the Back button.
//
// REFRESH re-reads the board on screen and forgets every other computer
// board, so each is read fresh when next chosen.
//
// The reads are props, so a dev preview can drive the same component with
// made-up rows, an empty board or a failure.

const LOCATION_EVENT = "nobs:location-change";

function subscribeToLocation(onChange: () => void) {
  window.addEventListener("popstate", onChange);
  window.addEventListener(LOCATION_EVENT, onChange);
  return () => {
    window.removeEventListener("popstate", onChange);
    window.removeEventListener(LOCATION_EVENT, onChange);
  };
}
const searchFromUrl = () => window.location.search;
const searchOnServer = () => "";

type ComputerBoardState = { status: LeaderboardStatus; rows: LeaderboardRow[]; refreshing: boolean };

export function FilteredLeaderboard({
  main,
  meId,
  god,
  faces,
  readLevel,
}: {
  main: { status: LeaderboardStatus; rows: LeaderboardRow[]; refreshing: boolean; onRefresh: () => void };
  meId: string | null;
  god: GodAvatar;
  faces: Record<ComputerLevel, ComputerFace>;
  readLevel: (level: ComputerLevel) => Promise<{ ok: true; data: unknown[] } | { ok: false }>;
}) {
  const search = useSyncExternalStore(subscribeToLocation, searchFromUrl, searchOnServer);
  const filter = useMemo(() => filterFromSearch(search), [search]);
  const level = filter.kind === "computer" ? filter.level : null;
  const chips = useMemo(() => leaderboardChips(faces), [faces]);

  const [boards, setBoards] = useState<Partial<Record<ComputerLevel, ComputerBoardState>>>({});

  // Reads one level's board. Keeps the rows on screen while it reads; a
  // failure with rows already shown leaves them (as the main board does).
  const loadLevel = useCallback(
    async (which: ComputerLevel) => {
      setBoards((prev) => ({
        ...prev,
        [which]: prev[which] ? { ...prev[which], refreshing: true } : { status: "loading", rows: [], refreshing: true },
      }));
      const result = await readLevel(which);
      setBoards((prev) => {
        const current = prev[which];
        const next: ComputerBoardState = result.ok
          ? { status: "ready", rows: result.data as LeaderboardRow[], refreshing: false }
          : { status: current?.status === "ready" ? "ready" : "error", rows: current?.rows ?? [], refreshing: false };
        return { ...prev, [which]: next };
      });
    },
    [readLevel]
  );

  // The first time a computer board is on screen (a chip, or a shared link).
  const needsRead = level !== null && boards[level] === undefined;
  useEffect(() => {
    if (level === null || !needsRead) return;
    let cancelled = false;
    // Deferred a tick, so no state is set synchronously inside the effect.
    Promise.resolve().then(() => {
      if (!cancelled) loadLevel(level);
    });
    return () => {
      cancelled = true;
    };
  }, [level, needsRead, loadLevel]);

  function select(next: LeaderboardFilter) {
    const query = searchForFilter(window.location.search, next);
    window.history.replaceState(null, "", `${window.location.pathname}${query}${window.location.hash}`);
    window.dispatchEvent(new Event(LOCATION_EVENT));
  }

  function refresh() {
    if (level === null) {
      setBoards({});
      main.onRefresh();
      return;
    }
    setBoards((prev) => (prev[level] ? { [level]: prev[level] } : {}));
    loadLevel(level);
  }

  const filterBar = <LeaderboardFilterBar chips={chips} selected={filter} onSelect={select} />;

  if (level === null) {
    return (
      <LeaderboardPanel
        status={main.status}
        rows={main.rows}
        meId={meId}
        god={god}
        refreshing={main.refreshing}
        onRefresh={refresh}
        filterBar={filterBar}
      />
    );
  }

  const board = boards[level];
  return (
    <LeaderboardPanel
      status={board?.status ?? "loading"}
      rows={board?.rows ?? []}
      meId={meId}
      god={god}
      refreshing={board?.refreshing ?? false}
      onRefresh={refresh}
      filterBar={filterBar}
      board={computerBoardText(faces[level].name)}
    />
  );
}
