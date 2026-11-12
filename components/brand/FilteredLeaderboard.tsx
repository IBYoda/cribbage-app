"use client";

import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { FollowStar } from "@/components/brand/FollowStar";
import { FriendsSwitch } from "@/components/brand/FriendsSwitch";
import { LeaderboardFilterBar } from "@/components/brand/LeaderboardFilterBar";
import {
  LeaderboardPanel,
  type GodAvatar,
  type LeaderboardRow,
  type LeaderboardStatus,
} from "@/components/brand/Leaderboard";
import type { ComputerLevel } from "@/lib/computer/config";
import { followMessage, friendsHint, friendsView, toggledSet, type FollowOutcome } from "@/lib/follows";
import {
  computerBoardText,
  filterFromSearch,
  friendsFromSearch,
  leaderboardChips,
  searchForFilter,
  searchForView,
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
// FRIENDS (PRD item 36, F2 and F3):
//   * THE FOLLOW LIST is read once (readFollows, get_my_follows) and again on
//     Refresh. Until it's read, every star is a dimmed outline; if it can't
//     be read, there are no stars and the switch is disabled.
//   * A STAR flips at once, the call goes out (writeFollow), and the star is
//     disabled until it answers. A refusal flips it back, with a short
//     message under the switch for a few seconds.
//   * FRIENDS ONLY (?friends=1, replaceState like the chips) shows the rows
//     each board already has, kept to a SNAPSHOT of the follow list plus the
//     signed-in player, re-ranked, with no top-20 cut. The snapshot is taken
//     when the list is read, when the switch changes and on Refresh, so a
//     card unfollowed meanwhile stays until then. No board is re-read.
//
// The reads and writes are props, so a dev preview can drive the same
// component with made-up rows, an empty board or a failure.

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
  readFollows,
  writeFollow,
}: {
  main: { status: LeaderboardStatus; rows: LeaderboardRow[]; refreshing: boolean; onRefresh: () => void };
  meId: string | null;
  god: GodAvatar;
  faces: Record<ComputerLevel, ComputerFace>;
  readLevel: (level: ComputerLevel) => Promise<{ ok: true; data: unknown[] } | { ok: false }>;
  readFollows: () => Promise<{ ok: true; data: string[] } | { ok: false }>;
  writeFollow: (userId: string, follow: boolean) => Promise<FollowOutcome>;
}) {
  const search = useSyncExternalStore(subscribeToLocation, searchFromUrl, searchOnServer);
  const filter = useMemo(() => filterFromSearch(search), [search]);
  const friendsAsked = useMemo(() => friendsFromSearch(search), [search]);
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

  // ---- Friends ------------------------------------------------------------
  const [follows, setFollows] = useState<{ status: "loading" | "ready" | "error"; ids: Set<string> }>({
    status: "loading",
    ids: new Set(),
  });
  const [snapshot, setSnapshot] = useState<Set<string>>(() => new Set());
  const [pending, setPending] = useState<Set<string>>(() => new Set());
  const [message, setMessage] = useState<string | null>(null);
  const messageTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Reads the follow list and takes a new snapshot. A failure after a good
  // read keeps the list (as the boards do).
  const loadFollows = useCallback(async () => {
    const result = await readFollows();
    if (result.ok) {
      const ids = new Set(result.data);
      setFollows({ status: "ready", ids });
      setSnapshot(new Set(ids));
    } else {
      setFollows((prev) => (prev.status === "ready" ? prev : { status: "error", ids: new Set() }));
    }
  }, [readFollows]);

  useEffect(() => {
    let cancelled = false;
    // Deferred a tick, so no state is set synchronously inside the effect.
    Promise.resolve().then(() => {
      if (!cancelled) loadFollows();
    });
    return () => {
      cancelled = true;
    };
  }, [loadFollows]);

  useEffect(
    () => () => {
      if (messageTimer.current) clearTimeout(messageTimer.current);
    },
    []
  );

  function showMessage(text: string) {
    if (messageTimer.current) clearTimeout(messageTimer.current);
    setMessage(text);
    messageTimer.current = setTimeout(() => setMessage(null), 4000);
  }

  async function toggleFollow(userId: string) {
    if (follows.status !== "ready" || pending.has(userId)) return;
    const want = !follows.ids.has(userId);
    setFollows((prev) => ({ ...prev, ids: toggledSet(prev.ids, userId, want) }));
    setPending((prev) => toggledSet(prev, userId, true));
    const outcome = await writeFollow(userId, want);
    setPending((prev) => toggledSet(prev, userId, false));
    const problem = followMessage(want, outcome);
    if (problem) {
      setFollows((prev) => ({ ...prev, ids: toggledSet(prev.ids, userId, !want) }));
      showMessage(problem);
    }
  }

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

  function writeUrl(query: string) {
    window.history.replaceState(null, "", `${window.location.pathname}${query}${window.location.hash}`);
    window.dispatchEvent(new Event(LOCATION_EVENT));
  }

  function select(next: LeaderboardFilter) {
    writeUrl(searchForFilter(window.location.search, next));
  }

  function setFriendsOnly(on: boolean) {
    // A fresh snapshot each time the switch changes.
    setSnapshot(new Set(follows.ids));
    writeUrl(searchForView(window.location.search, filter, on));
  }

  function refresh() {
    loadFollows();
    if (level === null) {
      setBoards({});
      main.onRefresh();
      return;
    }
    setBoards((prev) => (prev[level] ? { [level]: prev[level] } : {}));
    loadLevel(level);
  }

  // Friends only is in effect once the follow list is read; a list that
  // can't be read leaves the ordinary board (the switch is disabled).
  const friendsOn = friendsAsked && follows.status === "ready";
  const friendsWaiting = friendsAsked && follows.status === "loading";

  const filterBar = (
    <>
      <LeaderboardFilterBar chips={chips} selected={filter} onSelect={select} />
      <FriendsSwitch
        on={friendsAsked && follows.status !== "error"}
        disabled={follows.status !== "ready"}
        unavailable={follows.status === "error"}
        onChange={setFriendsOnly}
        message={message}
      />
    </>
  );

  const star =
    follows.status === "error"
      ? undefined
      : (row: LeaderboardRow) => (
          <FollowStar
            name={row.nickname}
            following={follows.ids.has(row.user_id)}
            loading={follows.status === "loading"}
            pending={pending.has(row.user_id)}
            onToggle={() => toggleFollow(row.user_id)}
          />
        );

  const board = level === null ? null : boards[level];
  const status: LeaderboardStatus = level === null ? main.status : (board?.status ?? "loading");
  const allRows = level === null ? main.rows : (board?.rows ?? []);
  const rows = friendsOn ? friendsView(allRows, snapshot, meId) : allRows;

  return (
    <LeaderboardPanel
      status={friendsWaiting ? "loading" : status}
      rows={rows}
      meId={meId}
      god={god}
      refreshing={level === null ? main.refreshing : (board?.refreshing ?? false)}
      onRefresh={refresh}
      filterBar={filterBar}
      board={level === null ? undefined : computerBoardText(faces[level].name)}
      shownLimit={friendsOn ? null : undefined}
      star={star}
      note={friendsOn ? friendsHint(rows, snapshot, meId, level === null ? null : faces[level].name) : undefined}
    />
  );
}
