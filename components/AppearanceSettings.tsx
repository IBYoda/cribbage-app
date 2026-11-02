"use client";

import { useState } from "react";
import { FaceDownCard, PlayingCard } from "@/components/PlayingCard";
import { useAppearance } from "@/components/AppearanceProvider";
import { setDealAnimationOn, useDealAnimationOn } from "@/components/table/DealAnimation";
import {
  CribbageBoard,
  setBoardPattern,
  setBoardSkin,
  useBoardPattern,
  useBoardSkin,
  type BoardPlayer,
} from "@/components/table/CribbageBoard";
import type { BoardPattern } from "@/lib/boardLayout";
import { BOARD_SKIN_LIST } from "@/lib/boardSkins";
import {
  CARD_BACKS,
  TABLE_SURFACES,
  surfaceIsDark,
  type Appearance,
  type CardBack,
  type TableSurface,
} from "@/lib/appearance";

// THE APPEARANCE SECTION of the Profile page: this player's table surface and
// card back, for THEIR OWN screen only. Its own Save, separate from Save
// Profile, so changing a card back never re-uploads an avatar.
//
// The swatches and the preview use the very same CSS as the table
// (.surface-swatch shares each surface's rule in app/globals.css, and the
// card backs come from data-back exactly as on the table), so what you pick
// here is what the table shows. All six back images load on this page only.

// The board previews: three players' pegs, one in each lane.
const PREVIEW_SIZE = { w: 375, h: 67 };
const PREVIEW_PLAYERS: BoardPlayer[] = [
  { userId: "a", name: "First seat", lane: 0, score: 38, lastPoints: 4 },
  { userId: "b", name: "Second seat", lane: 1, score: 27, lastPoints: 6 },
  { userId: "c", name: "Third seat", lane: 2, score: 15, lastPoints: 2 },
];
const BOARD_PATTERN_CHOICES: { id: BoardPattern; label: string }[] = [
  { id: "straight", label: "Straight" },
  { id: "s", label: "S" },
  { id: "snake", label: "Snake" },
];

