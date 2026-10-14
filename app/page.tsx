"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import { LandingView } from "@/components/brand/LandingView";
import { HomeView } from "@/components/brand/HomeView";

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

  // THE MAIN MENU (signed in).
  return <HomeView session={session} onLogout={handleLogout} />;
}
