// "Spectators allowed" (PRD item 40): a table whose host ticked Allow
// spectators says so to its players, so nobody is watched by surprise.
//   * "full": the pill, in the muggins-tag style -- the waiting screens
//     (WaitingForPlayer, WaitingRoom), before anyone watches.
//   * "icon": the bare eye glyph (the chat card's spectator mark uses
//     SpectatorEyeGlyph). The words are its tooltip and are read by screen
//     readers.
// In the game header the eye is SpectatorsEye below: shown only while
// someone is watching, with the count, and it opens the spectators list.
export function SpectatorsTag({ variant = "full" }: { variant?: "full" | "icon" }) {
  if (variant === "icon") {
    return (
      <span className="spectators-icon" title="Spectators allowed" data-testid="spectators-tag">
        <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden="true" focusable="false">
          <path
            d="M8 3.5C4.6 3.5 2 6.1 1 8c1 1.9 3.6 4.5 7 4.5s6-2.6 7-4.5c-1-1.9-3.6-4.5-7-4.5Z"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.4"
            strokeLinejoin="round"
          />
          <circle cx="8" cy="8" r="2.1" fill="currentColor" />
        </svg>
        <span className="sr-only">Spectators allowed</span>
      </span>
    );
  }
  return (
    <span className="muggins-tag" data-testid="spectators-tag">
      Spectators allowed
    </span>
  );
}

// The eye, drawn alone: 14px, aria-hidden (the caller says what it means).
export function SpectatorEyeGlyph({ size = 14 }: { size?: number }) {
  return (
    <svg viewBox="0 0 16 16" width={size} height={size} aria-hidden="true" focusable="false">
      <path
        d="M8 3.5C4.6 3.5 2 6.1 1 8c1 1.9 3.6 4.5 7 4.5s6-2.6 7-4.5c-1-1.9-3.6-4.5-7-4.5Z"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinejoin="round"
      />
      <circle cx="8" cy="8" r="2.1" fill="currentColor" />
    </svg>
  );
}

// THE HEADER'S EYE (spectator chat): only while at least one current
// spectator is watching (the caller passes the count from
// get_table_spectators; 0 renders nothing), with the count beside it. A
// button: it opens the spectators list (names and avatars, with Mute,
// Report and the host's Kick). Drawn small beside "Table CODE" on every
// table, a Muggins one too; its tap target is 44x44 (.spectators-eye).
export function SpectatorsEye({ count, onOpen }: { count: number; onOpen?: () => void }) {
  if (count <= 0) return null;
  const label = `${count} watching. Show spectators`;
  return (
    <button
      type="button"
      onClick={onOpen}
      aria-label={label}
      aria-haspopup="dialog"
      title={`${count} watching`}
      className="spectators-eye"
      data-testid="spectators-eye"
    >
      <SpectatorEyeGlyph size={14} />
      <span aria-hidden="true">{count}</span>
    </button>
  );
}

// "Watching": a thin row under a spectator's header (the header itself is
// the players' own). Text only, no button: Leave in the header stops
// watching.
export function WatchingRow() {
  return (
    <p className="watching-row" data-testid="watching-row">
      <SpectatorEyeGlyph size={12} />
      Watching
    </p>
  );
}
