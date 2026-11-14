// "Reconnecting..." in the table header, while the realtime channel is down.
// From 400px wide, the words, as always. Narrower, a small amber dot that
// pulses (steady with reduced motion): the words don't fit beside the
// speaker, the "⋯" and Leave, and they would push Leave off the screen. The
// words stay for screen readers (sr-only) and as the dot's tooltip.
// role="status", so a screen reader announces it as it appears.
//
// beside: Leave is asking to confirm ("End game & leave" + Cancel, which
// take the room the speaker and the "⋯" free). Then only the dot, from 400px
// up, and nothing narrower: the opponent's avatar would be squeezed out.
// Confirming is a moment, and the words come back with Cancel.
export function ReconnectingNote({ beside = false }: { beside?: boolean }) {
  return (
    <span
      role="status"
      title="Reconnecting..."
      className={`inline-flex shrink-0 items-center text-xs text-amber-600 dark:text-amber-500 surface:text-amber-200 ${
        beside ? "max-[399px]:hidden" : ""
      }`}
    >
      <span
        aria-hidden="true"
        className={`block h-2 w-2 rounded-full bg-current motion-safe:animate-pulse ${beside ? "" : "min-[400px]:hidden"}`}
      />
      <span className={beside ? "sr-only" : "max-[399px]:sr-only"}>Reconnecting...</span>
    </span>
  );
}
