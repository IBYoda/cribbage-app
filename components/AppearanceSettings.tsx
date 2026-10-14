"use client";

import { useState } from "react";
import { FaceDownCard, PlayingCard } from "@/components/PlayingCard";
import { useAppearance } from "@/components/AppearanceProvider";
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
export function AppearanceSettings() {
  const appearance = useAppearance();
  const saved: Appearance = { surface: appearance.surface, back: appearance.back };

  // Unsaved picks; null = nothing changed (shows the saved choice).
  const [draft, setDraft] = useState<Appearance | null>(null);
  const [status, setStatus] = useState<"idle" | "saving" | "saved" | "error">("idle");
  const [message, setMessage] = useState<string | null>(null);

  const shown = draft ?? saved;
  const changed = draft !== null && (draft.surface !== saved.surface || draft.back !== saved.back);

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
        <div className="grid grid-cols-3 gap-2">
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
