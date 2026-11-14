"use client";

import { useEffect, useId, useLayoutEffect, useRef, useState } from "react";

// THE HIDE COUNTS TOGGLE in the table header: a small "⋯" button, beside the
// speaker, that opens a popover holding the player's own Hide counts setting
// (lib/appearance.ts), the same one as on the Settings page. Folded away to
// make room in the header (it is changed rarely; the speaker, changed often,
// stays out). A tap on the row saves at once -- there is no separate Save --
// and closes the popover. The row's label shows the current state; it
// changes only once the save succeeds, so a failed save leaves the old value,
// with a short "Couldn't save" note under the "⋯" that clears itself. The
// "⋯" is disabled (aria-disabled, so it keeps focus) while saving, never
// stuck: it comes back whether the save succeeds, fails or throws.
//
// The row is a plain button: its visible text IS its state ("Counts: shown" /
// "Counts: hidden"), so a screen reader hears the state once, as its name.
//
// THE POPOVER: over the header's right end -- its top on the header's top,
// its right edge on the header's right edge -- so it never runs off the
// screen, and its 40px row ends above the across player's cards and piles
// (dropped under the header, it hid the top of their crib when they deal).
// It covers the speaker, the "⋯" and Leave while open: z-index 62, above the
// speaker's 61 (.sound-toggle, which sits over the deal overlay's 60). Closes on a tap outside, on Escape (focus back on the "⋯"), on
// tabbing away and after a toggle. Opening it moves focus onto the row.
// Neither it nor the note adds any height to the table.
//
// LOCKED (a Muggins table): nothing to show, so nothing to hide -- renders
// nothing, and the player's own setting is left as it was for their other
// tables. The tag line under the header already says the table is
// Self-Scoring.
export function CountsToggle({
  hidden,
  onSave,
  locked = false,
}: {
  hidden: boolean;
  onSave: (nextHidden: boolean) => Promise<string | null>;
  locked?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [saving, setSaving] = useState(false);
  const [failed, setFailed] = useState(false);
  const menuId = useId();
  const wrapRef = useRef<HTMLSpanElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const rowRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLSpanElement>(null);

  // The note clears itself after a few seconds.
  useEffect(() => {
    if (!failed) return;
    const t = window.setTimeout(() => setFailed(false), 4000);
    return () => window.clearTimeout(t);
  }, [failed]);

  // Placed before it paints (on the header's top right corner), then focus
  // onto the row.
  useLayoutEffect(() => {
    if (!open) return;
    const wrap = wrapRef.current;
    const header = wrap?.closest("header");
    if (wrap && header && menuRef.current) {
      const at = wrap.getBoundingClientRect();
      const edge = header.getBoundingClientRect();
      menuRef.current.style.right = `${-Math.max(0, edge.right - at.right)}px`;
      menuRef.current.style.top = `${edge.top - at.top}px`;
    }
    rowRef.current?.focus();
  }, [open]);

  // A tap anywhere outside closes it; so does Escape.
  useEffect(() => {
    if (!open) return;
    const onDown = (e: PointerEvent) => {
      if (!wrapRef.current?.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      setOpen(false);
      triggerRef.current?.focus();
    };
    document.addEventListener("pointerdown", onDown, true);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("pointerdown", onDown, true);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  if (locked) return null;

  async function handleToggle() {
    setOpen(false);
    triggerRef.current?.focus();
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
    <span
      ref={wrapRef}
      className="relative inline-flex"
      // Tabbing out of the menu closes it.
      onBlur={(e) => {
        if (open && !wrapRef.current?.contains(e.relatedTarget as Node | null)) setOpen(false);
      }}
    >
      <button
        ref={triggerRef}
        type="button"
        aria-label="Table options"
        aria-haspopup="true"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        title="Table options"
        // aria-disabled, not disabled, while saving: a disabled button
        // would drop the keyboard focus the toggle just put back on it.
        onClick={() => {
          if (!saving) setOpen((o) => !o);
        }}
        aria-disabled={saving || undefined}
        className="tap-40 shrink-0 px-1 text-zinc-600 aria-disabled:opacity-50 dark:text-zinc-400"
      >
        {/* A line tall, as tap-40 reckons: three 2px dots in a 16px box. */}
        <svg viewBox="0 0 16 16" className="block h-[1lh] w-4" aria-hidden="true">
          <circle cx="3" cy="8" r="1.5" fill="currentColor" />
          <circle cx="8" cy="8" r="1.5" fill="currentColor" />
          <circle cx="13" cy="8" r="1.5" fill="currentColor" />
        </svg>
      </button>
      {open && (
        <span
          ref={menuRef}
          id={menuId}
          role="menu"
          aria-label="Table options"
          className="absolute right-0 top-0 z-[62] flex flex-col overflow-hidden rounded border border-zinc-300 bg-background shadow-lg dark:border-zinc-700"
        >
          <button
            ref={rowRef}
            type="button"
            role="menuitem"
            onClick={handleToggle}
            className="flex min-h-10 items-center whitespace-nowrap px-2.5 text-left text-xs text-zinc-700 hover:bg-zinc-500/15 focus-visible:bg-zinc-500/15 focus-visible:outline-2 focus-visible:-outline-offset-2 dark:text-zinc-300"
          >
            {hidden ? "Counts: hidden" : "Counts: shown"}
          </button>
        </span>
      )}
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
