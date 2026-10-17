"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";

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
        .insert({ code, created_by: session.user.id, is_public: isPublic })
        .select("code")
        .single();

      if (!error) {
        // Straight to the table, where the creator joins and waits for the
        // second player (the table page shows the code to send). replace, not
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
    <CardRoomFrame title="Start a Table">
      <TableOptions isPublic={isPublic} onVisibilityChange={setIsPublic} />

      {/* Stays disabled once created, while the table page loads -- a second
          tap would open a second table. */}
      <button
        onClick={handleCreateTable}
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
    </CardRoomFrame>
  );
}

// THE TABLE OPTIONS: three groups, always all visible. Only Visibility is
// live; Muggins mode and Players are shown so players know they're coming,
// as real disabled controls (skipped by Tab and arrow keys, announced as
// unavailable). Nothing is sent for them -- those columns don't exist yet.
function TableOptions({
  isPublic,
  onVisibilityChange,
}: {
  isPublic: boolean;
  onVisibilityChange: (isPublic: boolean) => void;
}) {
  return (
    <div className="flex flex-col gap-5">
      <fieldset className="flex flex-col gap-2" aria-describedby="visibility-help">
        <legend className="mb-2 text-sm font-semibold uppercase tracking-[0.18em] text-[var(--brass-light)]">
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

      <fieldset className="flex flex-col gap-2">
        <legend className="mb-2 text-sm font-semibold uppercase tracking-[0.18em] text-[var(--brass-light)]">
          Muggins mode
        </legend>
        <div className="flex items-center gap-3">
          <button
            type="button"
            role="switch"
            aria-checked="false"
            aria-label="Muggins mode"
            aria-describedby="muggins-state muggins-soon"
            disabled
            className="felt-switch"
          />
          <span id="muggins-state">Off</span>
          <span id="muggins-soon" className="coming-soon">
            Coming soon
          </span>
        </div>
      </fieldset>

      <fieldset className="flex flex-col gap-2">
        <legend className="mb-2 text-sm font-semibold uppercase tracking-[0.18em] text-[var(--brass-light)]">
          Players
        </legend>
        <div className="grid grid-cols-3 gap-2">
          <OptionCard name="players" label="2" checked onChange={() => {}} />
          <OptionCard name="players" label="3" checked={false} disabled />
          <OptionCard name="players" label="4" checked={false} disabled />
        </div>
        <fieldset className="flex flex-col gap-2 pl-3" disabled>
          <legend className="mb-1 text-sm">
            With 4 players: Team or Solo <span className="coming-soon">Coming soon</span>
          </legend>
          <div className="grid grid-cols-2 gap-2">
            <OptionCard name="four-player-mode" label="Team" checked={false} disabled />
            <OptionCard name="four-player-mode" label="Solo" checked={false} disabled />
          </div>
        </fieldset>
      </fieldset>
    </div>
  );
}

// One choice: a real radio inside its label (see .option-card in
// app/globals.css). A disabled one says "Coming soon" -- part of its label,
// so a screen reader hears it too.
function OptionCard({
  name,
  label,
  checked,
  onChange,
  disabled = false,
}: {
  name: string;
  label: string;
  checked: boolean;
  onChange?: () => void;
  disabled?: boolean;
}) {
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
        {disabled && <span className="coming-soon">Coming soon</span>}
      </span>
    </label>
  );
}
