"use client";

import { useEffect, useState } from "react";

// EXACTLY these five, in this order, looping.
export const TAGLINES = [
  "SHOT!!!",
  "Deal Sucka!",
  "FISH ON BITCHES!",
  "Fuck Gil!",
  "That's a shot bitch!",
] as const;

const EVERY_MS = 4000;
const FADE_MS = 300; // matches .tagline's transition in app/globals.css

// The landing page's rotating tagline.
//   * The first line is in the server-rendered HTML.
//   * aria-live="off": it changes on its own and must not chatter at screen
//     readers.
//   * One fixed line height and no wrapping (.tagline), so a change never
//     moves anything.
//   * Fades out, swaps, fades in; with reduced motion it just swaps.
//   * Pauses while the tab is hidden, and picks up where it left off.
export function RotatingTagline() {
  const [index, setIndex] = useState(0);
  const [visible, setVisible] = useState(true);

  useEffect(() => {
    let interval: number | undefined;
    let fade: number | undefined;
    const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

    function next() {
      if (reduceMotion.matches) {
        setIndex((i) => (i + 1) % TAGLINES.length);
        return;
      }
      setVisible(false);
      fade = window.setTimeout(() => {
        setIndex((i) => (i + 1) % TAGLINES.length);
        setVisible(true);
      }, FADE_MS);
    }

    function start() {
      if (interval === undefined) interval = window.setInterval(next, EVERY_MS);
    }
    function stop() {
      window.clearInterval(interval);
      window.clearTimeout(fade);
      interval = undefined;
      setVisible(true);
    }
    function onVisibility() {
      if (document.hidden) stop();
      else start();
    }

    if (!document.hidden) start();
    document.addEventListener("visibilitychange", onVisibility);
    return () => {
      document.removeEventListener("visibilitychange", onVisibility);
      window.clearInterval(interval);
      window.clearTimeout(fade);
    };
  }, []);

  return (
    <p aria-live="off" className="tagline font-display" data-visible={visible}>
      {TAGLINES[index]}
    </p>
  );
}
