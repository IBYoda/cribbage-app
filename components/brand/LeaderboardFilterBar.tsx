"use client";

import { useEffect, useRef } from "react";
import { Avatar } from "@/components/Avatar";
import { sameFilter, type LeaderboardChip, type LeaderboardFilter } from "@/lib/leaderboardFilter";

// THE LEADERBOARD'S FILTER CHIPS (PRD item 35, slice S4): one row of toggle
// buttons under the title -- Multiplayer, then God, Rainman, Normie and
// Shortbus with their avatars -- that scrolls sideways on a phone with no
// visible scrollbar (.leaderboard-filters). The chips come from a list
// (leaderboardChips, lib/leaderboardFilter.ts), so a Friends chip is one more
// entry there. Each is a real button with aria-pressed; the chosen one is
// filled in brass. The chosen chip is scrolled into view, so a shared link to
// the last chip shows it selected.
export function LeaderboardFilterBar({
  chips,
  selected,
  onSelect,
}: {
  chips: readonly LeaderboardChip[];
  selected: LeaderboardFilter;
  onSelect: (filter: LeaderboardFilter) => void;
}) {
  const selectedRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    // Sideways only: never moves the page up or down.
    const chip = selectedRef.current;
    const row = chip?.parentElement;
    if (!chip || !row) return;
    const left = chip.offsetLeft - row.offsetLeft;
    if (left < row.scrollLeft || left + chip.offsetWidth > row.scrollLeft + row.clientWidth) {
      row.scrollTo({ left: Math.max(0, left - 8) });
    }
  }, [selected]);

  return (
    <div className="leaderboard-filters" role="group" aria-label="Show the leaderboard for">
      {chips.map((chip) => {
        const on = sameFilter(chip.filter, selected);
        return (
          <button
            key={chip.id}
            ref={on ? selectedRef : undefined}
            type="button"
            aria-pressed={on}
            onClick={() => onSelect(chip.filter)}
            className={`leaderboard-filter ${on ? "leaderboard-filter--on" : ""}`}
          >
            {chip.avatar && <Avatar name={chip.avatar.name} url={chip.avatar.url} size="xs" />}
            {chip.label}
          </button>
        );
      })}
    </div>
  );
}
