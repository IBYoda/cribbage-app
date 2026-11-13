"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { supabase } from "@/lib/supabase";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { HandCalculator } from "@/components/HandCalculator";

// THE HAND CALCULATOR ("Hand Calculator" on the main menu): pick four cards
// and a starter and see what they score, line by line. Not part of a game:
// nothing is read from or written to the database. Signed-in players only,
// with the same guard as Settings. The page is the wide frame (768px), so the
// big-screen layout has room for rows of 13 cards.
export default function CalculatorPage() {
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
        <p>You need to be logged in to use the hand calculator.</p>
        <Link href="/login" className="peg-btn peg-btn--brass">
          Log in
        </Link>
      </CardRoomFrame>
    );
  }

  return (
    <CardRoomFrame title="Hand Calculator" wide compact edgeToEdge>
      <HandCalculator />
    </CardRoomFrame>
  );
}
