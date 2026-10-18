"use client";

import { useEffect, useState } from "react";

// THE HIDE COUNTS TOGGLE in the table header, beside Leave: the player's own
// Hide counts setting (lib/appearance.ts), the same one as on the Profile
// page. A tap saves at once -- there is no separate Save. The label shows the
// current state; it changes only once the save succeeds, so a failed save
// leaves the old value showing, with a short "Couldn't save" note under the
// button that clears itself. Disabled while saving, never stuck: the button
// comes back whether the save succeeds, fails or throws.
//
// A plain button: its visible text IS its state ("Counts: shown" /
// "Counts: hidden"), so a screen reader hears the state once, as the
// button's name -- no switch role or aria-checked on top of it.
//
// The note is positioned under the header, so neither it nor the button
// adds any height to the table.
export function CountsToggle({
  hidden,
  onSave,
}: {
  hidden: boolean;
  onSave: (nextHidden: boolean) => Promise<string | null>;
}) {
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState(false);

  // The note clears itself after a few seconds.
  useEffect(() => {
    if (!failed) return;
    const t = window.setTimeout(() => setFailed(false), 4000);
    return () => window.clearTimeout(t);
  }, [failed]);

  async function handleClick() {
    setSaving(true);
    setFailed(false);
    let error: string | null;
    try {
      error = await onSave(!hidden);
    } catch {
      error = "failed";
    }
    setSaving(false);
    if (error) setFailed(true);
  }

  return (
    <span className="relative inline-flex">
      <button
        type="button"
        onClick={handleClick}
        disabled={saving}
        className="tap-40 whitespace-nowrap px-1 text-xs text-zinc-600 underline disabled:opacity-50 dark:text-zinc-400"
      >
        {hidden ? "Counts: hidden" : "Counts: shown"}
      </button>
      <span role="status" className="absolute right-0 top-full z-20 mt-1">
        {failed && (
          <span className="block whitespace-nowrap rounded bg-red-600 px-2 py-0.5 text-xs text-white shadow">
            Couldn&apos;t save
          </span>
        )}
      </span>
    </span>
  );
}
