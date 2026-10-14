"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import { LandingView } from "@/components/brand/LandingView";

export default function Home() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });

    const { data: listener } = supabase.auth.onAuthStateChange((_event, newSession) => {
      setSession(newSession);
    });

    return () => listener.subscription.unsubscribe();
  }, []);

  async function handleLogout() {
    await supabase.auth.signOut();
  }

  // THE LANDING PAGE: signed out -- and also while the session is still being
  // read, so the first paint is the card room (with the buttons held back
  // until we know nobody is signed in; see LandingView).
  if (loading || !session) {
    return <LandingView signedOut={!loading && !session} />;
  }

  // THE HOME VIEW (signed in) -- unchanged for now; the main-menu redesign is
  // stage 2.
  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-6 p-8">
      <h1 className="text-2xl font-semibold">Cribbage App</h1>

      {session && (
        <>
          <p>
            Logged in as <span className="font-medium">{session.user.email}</span>
          </p>
          <div className="flex gap-4">
            <Link
              href="/profile"
              className="rounded border border-zinc-300 px-4 py-2 dark:border-zinc-700"
            >
              Edit Profile
            </Link>
            <Link
              href="/tables/new"
              className="rounded border border-zinc-300 px-4 py-2 dark:border-zinc-700"
            >
              Start a Table
            </Link>
            <Link
              href="/tables/join"
              className="rounded border border-zinc-300 px-4 py-2 dark:border-zinc-700"
            >
              Join a Table
            </Link>
            <Link
              href="/admin"
              className="rounded border border-zinc-300 px-4 py-2 dark:border-zinc-700"
            >
              Admin
            </Link>
            <button
              onClick={handleLogout}
              className="rounded bg-foreground px-4 py-2 text-background"
            >
              Log Out
            </button>
          </div>
        </>
      )}
    </main>
  );
}
