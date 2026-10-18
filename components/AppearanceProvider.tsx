"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from "react";
import { preload } from "react-dom";
import { supabase } from "@/lib/supabase";
import {
  CLASSIC_APPEARANCE,
  HTML_SURFACE_ATTRIBUTE,
  cardBackUrl,
  clearCachedAppearance,
  normalizeAppearance,
  readCachedAppearance,
  writeCachedAppearance,
  type Appearance,
} from "@/lib/appearance";

// THE SIGNED-IN PLAYER'S APPEARANCE -- their table surface, card back and
// Hide counts setting (lib/appearance.ts), for THEIR OWN screen only.
//
// Read from public.user_appearance (owner-only, not in Realtime) once per
// signed-in user: on load, and again only when the signed-in user changes.
// Nothing subscribes to that table, and nothing about it touches the games.
//
//   * ready: we know the answer for the current user -- from this device's
//     cached copy, or from the database. The table page waits for it, so the
//     table is never drawn in the wrong look first.
//   * The cached copy is keyed by user id (lib/appearance.ts), cleared on
//     sign-out and when someone else signs in.
//   * The database wins: a fetched value replaces a cached one.
//   * No row means Classic. A failed read is quiet: the cached copy if there
//     is one, else Classic -- and a failed read never overwrites the cache.
type AppearanceState = Appearance & { userId: string | null; ready: boolean };

type AppearanceContextValue = AppearanceState & {
  // Saves every choice for the signed-in user (one upsert of the whole row,
  // so no field is ever lost). Resolves to null on success -- the new look
  // applies at once -- or to an error message, in which case nothing
  // changes.
  save: (next: Appearance) => Promise<string | null>;
};

// Without a provider (the layout mock), Classic and ready.
const AppearanceContext = createContext<AppearanceContextValue>({
  ...CLASSIC_APPEARANCE,
  userId: null,
  ready: true,
  save: async () => "Appearance settings are not available here.",
});

export function useAppearance() {
  return useContext(AppearanceContext);
}

export function AppearanceProvider({ children }: { children: React.ReactNode }) {
  const [state, setState] = useState<AppearanceState>({
    ...CLASSIC_APPEARANCE,
    userId: null,
    ready: false,
  });

  // The user whose appearance is loaded (or loading). Auth events repeat --
  // INITIAL_SESSION, TOKEN_REFRESHED -- and only a CHANGE of user reloads.
  const loadedUserRef = useRef<string | null | undefined>(undefined);
  // Ticket per load, so a slow read for a user who has since signed out (or
  // been replaced) can't land on top of the newer one.
  const loadSeqRef = useRef(0);

  useEffect(() => {
    async function load(userId: string | null) {
      if (userId === loadedUserRef.current) return;
      loadedUserRef.current = userId;
      const ticket = ++loadSeqRef.current;

      // Signed out: Classic, and no trace of the last player on this device.
      if (!userId) {
        clearCachedAppearance();
        setState({ ...CLASSIC_APPEARANCE, userId: null, ready: true });
        return;
      }

      // This user's cached copy, if this device has one: ready at once.
      // Otherwise not ready -- the table waits -- until the read below.
      const cached = readCachedAppearance(userId);
      setState(
        cached
          ? { ...cached, userId, ready: true }
          : { ...CLASSIC_APPEARANCE, userId, ready: false }
      );

      const { data, error } = await supabase
        .from("user_appearance")
        .select("card_back, table_surface, hide_counts")
        .eq("user_id", userId)
        .maybeSingle();
      if (ticket !== loadSeqRef.current) return; // superseded

      if (error) {
        setState({ ...(cached ?? CLASSIC_APPEARANCE), userId, ready: true });
        return;
      }
      const fetched = normalizeAppearance(
        data ? { surface: data.table_surface, back: data.card_back, hideCounts: data.hide_counts } : null
      );
      writeCachedAppearance(userId, fetched);
      setState({ ...fetched, userId, ready: true });
    }

    supabase.auth.getSession().then(({ data }) => load(data.session?.user.id ?? null));
    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      load(session?.user.id ?? null);
    });
    return () => listener.subscription.unsubscribe();
  }, []);

  // Keeps <html>'s cached-surface attribute (the table page's Loading screen,
  // app/globals.css) in step with what's known -- including back to nothing
  // on sign-out.
  useEffect(() => {
    const root = document.documentElement;
    if (state.userId && state.surface !== "classic") {
      root.setAttribute(HTML_SURFACE_ATTRIBUTE, state.surface);
    } else {
      root.removeAttribute(HTML_SURFACE_ATTRIBUTE);
    }
  }, [state.userId, state.surface]);

  // Fetch the chosen back's art early, so the first face-down card doesn't
  // pop in. Classic is CSS only: nothing to load.
  useEffect(() => {
    const url = cardBackUrl(state.back);
    if (url) preload(url, { as: "image" });
  }, [state.back]);

  const save = useCallback(
    async (next: Appearance) => {
      const userId = state.userId;
      if (!userId) return "You need to be logged in to save.";
      const { error } = await supabase.from("user_appearance").upsert(
        {
          user_id: userId,
          table_surface: next.surface,
          card_back: next.back,
          hide_counts: next.hideCounts,
          updated_at: new Date().toISOString(),
        },
        { onConflict: "user_id" }
      );
      if (error) return error.message;
      // Saved: the cached copy and the look change together, at once.
      writeCachedAppearance(userId, next);
      setState((current) =>
        current.userId === userId ? { ...current, ...next, ready: true } : current
      );
      return null;
    },
    [state.userId]
  );

  const value = useMemo(() => ({ ...state, save }), [state, save]);

  return <AppearanceContext.Provider value={value}>{children}</AppearanceContext.Provider>;
}
