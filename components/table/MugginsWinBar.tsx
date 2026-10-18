"use client";

// THE MUGGINS WIN BAR: on a Muggins table, in the score strip's place under
// my hand. A Muggins match ends only by agreement: one player taps "I win"
// (claim_win), the other taps "Confirm loss" (confirm_win), which ends the
// match as won by the claimant. The claimant can take the claim back by
// tapping "I win" again (clear_win_claim). The table page decides when the
// bar shows (a live, dealt game only) and makes the calls; this only draws
// the three states from games.win_claim_by.
//
// Same height as the strip (48px) and never taller: the status line ("Elsa
// says they won") and an error sit ABOVE the bar as an overlay, like the
// Hide counts note, so the table never grows. Each disabled button says why
// (title, and aria-describedby for screen readers).
export type WinClaimState = "none" | "mine" | "theirs";

export function MugginsWinBar({
  claim,
  otherName,
  busy,
  error,
  onClaim,
  onCancel,
  onConfirm,
}: {
  claim: WinClaimState;
  // The other player(s), for "Waiting for Elsa…" and "Elsa says they won".
  otherName: string;
  // A call of mine is in flight: both buttons wait.
  busy: boolean;
  error: string | null;
  onClaim: () => void;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  const mine = claim === "mine";
  const winDisabled = busy || claim === "theirs";
  const confirmDisabled = busy || claim !== "theirs";

  const winReason = busy
    ? "Sending…"
    : claim === "theirs"
      ? `${otherName} has claimed the win. Confirm the loss, or wait for them to cancel.`
      : null;
  const confirmReason = busy
    ? "Sending…"
    : claim === "none"
      ? "Nobody has claimed the win."
      : claim === "mine"
        ? `You claimed the win; ${otherName} confirms it.`
        : null;

  // Primary (filled) when it is the thing to tap; outlined otherwise.
  const filled = "bg-foreground text-background border-foreground";
  const outlined = "border-zinc-400 dark:border-zinc-600";

  return (
    <div className="relative">
      {/* Above the bar, adding no height: the claim, or a refused call. */}
      <p
        role="status"
        className="pointer-events-none absolute inset-x-0 bottom-full mb-1 truncate text-center text-xs font-medium"
      >
        {error ? (
          <span className="rounded bg-red-600 px-2 py-0.5 text-white shadow">{error}</span>
        ) : claim === "theirs" ? (
          // A pill, like the error: it sits over the bottom edge of my hand.
          <span id="muggins-claim-status" className="rounded bg-foreground px-2 py-0.5 text-background shadow">
            {otherName} says they won
          </span>
        ) : null}
      </p>

      <div className="flex h-12 gap-1">
        <button
          type="button"
          aria-pressed={mine}
          disabled={winDisabled}
          title={winReason ?? undefined}
          aria-describedby={winReason ? "muggins-win-reason" : undefined}
          onClick={mine ? onCancel : onClaim}
          className={`flex min-h-11 min-w-0 flex-1 flex-col items-center justify-center rounded-lg border-2 px-2 text-sm font-semibold leading-tight disabled:opacity-40 ${
            mine ? `${outlined} border-dashed` : claim === "none" ? filled : outlined
          }`}
        >
          {mine ? (
            <>
              <span className="max-w-full truncate">Waiting for {otherName}…</span>
              <span className="text-xs font-normal">(tap to cancel)</span>
            </>
          ) : (
            "I win"
          )}
        </button>
        <button
          type="button"
          disabled={confirmDisabled}
          title={confirmReason ?? undefined}
          aria-describedby={
            confirmReason ? "muggins-confirm-reason" : claim === "theirs" ? "muggins-claim-status" : undefined
          }
          onClick={onConfirm}
          className={`flex min-h-11 min-w-0 flex-1 items-center justify-center rounded-lg border-2 px-2 text-sm font-semibold disabled:opacity-40 ${
            claim === "theirs" ? filled : outlined
          }`}
        >
          Confirm loss
        </button>
      </div>

      {/* The disabled reasons, for screen readers. */}
      {winReason && (
        <span id="muggins-win-reason" className="sr-only">
          {winReason}
        </span>
      )}
      {confirmReason && (
        <span id="muggins-confirm-reason" className="sr-only">
          {confirmReason}
        </span>
      )}
    </div>
  );
}
