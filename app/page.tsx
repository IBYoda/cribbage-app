"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "@/lib/supabase";
import { LandingView } from "@/components/brand/LandingView";
import { HomeView } from "@/components/brand/HomeView";
import { readAuthHashError } from "@/lib/authFlow";

export default function Home() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  // An expired or already used confirmation link landed here
  // (#error=...&error_code=otp_expired): a notice for a signed-out visitor.
  const [linkExpired, setLinkExpired] = useState(false);

  useEffect(() => {
    // Read the link straight away, as the reset page does: the client clears
    // what it uses. A good link's tokens aren't an error, and sign the player
    // in exactly as before.
    const hashError = readAuthHashError(window.location.hash);
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
      if (hashError) {
        if (!data.session) setLinkExpired(true);
        // Off the address bar, so a refresh doesn't show it again.
        window.history.replaceState(null, "", window.location.pathname + window.location.search);
      }
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
    return (
      <LandingView
        signedOut={!loading && !session}
        linkExpired={linkExpired}
        onDismissLinkExpired={() => setLinkExpired(false)}
      />
    );
  }

  // THE MAIN MENU (signed in).
  return <HomeView session={session} onLogout={handleLogout} />;
}
