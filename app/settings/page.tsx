"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { supabase } from "@/lib/supabase";
import { AppearanceSettings } from "@/components/AppearanceSettings";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";

// SETTINGS ("Settings" on the main menu, beside Profile): the player's look
// and sound -- table surface, card back, Hide counts, animations, sound,
// wings and the board. All of it is the AppearanceSettings component,
// unchanged from when it sat on the Profile page (PRD item 35, slice S2).
// Its providers (AppearanceProvider, SoundProvider) wrap every route in
// app/layout.tsx, so nothing extra is needed here. Signed-in players only,
// with the same guard as Profile.
export default function SettingsPage() {
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
        <p>You need to be logged in to change your settings.</p>
        <Link href="/login" className="peg-btn peg-btn--brass">
          Log in
        </Link>
      </CardRoomFrame>
    );
  }

  return (
    <CardRoomFrame title="Settings">
      <AppearanceSettings />
    </CardRoomFrame>
  );
}
