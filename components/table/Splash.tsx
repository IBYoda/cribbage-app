"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { ZERO_SPLASH_PHRASES } from "@/lib/splashPhrases";

// THE TABLE SPLASHES: a big centred overlay for two live moments.
//   * "19" -- a counted hand or crib scored 0: a random phrase from
//     lib/splashPhrases.ts, and "<name> scored 0" under it (~2s).
//   * GO -- a player said Go (or was auto-gone): a giant "GO" (~1.2s). The
//     small amber Go label by the seat stays as it is.
//
// LIVE ONLY. The table page calls showZero / showGo from its realtime
// handlers, never from a read: postgres_changes streams only what happens
// while subscribed, so a refresh, a reconnect's catch-up read or the safety
// poll can never fire one. Each call carries a key for its event; a key seen
// before is ignored, so a re-delivered or repeated event never fires twice.
//
// ONE AT A TIME. A new splash replaces the one showing (new id, new key on
// the element, so its animation restarts). Nothing times it out: the CSS
// animation ends at opacity 0 and onAnimationEnd clears it -- the same
// remount-to-replay idea as the score flash. Never clickable
// (pointer-events-none, no backdrop), above the table (z-40) and below any
// modal (the dialogs are native <dialog>s, drawn in the top layer). No sound.

export type SplashEvent =
  | { id: number; kind: "zero"; phrase: string; sub: string }
  | { id: number; kind: "go" };

// noZero: the count numbers are hidden on this screen (Hide counts, or a
// Muggins table) -- the "19" splash says 0, so it never fires.
export function useSplash({ noZero }: { noZero: boolean }) {
  const [splash, setSplash] = useState<SplashEvent | null>(null);
  const handledRef = useRef(new Set<string>());
  const nextIdRef = useRef(0);
  const noZeroRef = useRef(noZero);
  useEffect(() => {
    noZeroRef.current = noZero;
  }, [noZero]);

  // True if this key is new (and marks it handled).
  const claim = useCallback((key: string) => {
    if (handledRef.current.has(key)) return false;
    handledRef.current.add(key);
    return true;
  }, []);

  const showZero = useCallback(
    (key: string, name: string, isCrib: boolean) => {
      if (!claim(key) || noZeroRef.current) return;
      const phrase = ZERO_SPLASH_PHRASES[Math.floor(Math.random() * ZERO_SPLASH_PHRASES.length)] ?? "";
      const sub = isCrib ? `${name}'s crib scored 0` : `${name} scored 0`;
      setSplash({ id: ++nextIdRef.current, kind: "zero", phrase, sub });
    },
    [claim]
  );

  const showGo = useCallback(
    (key: string) => {
      if (!claim(key)) return;
      setSplash({ id: ++nextIdRef.current, kind: "go" });
    },
    [claim]
  );

  // Clears the splash once its animation is over -- unless a newer one has
  // already replaced it.
  const dismiss = useCallback((id: number) => {
    setSplash((current) => (current && current.id === id ? null : current));
  }, []);

  return { splash, showZero, showGo, dismiss };
}

export function Splash({ splash, onDone }: { splash: SplashEvent | null; onDone: (id: number) => void }) {
  if (!splash) return null;
  return (
    <div
      aria-live="polite"
      className="pointer-events-none fixed inset-0 z-40 flex items-center justify-center px-4"
    >
      {splash.kind === "go" ? (
        <span
          key={splash.id}
          onAnimationEnd={() => onDone(splash.id)}
          className="splash-go select-none text-[clamp(7rem,38vw,18rem)] font-black leading-none tracking-tight text-amber-400"
        >
          GO
        </span>
      ) : (
        <div
          key={splash.id}
          onAnimationEnd={() => onDone(splash.id)}
          className="splash-zero flex max-w-full select-none flex-col items-center text-center"
        >
          <span className="text-[clamp(2.5rem,11vw,6.5rem)] font-black uppercase leading-[0.95] text-white">
            {splash.phrase}
          </span>
          <span className="mt-3 text-base font-semibold text-white sm:text-lg">{splash.sub}</span>
        </div>
      )}
    </div>
  );
}
