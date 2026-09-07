"use client";

import { useState } from "react";

export function PlayerScore({
  score,
  lastPoints,
  lastReason,
  lastAwardedAt,
}: {
  score: number;
  lastPoints: number | null;
  lastReason: string | null;
  lastAwardedAt: string | null;
}) {
  // Flash on CHANGE, not on freshness. The obvious version -- comparing
  // last_awarded_at against Date.now() -- reads a clock during render, which is
  // impure: the same props could render differently depending on when React
  // happened to re-run the component.
  //
  // This is React's "adjusting state when a prop changes" pattern instead. On
  // first render the seen value already equals the incoming one, so a page
  // loaded with an hour-old award does NOT replay it as if it just happened.
  // Only an award arriving after mount -- i.e. over realtime -- flashes.
  const [seenAwardedAt, setSeenAwardedAt] = useState<string | null>(lastAwardedAt);
  const [hasNewAward, setHasNewAward] = useState(false);

  if (lastAwardedAt !== seenAwardedAt) {
    setSeenAwardedAt(lastAwardedAt);
    setHasNewAward(true);
  }

  const showFlash = hasNewAward && lastPoints !== null;

  return (
    <span className="relative inline-flex items-baseline gap-2">
      <span className="text-base font-bold tabular-nums">{score}</span>

      {showFlash && (
        // Keyed on the award timestamp so a second award remounts this and
        // restarts the CSS animation. Without the key it would sit at its
        // finished (hidden) frame and never play again.
        //
        // No timer to hide it: the animation ends at opacity 0 with
        // "forwards", so there is nothing to clean up and no setState in an
        // effect. See .score-flash in globals.css.
        <span
          key={lastAwardedAt}
          className="score-flash absolute left-full ml-2 whitespace-nowrap text-xs font-medium text-green-600 dark:text-green-500"
        >
          {/* Signed, so a future penalty rule reads as "-2" rather than "+-2". */}
          {lastPoints! >= 0 ? `+${lastPoints}` : lastPoints}
          {lastReason ? ` — ${lastReason}` : ""}
        </span>
      )}
    </span>
  );
}
