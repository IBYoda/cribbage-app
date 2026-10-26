"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { OpponentChooser } from "@/components/brand/OpponentChooser";
import { LEVEL_INFO, type ComputerLevel } from "@/lib/computer/config";

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
// The avatars: each computer's profiles.avatar_url, found by its nickname
// (the computer accounts themselves can't be read by the app). Used only
// when exactly one profile has that nickname; otherwise -- or if the read
// fails -- the initial shows.
export default function SinglePlayerPage() {
  const router = useRouter();
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [level, setLevel] = useState<ComputerLevel>("medium");
  const [avatars, setAvatars] = useState<Partial<Record<ComputerLevel, string | null>>>({});
  const [status, setStatus] = useState<"idle" | "creating" | "success" | "error">("idle");
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });
  }, []);

  useEffect(() => {
    if (!session) return;
    let cancelled = false;
    const levels = Object.keys(LEVEL_INFO) as ComputerLevel[];
    supabase
      .from("profiles")
      .select("nickname, avatar_url")
      .in("nickname", levels.map((l) => LEVEL_INFO[l].name))
      .then(({ data }) => {
        if (cancelled || !data) return;
        const found: Partial<Record<ComputerLevel, string | null>> = {};
        for (const l of levels) {
          const rows = data.filter((p) => p.nickname === LEVEL_INFO[l].name);
          if (rows.length === 1) found[l] = rows[0].avatar_url ?? null;
        }
        setAvatars(found);
      });
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
    setMessage(null);

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
      setMessage(
        error.message.includes("not set up yet")
          ? `${LEVEL_INFO[level].name} isn't ready to play yet. Try another level, or try again later.`
          : error.message
      );
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

      {status === "error" && message && <p className="text-sm text-[var(--error-on-felt)]">{message}</p>}
    </CardRoomFrame>
  );
}
