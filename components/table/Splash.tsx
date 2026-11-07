"use client";

import { useCallback, useEffect, useRef, useState, type CSSProperties } from "react";
import {
  GOD_ZERO_SPLASH_IMAGE,
  isGodLevel,
  splashDurationMs,
  zeroSplashKind,
  zeroSplashPhrases,
} from "@/lib/splashPhrases";
import { godLossAlt, type GodLoss } from "@/lib/resultScores";
import { WingsFrame } from "@/components/Wings";
import { WINGS_SPLASH, placementFor, wingsSplashSub, type WingsTier } from "@/lib/wings";

// THE TABLE SPLASHES: a big centred overlay for four live moments.
//   * "19" -- a counted hand or crib scored 0: a random phrase from
//     lib/splashPhrases.ts, and "<name> scored 0" under it (3s). At a table
//     against God the human's 0 uses God's phrases, and God's own 0 shows
//     only an image, with the same pop and fade.
//   * God losing badly -- the human beat God by a skunk, a double skunk or
//     a stinkhole (godLossSplash, lib/resultScores.ts): the same image (3s).
//   * GO -- a player said Go (or was auto-gone): a giant "GO" (1.2s). The
//     small amber Go label by the seat stays as it is.
//   * Wings -- a win against God made the count exactly 10, 25, 50 or 100: the
//     full wings round the player's avatar, their tier and count (3s). If God
//     was skunked by the same win, that image follows when this one is over.
//
// LATER, A SOUND: the wings moment has none yet. It goes where showWings is
// called on the table page: a new SoundEvent in lib/sounds.ts, claimed with the
// same wings:<gameId> key, played after the win clip.
//
// LIVE ONLY. The table page calls showZero / showGo / showGodLoss from its
// realtime handlers, never from a read: postgres_changes streams only what
// happens while subscribed, so a refresh, a reconnect's catch-up read or the
// safety poll can never fire one. Each call carries a key for its event; a
// key seen before is ignored, so a re-delivered or repeated event never
// fires twice.
//
// ONE AT A TIME. A new splash replaces the one showing (new id, new key on
// the element, so its animation restarts). Nothing times it out: the CSS
// animation ends at opacity 0 and onAnimationEnd clears it -- the same
// remount-to-replay idea as the score flash. Never clickable
// (pointer-events-none, no backdrop), above the table (z-40) and below any
// modal (the dialogs are native <dialog>s, drawn in the top layer). A splash
// makes no sound of its own: the table's sounds are lib/sounds.ts, with the
// same live-only rule and the same claim keys.

export type SplashEvent =
  | { id: number; kind: "zero"; phrase: string; sub: string }
  | { id: number; kind: "image"; alt: string }
  | ({ id: number; kind: "wings" } & WingsMoment)
  | { id: number; kind: "go" };

// A player reaching a tier, as the splash shows it.
export type WingsMoment = { tier: WingsTier; count: number; name: string; url: string | null };

