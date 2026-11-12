"use client";

// "FRIENDS ONLY" (PRD item 36, F3): a switch on its own short line under the
// leaderboard's filter chips, for whichever board is selected. The same
// .felt-switch as the Settings page. Disabled while the follow list loads,
// and when it couldn't be read ("Friends unavailable right now"). Under it, a
// polite status line for the star's refusals ("You can follow up to 50
// players..."); empty, it takes no room.
export function FriendsSwitch({
  on,
  disabled,
  unavailable,
  onChange,
  message,
}: {
  on: boolean;
  disabled: boolean;
  unavailable: boolean;
  onChange: (on: boolean) => void;
  message: string | null;
}) {
  return (
    <div className="flex flex-col">
      <div className="flex min-h-7 items-center gap-3">
        <button
          id="friends-only-switch"
          type="button"
          role="switch"
          aria-checked={on}
          aria-describedby={unavailable ? "friends-only-unavailable" : undefined}
          disabled={disabled}
          title={unavailable ? "Friends unavailable right now" : undefined}
          onClick={() => onChange(!on)}
          className="felt-switch"
        />
        <label htmlFor="friends-only-switch" className={`text-sm ${disabled ? "opacity-60" : "cursor-pointer"}`}>
          Friends only
        </label>
        {unavailable && (
          <span id="friends-only-unavailable" className="text-xs text-[var(--brass-light)]">
            Friends unavailable right now
          </span>
        )}
      </div>
      {/* Always in the page (an empty paragraph has no height), so a screen
          reader announces a message when it appears. */}
      <p role="status" aria-live="polite" className={`text-sm text-[var(--brass-light)] ${message ? "mt-1" : ""}`}>
        {message}
      </p>
    </div>
  );
}