export function AppearanceSettings() {
  const appearance = useAppearance();
  const dealAnimationOn = useDealAnimationOn();
  const boardSkin = useBoardSkin();
  const boardPattern = useBoardPattern();
  const saved: Appearance = {
    surface: appearance.surface,
    back: appearance.back,
    hideCounts: appearance.hideCounts,
  };

  // Unsaved picks; null = nothing changed (shows the saved choice).
  const [draft, setDraft] = useState<Appearance | null>(null);
  const [status, setStatus] = useState<"idle" | "saving" | "saved" | "error">("idle");
  const [message, setMessage] = useState<string | null>(null);

  const shown = draft ?? saved;
  const changed =
    draft !== null &&
    (draft.surface !== saved.surface || draft.back !== saved.back || draft.hideCounts !== saved.hideCounts);

  function pick(next: Partial<Appearance>) {
    setDraft({ ...shown, ...next });
    setStatus("idle");
    setMessage(null);
  }

  async function handleSave() {
    if (!draft || !changed) return;
    setStatus("saving");
    setMessage(null);
    const error = await appearance.save(draft);
    if (error) {
      // The saved look stays applied; the picks stay on screen to retry.
      setStatus("error");
      setMessage(`Couldn't save your appearance: ${error}`);
      return;
    }
    setDraft(null);
    setStatus("saved");
  }

  return (
    <section className="flex w-full flex-col gap-4" aria-labelledby="appearance-heading">
      <h2 id="appearance-heading" className="font-display text-2xl font-bold italic">
        Appearance
      </h2>
      <p className="-mt-3 text-sm">
        Your table and card backs -- only you see them.
      </p>

      {/* THE PREVIEW: a slice of table in the chosen surface, with a face-down
          card in the chosen back, a face-up card and the accent pill. */}
      <div
        className="surface-swatch flex h-28 items-center justify-center gap-3 rounded-lg border border-zinc-300 dark:border-zinc-700"
        data-surface={shown.surface}
        data-scheme={surfaceIsDark(shown.surface) ? "dark" : undefined}
        data-back={shown.back}
        aria-label="Preview of your table"
      >
        <div className="w-14">
          <FaceDownCard sizing="w-full aspect-[5/7]" />
        </div>
        <div className="w-14">
          <PlayingCard card="7H" sizing="w-full aspect-[5/7]" />
        </div>
        <span className="rounded-full bg-green-600 px-2.5 py-0.5 text-xs font-semibold text-white surface:bg-violet-600">
          Your turn
        </span>
      </div>

      <fieldset className="flex flex-col gap-2" disabled={!appearance.ready || status === "saving"}>
        <legend className="mb-2 text-sm font-medium">Table surface</legend>
        <div className="grid grid-cols-4 gap-2">
          {TABLE_SURFACES.map((surface) => (
            <label key={surface.id} className="flex cursor-pointer flex-col items-center gap-1 text-center">
              <input
                type="radio"
                name="table-surface"
                value={surface.id}
                checked={shown.surface === surface.id}
                onChange={() => pick({ surface: surface.id as TableSurface })}
                className="peer sr-only"
              />
              <span
                className="surface-swatch block h-10 w-full rounded-md border-2 border-white/25 bg-background peer-checked:border-[var(--cream)] peer-checked:ring-2 peer-checked:ring-[var(--brass)] peer-checked:ring-offset-2 peer-checked:ring-offset-transparent peer-focus-visible:outline peer-focus-visible:outline-2 peer-focus-visible:outline-offset-4 peer-focus-visible:outline-[var(--brass-light)]"
                data-surface={surface.id}
                aria-hidden="true"
              />
              <span className="text-xs peer-checked:font-semibold">{surface.label}</span>
            </label>
          ))}
        </div>
      </fieldset>

      <fieldset className="flex flex-col gap-2" disabled={!appearance.ready || status === "saving"}>
        <legend className="mb-2 text-sm font-medium">Card back</legend>
        <div className="grid grid-cols-4 gap-2">
          {CARD_BACKS.map((back) => (
            <label key={back.id} className="flex cursor-pointer flex-col items-center gap-1 text-center">
              <input
                type="radio"
                name="card-back"
                value={back.id}
                checked={shown.back === back.id}
                onChange={() => pick({ back: back.id as CardBack })}
                className="peer sr-only"
              />
              <span
                className="block w-12 rounded-lg p-0.5 ring-offset-2 ring-offset-transparent peer-checked:ring-2 peer-checked:ring-[var(--cream)] peer-focus-visible:outline peer-focus-visible:outline-2 peer-focus-visible:outline-offset-4 peer-focus-visible:outline-[var(--brass-light)]"
                data-back={back.id}
                aria-hidden="true"
              >
                <FaceDownCard sizing="w-full aspect-[5/7]" />
              </span>
              <span className="text-xs leading-tight peer-checked:font-semibold">{back.label}</span>
            </label>
          ))}
        </div>
      </fieldset>

      {/* COUNT NUMBERS: Hide counts, for this player's own screen only. The
          table header has the same switch, which saves at once; this one is
          saved with the rest by Save Appearance. */}
      <fieldset className="flex flex-col gap-2" disabled={!appearance.ready || status === "saving"}>
        <legend className="mb-2 text-sm font-medium">Count numbers</legend>
        <div className="flex items-center gap-3">
          <button
            id="hide-counts-switch"
            type="button"
            role="switch"
            aria-checked={shown.hideCounts}
            aria-describedby="hide-counts-hint"
            onClick={() => pick({ hideCounts: !shown.hideCounts })}
            className="felt-switch"
          />
          <label htmlFor="hide-counts-switch" className="cursor-pointer text-sm">
            Hide counts
          </label>
        </div>
        <p id="hide-counts-hint" className="text-sm">
          Hide the hand and crib point numbers on your screen. The score strip stays.
        </p>
      </fieldset>

      {/* CARD ANIMATIONS (the deal and the discard toss): this device only
          (localStorage, no account column), so it saves at once, not with
          Save Appearance. Off: a new hand just appears and discards go
          straight to the crib, as with the system's reduced motion. */}
      <fieldset className="flex flex-col gap-2">
        <legend className="mb-2 text-sm font-medium">Animations</legend>
        <div className="flex items-center gap-3">
          <button
            id="deal-animation-switch"
            type="button"
            role="switch"
            aria-checked={dealAnimationOn}
            aria-describedby="deal-animation-hint"
            onClick={() => setDealAnimationOn(!dealAnimationOn)}
            className="felt-switch"
          />
          <label htmlFor="deal-animation-switch" className="cursor-pointer text-sm">
            Card animations
          </label>
        </div>
        <p id="deal-animation-hint" className="text-sm">
          Cards fly from the dealer&apos;s deck at the start of each hand, and discards fly to the crib. Saved on
          this device only, at once.
        </p>
      </fieldset>

      {/* BOARD: the cribbage board on the square table, for this player's
          own screen -- this device only (localStorage), so it saves at once,
          like Card animations. Two choices: the PATTERN (the track's shape:
          Straight, S or Snake), previewed in the chosen colours, and the COLORS (the
          six skins), listed one board a row and previewed in the chosen
          pattern. Each preview is the real board, drawn at a phone's strip
          size (375 x 67) and scaled to its box, so its pegs and lanes read as
          on the table. */}
      <fieldset className="flex flex-col gap-2">
        <legend className="mb-2 text-sm font-medium">Board</legend>
        <fieldset className="flex flex-col gap-2">
          <legend className="mb-1 text-xs font-medium">Pattern</legend>
          <div className="grid grid-cols-3 gap-2">
            {BOARD_PATTERN_CHOICES.map((choice) => (
              <label key={choice.id} className="flex cursor-pointer flex-col items-center gap-1 text-center">
                <input
                  type="radio"
                  name="board-pattern"
                  value={choice.id}
                  checked={boardPattern === choice.id}
                  onChange={() => setBoardPattern(choice.id)}
                  className="peer sr-only"
                />
                <span
                  className="block w-full rounded-md p-0.5 ring-offset-2 ring-offset-transparent peer-checked:ring-2 peer-checked:ring-[var(--cream)] peer-focus-visible:outline peer-focus-visible:outline-2 peer-focus-visible:outline-offset-4 peer-focus-visible:outline-[var(--brass-light)]"
                  aria-hidden="true"
                >
                  <CribbageBoard
                    skin={boardSkin}
                    pattern={choice.id}
                    players={PREVIEW_PLAYERS}
                    fixedSize={PREVIEW_SIZE}
                  />
                </span>
                <span className="text-xs leading-tight peer-checked:font-semibold">{choice.label}</span>
              </label>
            ))}
          </div>
          <p className="text-xs">S and Snake are 3-lane boards: 4-player Solo games use Straight.</p>
        </fieldset>
        <fieldset className="flex flex-col gap-2">
          <legend className="mb-1 text-xs font-medium">Colors</legend>
          <div className="flex flex-col gap-3">
          {BOARD_SKIN_LIST.map((skin) => (
            <label key={skin.id} className="flex cursor-pointer flex-col items-center gap-1 text-center">
              <input
                type="radio"
                name="board-skin"
                value={skin.id}
                checked={boardSkin.id === skin.id}
                onChange={() => setBoardSkin(skin.id)}
                className="peer sr-only"
              />
              <span
                className="block w-full rounded-md p-0.5 ring-offset-2 ring-offset-transparent peer-checked:ring-2 peer-checked:ring-[var(--cream)] peer-focus-visible:outline peer-focus-visible:outline-2 peer-focus-visible:outline-offset-4 peer-focus-visible:outline-[var(--brass-light)]"
                aria-hidden="true"
              >
                <CribbageBoard skin={skin} pattern={boardPattern} players={PREVIEW_PLAYERS} fixedSize={PREVIEW_SIZE} />
              </span>
              <span className="text-xs leading-tight peer-checked:font-semibold">{skin.name}</span>
            </label>
          ))}
          </div>
        </fieldset>
        <p className="text-sm">
          The board on your table -- only you see it. Saved on this device only, at once.
        </p>
      </fieldset>

      <button
        type="button"
        onClick={handleSave}
        disabled={!changed || status === "saving" || !appearance.ready}
        className="peg-btn peg-btn--brass disabled:opacity-60"
      >
        {status === "saving" ? "Saving..." : "Save Appearance"}
      </button>

      <p role="status" className="min-h-5 text-sm">
        {status === "saved" && <span className="text-[var(--success-on-felt)]">Saved.</span>}
        {status === "error" && message && <span className="text-[var(--error-on-felt)]">{message}</span>}
      </p>
    </section>
  );
}
