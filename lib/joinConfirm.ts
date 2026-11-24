// THE CONFIRM SCREENS (step 3, slice B): "Join table NNNN hosted by X?" and
// "Watch table NNNN hosted by X?". Pure: what the screen shows for a table
// previewed by code. Tested by scripts/test-phase3.ts.
//
// WHEN: only for someone arriving by a bare code -- typed (Join page, Home's
// join box) or an opened code link, bookmark or old URL WITHOUT ?t= -- who
// is not seated there. A code is freed when its table ends and may later
// belong to a stranger's table: the screen is what stops a stale code from
// seating (or making a spectator of) anyone without them seeing whose table
// it is. Never shown when already seated (the preview answers
// already_seated), never for in-app links (Open Tables rows, Rejoin, a new
// table, "Go to table"), which carry the table's id (?t=).
//
// THE PREVIEW behind it: join_table_by_code(code, p_preview => true)
// (docs/sql/free-codes-part1.sql). It seats nobody, ends nothing (not a
// single-player game, not watching), isn't counted toward the joins an hour,
// and counts a wrong code toward the lockout like any lookup.
//
// ONE SCREEN, the old pre-seat steps folded in: Play-or-Watch is its Join /
// Watch buttons (so Play is never asked again), and the Self-Scoring
// (Muggins) agreement is its line plus the "Join Self-Scoring (Muggins)
// table" button (tapping it is the agreement). The creator is never asked:
// create_table seats them, so their preview says already_seated.

import { isTableId } from "@/lib/oneTable";

export type JoinPreview = {
  tableId: string;
  code: string;
  status: string;
  endedReason: string | null;
  isPublic: boolean;
  isMuggins: boolean;
  allowSpectators: boolean;
  createdBy: string | null;
  maxPlayers: number;
  teamMode: string | null;
  computerLevel: string | null;
  seatedCount: number;
  gameLive: boolean;
  hostNickname: string | null;
  hostAvatarUrl: string | null;
};

export type PreviewAnswer =
  | { outcome: "preview" | "already_seated"; preview: JoinPreview }
  | { outcome: "not_found" }
  | null; // anything unexpected

// join_table_by_code's row, as the confirm screens use it.
export function previewFromRow(data: unknown): PreviewAnswer {
  const row = (Array.isArray(data) ? data[0] : data) as Record<string, unknown> | null | undefined;
  if (!row) return null;
  if (row.outcome === "not_found") return { outcome: "not_found" };
  if (row.outcome !== "preview" && row.outcome !== "already_seated" && row.outcome !== "joined") return null;
  if (!isTableId(row.table_id) || typeof row.code !== "string") return null;
  const str = (v: unknown) => (typeof v === "string" ? v : null);
  return {
    outcome: row.outcome === "preview" ? "preview" : "already_seated",
    preview: {
      tableId: row.table_id,
      code: row.code,
      status: str(row.status) ?? "open",
      endedReason: str(row.ended_reason),
      isPublic: row.is_public === true,
      isMuggins: row.is_muggins === true,
      allowSpectators: row.allow_spectators === true,
      createdBy: str(row.created_by),
      maxPlayers: typeof row.max_players === "number" ? row.max_players : 2,
      teamMode: str(row.team_mode),
      computerLevel: str(row.computer_level),
      seatedCount: typeof row.seated_count === "number" ? row.seated_count : 0,
      gameLive: row.game_live === true,
      hostNickname: str(row.host_nickname),
      hostAvatarUrl: str(row.host_avatar_url),
    },
  };
}

export const MUGGINS_CONFIRM_LINE =
  "Self-Scoring (Muggins): all scoring is off. The app only deals the cards, so you keep your own score, and these matches don't count toward rankings.";

export type ConfirmView = {
  title: string;
  hostName: string | null;
  badges: string[];
  seatsLine: string;
  // Why there is no seat (full, started, a single-player game) or no
  // watching (not allowed): shown above the buttons.
  notice: string | null;
  // The Self-Scoring agreement, when there is a seat to take there.
  mugginsLine: string | null;
  // The seat: its button's label, or null when there is no seat to take.
  join: { label: string } | null;
  // Watch is offered.
  watch: boolean;
};

export function confirmBadges(p: JoinPreview): string[] {
  const badges: string[] = [];
  if (p.isMuggins) badges.push("Self-Scoring (Muggins)");
  badges.push(`${p.maxPlayers} players`);
  if (p.maxPlayers === 4 && !p.isMuggins) badges.push(p.teamMode === "solo" ? "Solo" : "Teams");
  if (p.allowSpectators) badges.push("Spectators allowed");
  return badges;
}

export function confirmView(p: JoinPreview, mode: "join" | "watch"): ConfirmView {
  const host = p.hostNickname && p.hostNickname.trim() !== "" ? p.hostNickname : null;
  const verb = mode === "join" ? "Join" : "Watch";
  const title = host ? `${verb} table ${p.code} hosted by ${host}?` : `${verb} table ${p.code}?`;
  const base = {
    title,
    hostName: host,
    badges: confirmBadges(p),
    seatsLine: `${p.seatedCount} of ${p.maxPlayers} seats taken`,
  };

  // A single-player table: nobody else can sit there or watch it.
  if (p.computerLevel) {
    return {
      ...base,
      title: `Table ${p.code} is a single-player game.`,
      notice: mode === "join" ? "Only its player can sit there." : "Computer tables cannot be watched.",
      mugginsLine: null,
      join: null,
      watch: false,
    };
  }

  const canWatch = p.allowSpectators;

  if (mode === "watch") {
    return {
      ...base,
      notice: canWatch ? null : "This table doesn't allow spectators.",
      mugginsLine: null,
      join: null,
      watch: canWatch,
    };
  }

  const full = p.seatedCount >= p.maxPlayers;
  if (full || p.gameLive) {
    const why = full ? `Table ${p.code} is full.` : `The game at table ${p.code} has already started.`;
    return {
      ...base,
      notice: canWatch ? `${why} You can watch the game instead.` : `${why} This table doesn't allow spectators.`,
      mugginsLine: null,
      join: null,
      watch: canWatch,
    };
  }

  return {
    ...base,
    notice: null,
    mugginsLine: p.isMuggins ? MUGGINS_CONFIRM_LINE : null,
    join: { label: p.isMuggins ? "Join Self-Scoring (Muggins) table" : "Join" },
    watch: canWatch,
  };
}

// A previewed table can take a NEW seat (the nickname step is asked only then).
export function previewHasSeat(p: JoinPreview): boolean {
  return !p.computerLevel && !p.gameLive && p.seatedCount < p.maxPlayers;
}
