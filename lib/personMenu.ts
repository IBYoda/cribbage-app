// THE PERSON POPUP (moderation M2b/M2c): the one popup window for another
// person at the table -- from their seat (avatar or name) and their chat
// card's "..." -- plus the spectator list's inline buttons, the chat
// composer's "Muted:" line and the "Also block?" question after a Mute. Pure
// rules here (no React, no Supabase); the components and the shared store
// are components/table/PersonMenu.tsx. Tested by scripts/test-phase3.ts.
//
// Its buttons, by what I already did to that person and who I am:
//   everyone:  "Mute" (not muted) or "Unmute" (muted) -- just the word --
//              then "Report" (moderation M6: lib/reports.ts)
//   the HOST:  also "Kick", last
// Mute is PERSONAL (it changes only what I see, the host's too), kept for
// this table on this browser (lib/chatMute.ts). There is no Block or Unblock
// button at the table: Block only comes from the question after a Mute or a
// spectator's Kick (or the Profile page, by exact nickname); Unblock is on
// the Profile page only. Never on my own seat, row or card, and never at a
// computer table.

export type PersonAction = "mute" | "unmute" | "report" | "kick";

export function personPopupButtons(state: { muted: boolean; isHost: boolean }): { action: PersonAction; label: string }[] {
  const mute: { action: PersonAction; label: string } = state.muted ? { action: "unmute", label: "Unmute" } : { action: "mute", label: "Mute" };
  const report: { action: PersonAction; label: string } = { action: "report", label: "Report" };
  return state.isHost ? [mute, report, { action: "kick", label: "Kick" }] : [mute, report];
}

// The spectator list's inline buttons for another person's row, in order:
// the same as the popup's (Mute/Unmute, Report, the host's Kick).
export function spectatorRowButtons(state: { muted: boolean; isHost: boolean }): PersonAction[] {
  return personPopupButtons(state).map((b) => b.action);
}

// The host's Kick (moderation M3) is the real one for a player or a
// spectator alike: lib/kicks.ts (the confirm, the notice, writeKick).

// Whether this person gets a menu at all: a real other person, while the
// table offers it (signed in, a human table).
export function canOfferPersonMenu(input: { userId: string | null | undefined; myUserId: string | null; enabled: boolean }): boolean {
  return input.enabled && !!input.myUserId && !!input.userId && input.userId !== input.myUserId;
}

// THE QUESTION AFTER A MUTE (never after Unmute) or a spectator's
// successful Kick: "Also block <name>?" --
// skipped entirely when they are already on my Block List. Closing it
// (Escape, a tap outside) is "No, thanks": the Mute stays either way.
export function shouldAskToBlock(state: { blocked: boolean }): boolean {
  return !state.blocked;
}

export function blockQuestion(name: string): { title: string; body: string; yesLabel: string; noLabel: string } {
  return {
    title: `Also block ${name}?`,
    body:
      "Blocked players can't join or watch tables you start, and you won't see their chat anywhere. " +
      'You can review or remove anyone later on your Profile page under "Blocked players."',
    yesLabel: "Yes, block",
    noLabel: "No, thanks",
  };
}

// THE QUIET MARK on a muted person's avatar: "blocked" wins over "muted"
// (a blocked person is muted whether or not they are also muted here).
export type MutedMark = "blocked" | "muted" | null;

export function mutedMark(state: { muted: boolean; blocked: boolean }): MutedMark {
  return state.blocked ? "blocked" : state.muted ? "muted" : null;
}

// The words a screen reader hears after the name for that mark.
export function mutedMarkText(mark: MutedMark): string {
  return mark === "blocked" ? " (blocked)" : mark === "muted" ? " (muted in chat)" : "";
}

// THE COMPOSER'S LINE: the people at THIS table (seated or watching, from
// the chat roster, never me) whom I have muted, in roster order, each once.
export function mutedAtTable(
  roster: readonly { user_id: string; nickname: string | null }[],
  muted: ReadonlySet<string>,
  myUserId: string | null
): { userId: string; name: string }[] {
  const seen = new Set<string>();
  const out: { userId: string; name: string }[] = [];
  for (const r of roster) {
    if (r.user_id === myUserId || !muted.has(r.user_id) || seen.has(r.user_id)) continue;
    seen.add(r.user_id);
    out.push({ userId: r.user_id, name: r.nickname?.trim() || "Unnamed player" });
  }
  return out;
}
