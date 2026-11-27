"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { HandCalculator } from "@/components/HandCalculator";

// THE HAND CALCULATOR ("Hand Calculator" on the main menu): pick four cards
// and a starter and see what they score, line by line. Not part of a game:
// nothing is read from or written to the database. Signed-in players only,
// with the same guard as Settings. The page is the wide frame (768px), so the
// big-screen layout has room for rows of 13 cards.
//
// FROM THE TRAVEL BOARD (?from=travel-board, its cards key): a "Use this
// score" button under the count takes the total back as
// /travel-board?calc=N (added to its entry; OK still has to be tapped), and
// "Back to Travel Board" replaces "Back home". Both replace this page in the
// history, so Back from the board doesn't land here again. Without the
// marker -- opened from Home -- the page is exactly as before.
export default function CalculatorPage() {
  const router = useRouter();
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [fromBoard, setFromBoard] = useState(false);

  useEffect(() => {
    // Read here, not with useSearchParams: no Suspense boundary needed.
    const fromTravelBoard = new URLSearchParams(window.location.search).get("from") === "travel-board";
    supabase.auth.getSession().then(({ data }) => {
      setFromBoard(fromTravelBoard);
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
        <p>You need to be logged in to use the hand calculator.</p>
        <Link href="/login" className="peg-btn peg-btn--brass">
          Log in
        </Link>
      </CardRoomFrame>
    );
  }

  return (
    <CardRoomFrame
      title="Hand Calculator"
      wide
      compact
      edgeToEdge
      backHome={!fromBoard}
      after={
        fromBoard ? (
          <Link href="/travel-board" replace className="peg-btn peg-btn--ghost w-full">
            Back to Travel Board
          </Link>
        ) : undefined
      }
    >
      <HandCalculator
        onUseScore={fromBoard ? (total) => router.replace(`/travel-board?calc=${total}`) : undefined}
      />
    </CardRoomFrame>
  );
}