// noZero: the count numbers are hidden on this screen (Hide counts, or a
// Muggins table) -- the "19" splash says 0, so it never fires, and neither
// does God's image, which says the same thing.
// computerLevel: tables.computer_level; "hard" is a table against God.
export function useSplash({ noZero, computerLevel }: { noZero: boolean; computerLevel?: string | null }) {
  const godTable = isGodLevel(computerLevel);
  const [splash, setSplash] = useState<SplashEvent | null>(null);
  const handledRef = useRef(new Set<string>());
  const nextIdRef = useRef(0);
  const noZeroRef = useRef(noZero);
  const godTableRef = useRef(godTable);
  const preloadRef = useRef<HTMLImageElement | null>(null);
  useEffect(() => {
    noZeroRef.current = noZero;
  }, [noZero]);
  useEffect(() => {
    godTableRef.current = godTable;
    // Fetched when the table opens: the splash lasts only 3 seconds, too
    // short to wait for it. Once per page, and never at any other table.
    if (godTable && !preloadRef.current) {
      preloadRef.current = new Image();
      preloadRef.current.src = GOD_ZERO_SPLASH_IMAGE;
    }
  }, [godTable]);

  // True if this key is new (and marks it handled).
  const claim = useCallback((key: string) => {
    if (handledRef.current.has(key)) return false;
    handledRef.current.add(key);
    return true;
  }, []);

  // humanScored: whose 0 it was. Only a God table looks at it.
  const showZero = useCallback(
    (key: string, name: string, isCrib: boolean, humanScored = true) => {
      if (!claim(key) || noZeroRef.current) return;
      const godTableNow = godTableRef.current;
      if (zeroSplashKind(godTableNow, humanScored) === "image") {
        setSplash({ id: ++nextIdRef.current, kind: "image", alt: "God scored 0" });
        return;
      }
      const phrases = zeroSplashPhrases(godTableNow);
      const phrase = phrases[Math.floor(Math.random() * phrases.length)] ?? "";
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

  // God losing badly. Not held back by noZero: Hide counts hides the count
  // numbers, and the final scores are on the plates anyway.
  const showGodLoss = useCallback(
    (key: string, loss: GodLoss) => {
      if (!claim(key)) return;
      setSplash({ id: ++nextIdRef.current, kind: "image", alt: godLossAlt(loss) });
    },
    [claim]
  );

  // A milestone, and God's splash after it if the same win earned one: one at a
  // time, so the second waits out the first.
  const followRef = useRef<number | null>(null);
  useEffect(
    () => () => {
      if (followRef.current !== null) window.clearTimeout(followRef.current);
    },
    []
  );
  const showWings = useCallback(
    (key: string, moment: WingsMoment, then?: { key: string; loss: GodLoss }) => {
      if (!claim(key)) return;
      setSplash({ id: ++nextIdRef.current, kind: "wings", ...moment });
      if (then) followRef.current = window.setTimeout(() => showGodLoss(then.key, then.loss), splashDurationMs("wings"));
    },
    [claim, showGodLoss]
  );

  // Clears the splash once its animation is over -- unless a newer one has
  // already replaced it.
  const dismiss = useCallback((id: number) => {
    setSplash((current) => (current && current.id === id ? null : current));
  }, []);

  return { splash, showZero, showGo, showGodLoss, showWings, dismiss };
}

export function Splash({ splash, onDone }: { splash: SplashEvent | null; onDone: (id: number) => void }) {
  if (!splash) return null;
  return (
    <div
      aria-live="polite"
      className="pointer-events-none fixed inset-0 z-40 flex items-center justify-center px-4"
      // The animation's length, read by .splash-zero, .splash-image and
      // .splash-go in app/globals.css.
      style={{ "--splash-duration": `${splashDurationMs(splash.kind)}ms` } as CSSProperties}
    >
      {splash.kind === "go" ? (
        <span
          key={splash.id}
          onAnimationEnd={() => onDone(splash.id)}
          className="splash-go select-none text-[clamp(7rem,38vw,18rem)] font-black leading-none tracking-tight text-amber-400"
        >
          GO
        </span>
      ) : splash.kind === "wings" ? (
        <div
          key={splash.id}
          onAnimationEnd={(event) => {
            // Flames animate in here: only the wrapper's own end counts.
            if (event.target === event.currentTarget) onDone(splash.id);
          }}
          className="splash-wings flex max-w-full select-none flex-col items-center gap-4 text-center"
        >
          <WingsFrame tier={splash.tier} placement={placementFor("milestone")} size={120}>
            {splash.url ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img src={splash.url} alt="" className="splash-wings__avatar" />
            ) : (
              <span className="splash-wings__avatar splash-wings__letter" aria-hidden="true">
                {splash.name.slice(0, 1).toUpperCase()}
              </span>
            )}
          </WingsFrame>
          <span className="text-[clamp(2rem,9vw,4.5rem)] font-black uppercase leading-[0.95] text-white">
            {WINGS_SPLASH[splash.tier]}
          </span>
          <span className="text-base font-semibold text-white sm:text-lg">{wingsSplashSub(splash.count)}</span>
        </div>
      ) : splash.kind === "image" ? (
        // The wrapper animates and clears the splash. The image itself must
        // never animate: its animation events would bubble up here and clear
        // the splash early.
        <div key={splash.id} onAnimationEnd={() => onDone(splash.id)} className="splash-image select-none">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src={GOD_ZERO_SPLASH_IMAGE} alt={splash.alt} width={420} height={420} className="splash-image__img" />
        </div>
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
