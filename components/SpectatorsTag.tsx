// "Spectators allowed" (PRD item 40): a table whose host ticked Allow
// spectators says so to its players, so nobody is watched by surprise.
//   * "full": the pill, in the muggins-tag style -- the waiting screens, and
//     the header's tag line on a Muggins table (that line is already there).
//   * "icon": a small eye in the header line itself, beside the table code,
//     for a table with no tag line: a line of its own would take ~20px from
//     the middle of every in-game screen. The words are its tooltip and are
//     read by screen readers.
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
