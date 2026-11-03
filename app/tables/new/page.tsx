"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { MugginsNotice } from "@/components/brand/MugginsNotice";
import { TableOptions } from "@/components/brand/TableOptions";
import { newTableFields, type FourPlayerMode } from "@/lib/newTable";

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
  // The Muggins confirmation (MugginsNotice). Only its "Start Self-Scoring (Muggins) table"
  // creates the table; a Regular table never sees it.
  const [mugginsNoticeOpen, setMugginsNoticeOpen] = useState(false);
  // How many players: 2, 3 or 4, with Regular play or Self-Scoring alike.
  // Always sent.
  const [maxPlayers, setMaxPlayers] = useState<2 | 3 | 4>(2);
  // With 4 players: Teams (the default) or Solo. Sent only for 4 players,
  // and never with Self-Scoring, which has no Team/Solo (newTableFields).
  const [fourPlayerMode, setFourPlayerMode] = useState<FourPlayerMode>("teams");

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
          ...newTableFields({ isPublic, isMuggins, maxPlayers, fourPlayerMode }),
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
        fourPlayerMode={fourPlayerMode}
        onFourPlayerModeChange={setFourPlayerMode}
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
        playerCount={maxPlayers}
        onCancel={() => setMugginsNoticeOpen(false)}
        onConfirm={() => {
          setMugginsNoticeOpen(false);
          handleCreateTable();
        }}
      />
    </CardRoomFrame>
  );
}
