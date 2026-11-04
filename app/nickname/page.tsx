"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { supabase } from "@/lib/supabase";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { NicknameStep } from "@/components/brand/NicknameStep";
import { safeReturnPath } from "@/lib/nickname";
import { fetchNeedsNickname } from "@/lib/profileNickname";

// THE NICKNAME STEP for the direct routes: Start a Table, single player, and
// a new seat at a table send a player without a nickname here, with
// ?next=<where they were going>. Once it's saved -- or if they turn out to
// have one already -- they go on to next, which must be a same-site path
// (safeReturnPath; anything else is the home page).
export default function NicknamePage() {
  const router = useRouter();
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [next, setNext] = useState("/");

  useEffect(() => {
    let cancelled = false;
    // Read here, not with useSearchParams: no Suspense boundary needed.
    const target = safeReturnPath(new URLSearchParams(window.location.search).get("next"));
    supabase.auth.getSession().then(async ({ data }) => {
      if (cancelled) return;
      setNext(target);
      setSession(data.session);
      if (!data.session) {
        setLoading(false);
        return;
      }
      // Already has one (or it can't be read): straight on.
      const needs = await fetchNeedsNickname(data.session.user.id);
      if (cancelled) return;
      if (needs !== true) {
        router.replace(target);
        return;
      }
      setLoading(false);
    });
    return () => {
      cancelled = true;
    };
  }, [router]);

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
        <p>You need to be logged in to pick a nickname.</p>
        <Link href="/login" className="peg-btn peg-btn--brass">
          Log in
        </Link>
      </CardRoomFrame>
    );
  }

  return (
    <NicknameStep
      userId={session.user.id}
      onSaved={() => router.replace(next)}
      onLogout={() => {
        supabase.auth.signOut().then(() => router.replace("/"));
      }}
    />
  );
}
