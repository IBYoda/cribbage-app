"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { OpponentChooser } from "@/components/brand/OpponentChooser";
import { DEFAULT_COMPUTER_LEVEL, LEVEL_INFO, isComputerLevel, type ComputerLevel } from "@/lib/computer/config";
import { nicknameStepHref } from "@/lib/nickname";
import { fetchNeedsNickname } from "@/lib/profileNickname";
import { RefusalNotice } from "@/components/brand/RefusalNotice";
import { GENERIC_ERROR_TEXT, QUIET_CLOSE_NOTE, logUnexpectedError, rpcRefusal, type Refusal } from "@/lib/oneTable";

const UNIQUE_VIOLATION = "23505";
const MAX_CODE_ATTEMPTS = 5;

function generateCode() {
  return Math.floor(Math.random() * 10000)
    .toString()
    .padStart(4, "0");
}

// THE SINGLE-PLAYER SCREEN ("Play Single Player Game" on the main menu):
// choose a computer opponent and play it. A computer table is always
// private, 2-player and regular scoring, so there are no other options.
//
// The avatars: each computer's profiles.avatar_url, from
// get_computer_profiles() -- found by account id through computer_accounts
// (which the app can't read directly), one row per level. If the call fails
// or a level is missing, that computer shows its initial.
export default function SinglePlayerPage() {
  const router = useRouter();
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  // Starts on Normie (DEFAULT_COMPUTER_LEVEL), the standard player's match.
  const [level, setLevel] = useState<ComputerLevel>(DEFAULT_COMPUTER_LEVEL);
  const [avatars, setAvatars] = useState<Partial<Record<ComputerLevel, string | null>>>({});
  const [status, setStatus] = useState<"idle" | "creating" | "success" | "error">("idle");
  // Why the game didn't start: its plain message, and for "already at table
  // NNNN" a button to that table (lib/oneTable.ts).
  const [refusal, setRefusal] = useState<Refusal | null>(null);

  // The nickname gate: a player without a nickname picks one first and
  // comes back here (the page stays "Loading..." meanwhile).
  useEffect(() => {
    let cancelled = false;
    supabase.auth.getSession().then(async ({ data }) => {
      if (cancelled) return;
      if (data.session && (await fetchNeedsNickname(data.session.user.id)) === true) {
        if (!cancelled) router.replace(nicknameStepHref("/single-player"));
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

  useEffect(() => {
    if (!session) return;
    let cancelled = false;
    supabase.rpc("get_computer_profiles").then(
      ({ data, error }) => {
        if (cancelled || error || !Array.isArray(data)) return;
        const found: Partial<Record<ComputerLevel, string | null>> = {};
        for (const row of data as { level: string; avatar_url: string | null }[]) {
          if (isComputerLevel(row.level)) found[row.level] = row.avatar_url ?? null;
        }
        setAvatars(found);
      },
      () => {} // a network failure: the initials stay
    );
    return () => {
      cancelled = true;
    };
  }, [session]);

  // create_computer_table makes the table (private, 2-player, regular
  // scoring) and seats this player and the computer. A code collision raises
  // 23505, as a direct insert does: try again with a fresh code.
  async function handlePlay() {
    if (!session) return;

    setStatus("creating");
    setRefusal(null);

    for (let attempt = 0; attempt < MAX_CODE_ATTEMPTS; attempt++) {
      const code = generateCode();

      const { data, error } = await supabase.rpc("create_computer_table", {
        p_level: level,
        p_code: code,
      });

      if (!error) {
        const row = (data as { table_id: string; code: string }[] | null)?.[0];
        setStatus("success");
        // replace: Back from the table shouldn't land here, one tap away
        // from a second table.
        router.replace(`/tables/${row?.code ?? code}`);
        return;
      }

      if (error.code === UNIQUE_VIOLATION) {
        continue;
      }

      setStatus("error");
      if (error.message.includes("not set up yet")) {
        setRefusal({
          kind: "unknown",
          text: `${LEVEL_INFO[level].name} isn't ready to play yet. Try another level, or try again later.`,
        });
        return;
      }
      // One table at a time (docs/sql/join-create.sql): seated at a table
      // with other humans -> already_at_table, with a button to it; 10 games
      // in the last hour -> rate_limited. Anything else: never raw text.
      const why = rpcRefusal(error);
      if (why.kind === "unknown") logUnexpectedError("create_computer_table", error);
      setRefusal(why.kind === "unknown" ? { kind: "unknown", text: GENERIC_ERROR_TEXT } : why);
      return;
    }

    setStatus("error");
    setRefusal({ kind: "unknown", text: "Couldn't generate a unique table code, please try again." });
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
        <p>You need to be logged in to play.</p>
        <Link href="/login" className="peg-btn peg-btn--brass">
          Log in
        </Link>
      </CardRoomFrame>
    );
  }

  return (
    <CardRoomFrame title="Choose Your Opponent" compact>
      <OpponentChooser level={level} onLevelChange={setLevel} avatars={avatars} />

      {/* Stays disabled once created, while the table page loads. */}
      <button
        onClick={handlePlay}
        disabled={status === "creating" || status === "success"}
        className="peg-btn peg-btn--brass disabled:opacity-60"
      >
        {status === "creating"
          ? "Creating..."
          : status === "success"
            ? "Opening table..."
            : `Play ${LEVEL_INFO[level].name}`}
      </button>

      <p className="text-sm">{QUIET_CLOSE_NOTE}</p>

      {status === "error" && refusal && <RefusalNotice refusal={refusal} />}
    </CardRoomFrame>
  );
}
