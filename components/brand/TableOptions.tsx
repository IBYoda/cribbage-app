"use client";

import { startTableOptions, type FourPlayerMode } from "@/lib/newTable";

// THE TABLE OPTIONS (Start a Table, app/tables/new/page.tsx; also drawn by
// the dev mock app/dev/start-table-mock): three groups, always all visible.
// Visibility, Scoring and Players are all live and sent (tables.is_public,
// is_muggins, max_players). Every size can be picked with either scoring.
// With 4 players, Team or Solo (team_mode); the pair is greyed out for 2 and
// 3 players (fourPlayerModeOffered) and not shown at all with Self-Scoring,
// which has no Team/Solo -- just a shared deck (startTableOptions).
export function TableOptions({
  isPublic,
  onVisibilityChange,
  isMuggins,
  onMugginsChange,
  maxPlayers,
  onMaxPlayersChange,
  fourPlayerMode,
  onFourPlayerModeChange,
}: {
  isPublic: boolean;
  onVisibilityChange: (isPublic: boolean) => void;
  isMuggins: boolean;
  onMugginsChange: (isMuggins: boolean) => void;
  maxPlayers: 2 | 3 | 4;
  onMaxPlayersChange: (maxPlayers: 2 | 3 | 4) => void;
  fourPlayerMode: FourPlayerMode;
  onFourPlayerModeChange: (mode: FourPlayerMode) => void;
}) {
  const options = startTableOptions(maxPlayers, isMuggins);
  const modeOffered = options.fourPlayerModeOffered;
  return (
    <div className="flex flex-col gap-4">
      <fieldset className="flex flex-col gap-1.5" aria-describedby="visibility-help">
        <legend className="mb-1.5 text-sm font-semibold uppercase tracking-[0.18em] text-[var(--brass-light)]">
          Visibility
        </legend>
        <div className="grid grid-cols-2 gap-2">
          <OptionCard
            name="visibility"
            label="Public"
            checked={isPublic}
            onChange={() => onVisibilityChange(true)}
          />
          <OptionCard
            name="visibility"
            label="Private"
            checked={!isPublic}
            onChange={() => onVisibilityChange(false)}
          />
        </div>
        <p id="visibility-help" className="text-sm">
          {isPublic ? "Listed in Open Tables" : "Only people with your code can join"}
        </p>
      </fieldset>

      <fieldset className="flex flex-col gap-1.5" aria-describedby="scoring-help">
        <legend className="mb-1.5 text-sm font-semibold uppercase tracking-[0.18em] text-[var(--brass-light)]">
          Scoring
        </legend>
        <div className="grid grid-cols-2 gap-2">
          <OptionCard
            name="scoring"
            label="Regular play"
            checked={!isMuggins}
            onChange={() => onMugginsChange(false)}
          />
          <OptionCard
            name="scoring"
            label="Self-Scoring (Muggins)"
            checked={isMuggins}
            onChange={() => onMugginsChange(true)}
          />
        </div>
        <p id="scoring-help" className="text-sm">
          {isMuggins ? "No scoring: you keep your own score" : "The app keeps the score"}
        </p>
      </fieldset>

      <fieldset className="flex flex-col gap-1.5" aria-describedby="players-help">
        <legend className="mb-1.5 text-sm font-semibold uppercase tracking-[0.18em] text-[var(--brass-light)]">
          Players
        </legend>
        <div className="grid grid-cols-3 gap-2">
          {options.playerCounts.map((n) => (
            <OptionCard
              key={n}
              name="players"
              label={String(n)}
              checked={maxPlayers === n}
              onChange={() => onMaxPlayersChange(n)}
            />
          ))}
        </div>
        {/* Team or Solo: not with Self-Scoring at all. */}
        {options.fourPlayerModeShown && (
          <fieldset className="flex flex-col gap-2 pl-3" disabled={!modeOffered}>
            <legend className="mb-1 text-sm">With 4 players: Team or Solo</legend>
            <div className="grid grid-cols-2 gap-2">
              <OptionCard
                name="four-player-mode"
                label="Team"
                checked={modeOffered && fourPlayerMode === "teams"}
                onChange={() => onFourPlayerModeChange("teams")}
                disabled={!modeOffered}
                note={null}
              />
              <OptionCard
                name="four-player-mode"
                label="Solo"
                checked={modeOffered && fourPlayerMode === "solo"}
                onChange={() => onFourPlayerModeChange("solo")}
                disabled={!modeOffered}
                note={null}
              />
            </div>
          </fieldset>
        )}
        <p id="players-help" className="text-sm">
          {maxPlayers === 4 && !isMuggins
            ? fourPlayerMode === "solo"
              ? "Everyone plays for themselves"
              : "Two teams: partners sit opposite and share one score"
            : maxPlayers === 3 || maxPlayers === 4
              ? "Everyone plays for themselves"
              : "Head to head"}
        </p>
      </fieldset>
    </div>
  );
}

// One choice: a real radio inside its label (see .option-card in
// app/globals.css). A disabled one says why -- "Coming soon" unless a note
// says otherwise -- as part of its label, so a screen
// reader hears it too. note={null} shows nothing.
function OptionCard({
  name,
  label,
  checked,
  onChange,
  disabled = false,
  note,
}: {
  name: string;
  label: string;
  checked: boolean;
  onChange?: () => void;
  disabled?: boolean;
  note?: string | null;
}) {
  const reason = disabled ? (note === undefined ? "Coming soon" : note) : null;
  return (
    <label className="option-card">
      <input
        type="radio"
        name={name}
        value={label}
        checked={checked}
        onChange={onChange}
        readOnly={!onChange}
        disabled={disabled}
        className="sr-only"
      />
      <span className="option-dot" aria-hidden="true" />
      <span className="flex flex-col leading-tight">
        <span className="font-semibold">{label}</span>
        {reason && <span className="coming-soon">{reason}</span>}
      </span>
    </label>
  );
}
