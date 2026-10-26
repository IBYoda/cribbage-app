"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { MugginsNotice } from "@/components/brand/MugginsNotice";

const UNIQUE_VIOLATION = "23505";
const MAX_CODE_ATTEMPTS = 5;

function generateCode() {
  return Math.floor(Math.random() * 10000)
    .toString()
    .padStart(4, "0");
}

export default function NewTablePage() {
  const router = useRouter();
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [status, setStatus] = useState<"idle" | "creating" | "success" | "error">("idle");
  const [message, setMessage] = useState<string | null>(null);
  // Listed in the home page's Open Tables or not. The form defaults to
  // Public and always sends it; the database default is false, so any other
  // insert that forgets it stays private. Private only means UNLISTED:
  // anyone with the code can still join.
  const [isPublic, setIsPublic] = useState(true);
  // Regular play or Muggins play (no scoring -- the players keep their own).
  // Defaults to Regular and is always sent; the database default is false
  // too. Fixed once the table exists.
  const [isMuggins, setIsMuggins] = useState(false);
  // The Muggins confirmation (MugginsNotice). Only its "Start Muggins table"
  // creates the table; a Regular table never sees it.
  const [mugginsNoticeOpen, setMugginsNoticeOpen] = useState(false);
  // How many players: 2, 3 or 4. Muggins is 2-player only (the database
  // refuses anything else too), so each greys out the other. Always sent; 4
  // players play Teams.
  const [maxPlayers, setMaxPlayers] = useState<2 | 3 | 4>(2);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });
  }, []);

  async function handleCreateTable() {
    if (!session) return;

    setStatus("creating");
    setMessage(null);

    for (let attempt = 0; attempt < MAX_CODE_ATTEMPTS; attempt++) {
      const code = generateCode();

      const { data, error } = await supabase
        .from("tables")
        .insert({
          code,
          created_by: session.user.id,
          is_public: isPublic,
          is_muggins: isMuggins,
          max_players: maxPlayers,
          ...(maxPlayers === 4 ? { team_mode: "teams" } : {}),
        })
        .select("code")
        .single();

      if (!error) {
        // Straight to the table, where the creator joins and waits for the
        // other players (the table page shows the code to send). replace, not
        // push: Back from the table shouldn't land on this page, one tap away
        // from opening a second table.
        setStatus("success");
        router.replace(`/tables/${data.code}`);
        return;
      }

      // Code collision -- try again with a fresh random code.
      if (error.code === UNIQUE_VIOLATION) {
        continue;
      }

      setStatus("error");
      setMessage(error.message);
      return;
    }

    setStatus("error");
    setMessage("Couldn't generate a unique table code, please try again.");
  }

  if (loading) {
    return (
      <CardRoomFrame backHome={false}>
        <p className="text-center">Loading...</p>
      </CardRoomFrame>
    );
  }

  if (!session) {
    return (
      <CardRoomFrame backHome={false}>
        <p>You need to be logged in to start a table.</p>
        <Link href="/login" className="peg-btn peg-btn--brass">
          Log in
        </Link>
      </CardRoomFrame>
    );
  }

  return (
    <CardRoomFrame title="Start a Table" compact>
      <TableOptions
        isPublic={isPublic}
        onVisibilityChange={setIsPublic}
        isMuggins={isMuggins}
        onMugginsChange={setIsMuggins}
        maxPlayers={maxPlayers}
        onMaxPlayersChange={setMaxPlayers}
      />

      {/* Stays disabled once created, while the table page loads -- a second
          tap would open a second table. A Muggins table asks first. */}
      <button
        onClick={() => (isMuggins ? setMugginsNoticeOpen(true) : handleCreateTable())}
        disabled={status === "creating" || status === "success"}
        className="peg-btn peg-btn--brass disabled:opacity-60"
      >
        {status === "creating"
          ? "Creating..."
          : status === "success"
            ? "Opening table..."
            : "Start a Table"}
      </button>

      {status === "error" && message && (
        <p className="text-sm text-[var(--error-on-felt)]">{message}</p>
      )}

      {/* THE MUGGINS CONFIRMATION -- the same notice a joiner sees (see
          MugginsNotice). Go back, Escape and the backdrop just close it. */}
      <MugginsNotice
        open={mugginsNoticeOpen}
        mode="create"
        onCancel={() => setMugginsNoticeOpen(false)}
        onConfirm={() => {
          setMugginsNoticeOpen(false);
          handleCreateTable();
        }}
      />
    </CardRoomFrame>
  );
}

// THE TABLE OPTIONS: three groups, always all visible. Visibility, Scoring
// and Players are all live and sent (tables.is_public, is_muggins,
// max_players). 3 and 4 players can be picked -- except with Muggins,
// which is 2-player only, so each greys out the other. 4 players play
// Teams: Team is shown checked and fixed, and Solo is still "Coming soon".
function TableOptions({
  isPublic,
  onVisibilityChange,
  isMuggins,
  onMugginsChange,
  maxPlayers,
  onMaxPlayersChange,
}: {
  isPublic: boolean;
  onVisibilityChange: (isPublic: boolean) => void;
  isMuggins: boolean;
  onMugginsChange: (isMuggins: boolean) => void;
  maxPlayers: 2 | 3 | 4;
  onMaxPlayersChange: (maxPlayers: 2 | 3 | 4) => void;
}) {
  // Muggins is 2-player only.
  const mugginsBlocked = maxPlayers !== 2;
  // 3 or 4: never with Muggins.
  const morePlayersNote = isMuggins ? "Not with Muggins" : null;
  const morePlayersDisabled = isMuggins;
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
            label="Muggins play"
            checked={isMuggins}
            onChange={() => onMugginsChange(true)}
            disabled={mugginsBlocked}
            note={mugginsBlocked ? "2 players only" : null}
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
          <OptionCard name="players" label="2" checked={maxPlayers === 2} onChange={() => onMaxPlayersChange(2)} />
          <OptionCard
            name="players"
            label="3"
            checked={maxPlayers === 3}
            onChange={() => onMaxPlayersChange(3)}
            disabled={morePlayersDisabled}
            note={morePlayersNote}
          />
          <OptionCard
            name="players"
            label="4"
            checked={maxPlayers === 4}
            onChange={() => onMaxPlayersChange(4)}
            disabled={morePlayersDisabled}
            note={morePlayersNote}
          />
        </div>
        <fieldset className="flex flex-col gap-2 pl-3" disabled={maxPlayers !== 4}>
          <legend className="mb-1 text-sm">With 4 players: Team or Solo</legend>
          <div className="grid grid-cols-2 gap-2">
            {/* Fixed: the only 4-player mode for now. */}
            <OptionCard name="four-player-mode" label="Team" checked={maxPlayers === 4} />
            <OptionCard name="four-player-mode" label="Solo" checked={false} disabled />
          </div>
        </fieldset>
        <p id="players-help" className="text-sm">
          {maxPlayers === 4
            ? "Two teams: partners sit opposite and share one score"
            : maxPlayers === 3
              ? "Everyone plays for themselves"
              : "Head to head"}
        </p>
      </fieldset>
    </div>
  );
}

// One choice: a real radio inside its label (see .option-card in
// app/globals.css). A disabled one says why -- "Coming soon" unless a note
// says otherwise ("2 players only") -- as part of its label, so a screen
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
