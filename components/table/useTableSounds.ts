"use client";

import { useEffect, useMemo, useRef } from "react";
import { canPlayNow, playCue, prepareSounds, stopClip, useSoundOn } from "@/components/SoundProvider";
import type { CustomBoard } from "@/lib/customBoards";
import {
  CORE_SOUNDS,
  DISCARD_GAP_MS,
  SHUFFLE_LEAD_MS,
  clipsFor,
  pickClip,
  readLastClip,
  readSoundOn,
  soundFor,
  writeLastClip,
  zeroSoundAllowed,
  type SoundEvent,
} from "@/lib/sounds";

// THE TABLE'S SOUNDS: what the table page's realtime handlers, its one cut tap
// and the deal animation's start call. Each call carries a key, as a splash
// does (components/table/Splash.tsx): a key seen before is ignored, so a
// repeated row or a re-delivered event never plays twice. A key is claimed even
// with the sound off, so turning it on can't play something old.
//
// `options` is read through a ref: the page's realtime handlers are long-lived
// closures. Everything returned is stable, so the page's subscription never
// restarts for it.

type TableSoundOptions = {
  // A table is open here: its clips load (and only with the sound on).
  open: boolean;
  isMuggins: boolean;
  // This player's Hide counts setting.
  hideCounts: boolean;
  // The square table, the only one that shows a board.
  square: boolean;
  board: CustomBoard | null;
};

export function useTableSounds(options: TableSoundOptions) {
  const { open, board } = options;
  const soundOn = useSoundOn();
  const optionsRef = useRef(options);
  useEffect(() => {
    optionsRef.current = options;
  });
  // soundOn is on for the first render whatever is saved (the server can't read
  // it), so the saved setting has the last word: sound off loads nothing, and
  // turning it on mid-game runs this again.
  useEffect(() => {
    if (open && soundOn && readSoundOn()) prepareSounds(clipsFor(board));
  }, [open, soundOn, board]);

  // Stays with the component: a page load is one set of keys.
  const handledRef = useRef(new Set<string>());
  // The deal's lead-in by key, so a second run of the animation's start (dev's
  // double effects, a remount) gets the same answer and plays nothing.
  const dealLeadRef = useRef(new Map<string, number>());

  return useMemo(() => {
    // True if this key is new (and marks it handled).
    const claim = (key: string) => {
      if (handledRef.current.has(key)) return false;
      handledRef.current.add(key);
      return true;
    };
    const urlFor = (event: SoundEvent) => {
      const { board, isMuggins, square } = optionsRef.current;
      const url = pickClip(soundFor(event, board, { isMuggins, square }), readLastClip(event));
      writeLastClip(event, url);
      return url;
    };
    const card = (count: number) => {
      const url = urlFor("card");
      playCue({ steps: Array.from({ length: count }, () => ({ event: "card" as const, url })), gapMs: DISCARD_GAP_MS });
    };

    return {
      // Already happened without this screen hearing it: never played.
      heard(keys: string[]) {
        for (const key of keys) handledRef.current.add(key);
      },
      // count: a discard's cards, one sound each.
      card(key: string, count = 1) {
        if (claim(key)) card(count);
      },
      shuffle(key: string) {
        if (claim(key)) playCue({ steps: [{ event: "shuffle", url: urlFor("shuffle") }], gapMs: null });
      },
      // The shuffle, then the deal. Returns how long the deal animation should
      // hold its first card so the two start together: 0 when nothing will be
      // heard, so with the sound off the animation runs exactly as before.
      dealStart(key: string): number {
        if (!claim(key)) return dealLeadRef.current.get(key) ?? 0;
        const steps = [
          { event: "shuffle" as const, url: urlFor("shuffle") },
          { event: "deal" as const, url: urlFor("deal") },
        ];
        const lead = canPlayNow(steps.map((s) => s.url)) ? SHUFFLE_LEAD_MS : 0;
        dealLeadRef.current.set(key, lead);
        if (lead) playCue({ steps, gapMs: null });
        return lead;
      },
      // The deal is over or skipped. A board's own deal clip is stopped too.
      dealEnd() {
        const { board, isMuggins, square } = optionsRef.current;
        for (const url of new Set([...CORE_SOUNDS.deal, ...soundFor("deal", board, { isMuggins, square })])) stopClip(url);
      },
      // A hand or crib that counted 0. Claimed even when it's hidden here.
      zeroHand(key: string) {
        if (!claim(key) || !zeroSoundAllowed(optionsRef.current)) return;
        playCue({ steps: [{ event: "zeroHand", url: urlFor("zeroHand") }], gapMs: null });
      },
      end(key: string, event: SoundEvent) {
        if (claim(key)) playCue({ steps: [{ event, url: urlFor(event) }], gapMs: null });
      },
    };
  }, []);
}
