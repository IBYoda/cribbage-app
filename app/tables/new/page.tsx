"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { MugginsNotice } from "@/components/brand/MugginsNotice";
import { TableOptions } from "@/components/brand/TableOptions";
import { RefusalNotice } from "@/components/brand/RefusalNotice";
import { createTableArgs, type FourPlayerMode } from "@/lib/newTable";
import { nicknameStepHref } from "@/lib/nickname";
import { fetchNeedsNickname } from "@/lib/profileNickname";
import {
  GENERIC_ERROR_TEXT,
  QUIET_CLOSE_NOTE,
  createdTable,
  logUnexpectedError,
  rpcRefusal,
  tableHref,
  type Refusal,
} from "@/lib/oneTable";

export default function NewTablePage() {
  const router = useRouter();
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [status, setStatus] = useState<"idle" | "creating" | "success" | "error">("idle");
  // Why the table wasn't made (lib/oneTable.ts): its plain message, and for
  // "already at table NNNN" a button to that table.
  const [refusal, setRefusal] = useState<Refusal | null>(null);
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
  // Spectators (PRD item 40): off unless ticked; always sent. Fixed once the
  // table exists.
  const [allowSpectators, setAllowSpectators] = useState(false);

  // The nickname gate: a player without a nickname picks one first and
  // comes back here (the page stays "Loading..." meanwhile).
  useEffect(() => {
    let cancelled = false;
    supabase.auth.getSession().then(async ({ data }) => {
      if (cancelled) return;
      if (data.session && (await fetchNeedsNickname(data.session.user.id)) === true) {
        if (!cancelled) router.replace(nicknameStepHref("/tables/new"));
        return;
      }
      if (cancelled) return;
      setSession(data.session);
      setLoading(false);
    });
    return () => {
      cancelled = true;
    };
  }, [router]);

  // create_table (docs/sql/join-create.sql): the server picks a free code,
  // makes the table and seats the creator (seat 1), all at once. Refused
  // when the player is already seated at another table with other humans
  // (already_at_table, with a button to it) or has started 10 tables in the
  // last hour (rate_limited). An unfinished single-player game of theirs is
  // ended quietly instead (QUIET_CLOSE_NOTE). Never raw server text.
  async function handleCreateTable() {
    if (!session) return;

    setStatus("creating");
    setRefusal(null);

    const { data, error } = await supabase.rpc(
      "create_table",
      createTableArgs({ isPublic, isMuggins, maxPlayers, fourPlayerMode, allowSpectators })
    );
    const made = error ? null : createdTable(data);

    if (made) {
      // Straight to the table, where the creator is already seated and waits
      // for the other players (the table page shows the code to send).
      // replace, not push: Back from the table shouldn't land on this page,
      // one tap away from opening a second table. The link carries the new
      // table's id (step 3 slice B), so the page reads it by id: no confirm.
      setStatus("success");
      router.replace(tableHref(made.code, made.tableId));
      return;
    }

    const why = rpcRefusal(error);
    if (why.kind === "unknown") logUnexpectedError("create_table", error ?? data);
    setStatus("error");
    setRefusal(why.kind === "unknown" ? { kind: "unknown", text: GENERIC_ERROR_TEXT } : why);
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
        allowSpectators={allowSpectators}
        onAllowSpectatorsChange={setAllowSpectators}
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

      <p className="text-sm">{QUIET_CLOSE_NOTE}</p>

      {status === "error" && refusal && <RefusalNotice refusal={refusal} />}

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
