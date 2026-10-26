import { Avatar } from "@/components/Avatar";
import { LEVEL_INFO, type ComputerLevel } from "@/lib/computer/config";

const ORDER: ComputerLevel[] = ["easy", "medium", "hard"];

// THE COMPUTER CHOICES (the single-player screen, app/single-player): one
// card per computer -- a real radio inside its label, like Start a Table's
// option cards (.option-card) -- with the computer's name first, then the
// level and its tagline (LEVEL_INFO), and its avatar on the right, a round
// crop with nothing behind it. Presentational: the page owns the choice and
// reads the avatars.
export function OpponentChooser({
  level,
  onLevelChange,
  avatars,
}: {
  level: ComputerLevel;
  onLevelChange: (level: ComputerLevel) => void;
  avatars: Partial<Record<ComputerLevel, string | null>>;
}) {
  return (
    <fieldset className="flex flex-col gap-2.5">
      <legend className="sr-only">Opponent</legend>
      {ORDER.map((id) => (
        <label key={id} className="option-card">
          <input
            type="radio"
            name="computer-level"
            value={id}
            checked={level === id}
            onChange={() => onLevelChange(id)}
            className="sr-only"
          />
          <span className="option-dot" aria-hidden="true" />
          <span className="flex min-w-0 flex-1 flex-col leading-tight">
            <span className="text-lg font-bold">{LEVEL_INFO[id].name}</span>
            <span className="text-sm font-semibold">{LEVEL_INFO[id].label}</span>
            <span className="text-xs font-semibold text-[var(--brass-light)]">{LEVEL_INFO[id].tagline}</span>
          </span>
          <Avatar name={LEVEL_INFO[id].name} url={avatars[id] ?? null} size="lg" />
        </label>
      ))}
    </fieldset>
  );
}
