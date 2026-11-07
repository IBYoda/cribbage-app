"use client";

import { setSoundOn, useSoundOn } from "@/components/SoundProvider";

// THE QUICK MUTE in the table header, beside the Counts toggle: the same
// device-only setting as Profile's Sound switch, saved at once. An icon, so it
// takes 24px from the header: on a phone the across player's name gives way
// first (.sq-header). The tap target is 40px tall (tap-40), and the name and
// aria-pressed never change, so a screen reader hears "Sound, pressed".
// .sound-toggle keeps it above the deal overlay, which takes every other tap:
// under it, a tap would skip the deal and cut its sound while the setting
// stayed as it was, so it sounded muted and could not be unmuted.
export function SoundToggle() {
  const on = useSoundOn();
  return (
    <button
      type="button"
      aria-label="Sound"
      aria-pressed={on}
      title={on ? "Sound on" : "Sound off"}
      onClick={() => setSoundOn(!on)}
      className="sound-toggle tap-40 shrink-0 px-1 text-zinc-600 dark:text-zinc-400"
    >
      {/* A line tall, as tap-40 reckons: the icon stays 16px in the middle. */}
      <svg viewBox="0 0 16 16" className="block h-[1lh] w-4" fill="none" aria-hidden="true">
        <path d="M2 6v4h2.5L8 13V3L4.5 6H2Z" fill="currentColor" />
        {on ? (
          <path d="M10.5 5.5a3.5 3.5 0 0 1 0 5M12.5 3.5a6.3 6.3 0 0 1 0 9" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
        ) : (
          <path d="m10.5 6 4 4m0-4-4 4" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
        )}
      </svg>
    </button>
  );
}
