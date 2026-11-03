"use client";

import type { MugginsPlateState } from "@/lib/mugginsPlates";

// THE SELF-SCORING PLATES (3 and 4 players): in the score plates' slot of
// the square table, the plates themselves are the win controls -- my plate
// is my button ("I win", "Waiting… (tap to cancel)", "Confirm loss",
// "✓ Confirmed"), the others say who claims the win and who has confirmed
// it, and on the final board the winner's says "Won". What each plate says
// and does comes from mugginsPlateStates (lib/mugginsPlates.ts); the table
// page makes the calls (claim_win, clear_win_claim, confirm_win), as it does
// for the 2-player win bar (MugginsWinBar), which 2-player tables keep.
//
// The plates' own sizes: 48px tall, equal widths. Three plates are drawn
// like the 3-plate score strip (name on the left, the plate's word where the
// score would be); four like the 4-plate one (ScoreStrip's stacked row: the
// name, 11px, over the word). Names end in an ellipsis, the full name in the
// tooltip. A refused call shows as the red pill above the plates, adding no
// height (as the win bar's does).
export function MugginsPlates({
  plates,
  busy,
  error,
  onClaim,
  onCancel,
  onConfirm,
}: {
  plates: MugginsPlateState[];
  // A call of mine is in flight: my plate waits.
  busy: boolean;
  error: string | null;
  onClaim: () => void;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  const stacked = plates.length === 4;
  // Who the claim is still waiting for (the tooltips): every player but the
  // claimant who hasn't confirmed.
  const claimant = plates.find((p) => p.kind === "claims" || p.kind === "waiting");
  const waitingFor = claimant
    ? plates
        .filter((p) => p.userId !== claimant.userId && !p.tick && p.kind !== "confirmed-mine")
        .map((p) => (p.mine ? "you" : p.name))
    : [];

  return (
    <div className="relative">
      {/* Above the plates, adding no height: a refused call. */}
      <p role="status" className="pointer-events-none absolute inset-x-0 bottom-full mb-1 truncate text-center text-xs font-medium">
        {error ? <span className="rounded bg-red-600 px-2 py-0.5 text-white shadow">{error}</span> : null}
      </p>
      {/* Equal columns, whatever each plate's border (my button's is 2px). */}
      <div
        className="grid h-12 gap-1"
        style={{ gridTemplateColumns: `repeat(${plates.length}, minmax(0, 1fr))` }}
        role="group"
        aria-label="Win claim"
      >
        {plates.map((plate) =>
          plate.mine && plate.action ? (
            <MyPlateButton
              key={plate.userId}
              plate={plate}
              stacked={stacked}
              busy={busy}
              title={plate.kind === "waiting" && waitingFor.length > 0 ? `Waiting for ${waitingFor.join(", ")}` : undefined}
              onClick={plate.action === "claim" ? onClaim : plate.action === "cancel" ? onCancel : onConfirm}
            />
          ) : (
            <PlateBox
              key={plate.userId}
              plate={plate}
              stacked={stacked}
              title={
                plate.kind === "confirmed-mine" && waitingFor.length > 0 ? `Waiting for ${waitingFor.join(", ")}` : undefined
              }
            />
          )
        )}
      </div>
    </div>
  );
}

// Primary (filled) when it is the thing to tap; dashed while my claim waits.
const FILLED = "bg-foreground text-background border-foreground";
const OUTLINED = "border-zinc-400 dark:border-zinc-600";

function MyPlateButton({
  plate,
  stacked,
  busy,
  title,
  onClick,
}: {
  plate: MugginsPlateState;
  stacked: boolean;
  busy: boolean;
  title?: string;
  onClick: () => void;
}) {
  const waiting = plate.kind === "waiting";
  return (
    <button
      type="button"
      aria-pressed={waiting}
      disabled={busy}
      title={busy ? "Sending…" : title}
      onClick={onClick}
      data-muggins-plate={plate.kind}
      className={`flex min-h-11 min-w-0 flex-1 flex-col items-center justify-center rounded-lg border-2 text-center font-semibold leading-tight disabled:opacity-40 ${
        stacked ? "px-1 text-xs" : "px-2 text-sm"
      } ${waiting ? `${OUTLINED} border-dashed` : FILLED}`}
    >
      {waiting ? (
        <>
          <span className="max-w-full truncate">Waiting…</span>
          <span className="text-[11px] font-normal">(tap to cancel)</span>
        </>
      ) : (
        plate.label
      )}
    </button>
  );
}

// A plate that isn't a button: someone else's, or mine with nothing to tap
// ("✓ Confirmed", the final board).
function PlateBox({ plate, stacked, title }: { plate: MugginsPlateState; stacked: boolean; title?: string }) {
  const confirmedMine = plate.kind === "confirmed-mine";
  const won = plate.kind === "won" || plate.kind === "won-mine";
  const border = plate.mine
    ? "border-zinc-500 bg-zinc-100 dark:border-zinc-400 dark:bg-zinc-800"
    : "border-zinc-300 dark:border-zinc-700";

  // Mine, confirmed: just its words, centred, as the button was.
  if (confirmedMine) {
    return (
      <div
        data-muggins-plate={plate.kind}
        title={title}
        className={`flex min-w-0 flex-1 items-center justify-center rounded-lg border-2 text-center font-semibold leading-tight ${OUTLINED} ${
          stacked ? "px-1 text-xs" : "px-2 text-sm"
        }`}
      >
        {plate.label}
      </div>
    );
  }

  const name = (
    <span className="flex min-w-0 items-center gap-1">
      <span className="truncate" title={plate.name}>
        {plate.name}
        {plate.mine && <span className="text-zinc-500"> (you)</span>}
      </span>
      {plate.tick && (
        <span className="shrink-0 font-bold text-emerald-700 dark:text-emerald-400 surface:text-emerald-300" aria-label="confirmed" title="Confirmed">
          ✓
        </span>
      )}
    </span>
  );
  const word = plate.label ? (
    <span className={`font-semibold leading-tight ${won ? "text-emerald-700 dark:text-emerald-400 surface:text-emerald-300" : ""}`}>
      {plate.label}
    </span>
  ) : null;

  return stacked ? (
    <div
      data-muggins-plate={plate.kind}
      className={`flex min-w-0 flex-1 flex-col justify-center rounded-lg border px-1.5 text-[11px] font-medium leading-tight ${border}`}
    >
      {name}
      {word && <span className="line-clamp-2">{word}</span>}
    </div>
  ) : (
    <div
      data-muggins-plate={plate.kind}
      className={`flex min-w-0 flex-1 items-center gap-1.5 rounded-lg border px-2 text-xs font-medium ${border}`}
    >
      <span className="min-w-0 flex-1">{name}</span>
      {word && <span className="max-w-[50%] shrink-0 text-right text-[11px]">{word}</span>}
    </div>
  );
}
