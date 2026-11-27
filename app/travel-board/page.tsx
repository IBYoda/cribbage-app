"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { supabase } from "@/lib/supabase";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { TravelBoard } from "@/components/TravelBoard";

// THE TRAVEL BOARD ("Travel Board" on the main menu): a cribbage board for a
// face-to-face game with a real deck. Scorekeeping only, kept in this browser
// (lib/travelBoard.ts): nothing is read from or written to the database.
// Signed-in players only, with the Hand Calculator's guard (the saved sign-in
// only; no table reads). The user id names the saved game's key.
export default function TravelBoardPage() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });
  }, []);

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
        <p>You need to be logged in to use the travel board.</p>
        <Link href="/login" className="peg-btn peg-btn--brass">
          Log in
        </Link>
      </CardRoomFrame>
    );
  }

  return <TravelBoard userId={session.user.id} />;
}
