"use client";

import { useEffect, useId, useState, useSyncExternalStore, type CSSProperties, type ReactNode } from "react";
import { useAmbientMotion } from "@/components/table/useAmbientMotion";
import {
  FLAMES_URL,
  WINGS_BADGE,
  WINGS_HALO,
  badgeSize,
  emberUrl,
  flamesForPointer,
  hasFlames,
  readWingsOn,
  wingsBox,
  wingsOverhang,
  wingsUrl,
  writeWingsOn,
  type WingsPlacement,
  type WingsTier,
} from "@/lib/wings";

// A PLAYER'S WINGS, round whatever avatar is its child: an Avatar, or the
// Profile's own image. Drawn behind it, hidden from screen readers, and never in
// the way of a tap. No tier or mode "none": the child alone, exactly as before.
// The art's place is worked out from the avatar's size (wingsBox, lib/wings.ts),
// so it never moves anything; the only room taken is mini's margin.
//
// size: the avatar's diameter in px. The Beer Board can't use this (no HTML in
// its SVG): MugWings, components/table/BeerBoard.tsx, draws the same art there.
//
// flush: no margin of its own (a Teams pair: ScoreStrip puts it on the pair's
// outside edges). lift: an avatar with no wings beside one with them, raised
// over their art so a partner's wing never hides it. No layout either way.
export function WingsFrame({
  tier,
  placement,
  size,
  flush = false,
  lift = false,
  children,
}: {
  tier: WingsTier | null | undefined;
  placement: WingsPlacement;
  size: number;
  flush?: boolean;
  lift?: boolean;
  children: ReactNode;
}) {
  const { mode, scale } = placement;
  if (!tier || mode === "none") return lift ? <span className="wings-lift">{children}</span> : <>{children}</>;
  const margin = mode === "mini" && !flush ? wingsOverhang(size, scale) : 0;
  return (
    <span
      className={`wings-frame wings-frame--${mode}`}
      style={{ "--wings-d": `${size}px`, ...(margin ? { marginInline: margin } : {}) } as CSSProperties}
    >
      {mode !== "badge" && (
        <span className="wings-art" aria-hidden="true" style={artBox(size, scale)}>
          {mode === "mini" ? <MiniArt tier={tier} /> : <FullArt tier={tier} />}
        </span>
      )}
      <span className="wings-avatar">{children}</span>
      {mode === "badge" && (
        <span
          className="wings-badge"
          aria-hidden="true"
          style={{ width: badgeSize(size), height: badgeSize(size), background: WINGS_BADGE[tier] }}
        />
      )}
    </span>
  );
}

function artBox(size: number, scale: number): CSSProperties {
  const { width, height, left, top } = wingsBox(size, scale);
  return { width, height, left, top };
}

// At a table burning wings (black, the creator's) only breathe: the ember
// layer's slow pulse.
function MiniArt({ tier }: { tier: WingsTier }) {
  const motion = useAmbientMotion();
  return (
    <>
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src={wingsUrl(tier, "mini")} alt="" className="wings-img" />
      {hasFlames(tier) && (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={emberUrl("mini")} alt="" className={`wings-img wings-ember ${motion ? "wings-ember--on" : ""}`} />
      )}
    </>
  );
}

function FullArt({ tier }: { tier: WingsTier }) {
  if (hasFlames(tier)) return <FlamingWingsFx tier={tier} />;
  return (
    <>
      <span className="wings-halo" style={{ "--wings-halo": WINGS_HALO[tier] } as CSSProperties} />
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src={wingsUrl(tier, "full")} alt="" className="wings-img" />
    </>
  );
}

// BURNING WINGS AT FULL SIZE (the black tier, and the creator's green wings
// with the same flames): Profile and the milestone only, because it is
// about 160 moving shapes (about 100 on a touch screen). Fetched rather than bundled, so a table never carries
// the flames it doesn't draw. Until they arrive, or if they don't, it is the
// wings and their glow. Motion off: the same picture, still.
type Flame = { class: string; d: string; grad: "fl" | "fl2"; dur: number; delay: number };
type Ember = { cx: number; cy: number; r: number; dur: number; delay: number };
type Stop = [offset: number, color: string, opacity: number];
type FlameData = {
  viewBox: string;
  back: Flame[];
  front: Flame[];
  embers: Ember[];
  gradients: Record<"fl" | "fl2", Stop[]>;
  blur: number;
};

let flamesRead: Promise<FlameData | null> | null = null;

function readFlames() {
  flamesRead ??= fetch(FLAMES_URL)
    .then((response) => (response.ok ? (response.json() as Promise<FlameData>) : null))
    .catch(() => null);
  return flamesRead;
}

// A touch screen, read live: fewer flames there (flamesForPointer, lib/wings.ts).
const COARSE_POINTER = "(pointer: coarse)";

function subscribeCoarsePointer(onChange: () => void) {
  const query = window.matchMedia(COARSE_POINTER);
  query.addEventListener("change", onChange);
  return () => query.removeEventListener("change", onChange);
}

function useCoarsePointer(): boolean {
  return useSyncExternalStore(
    subscribeCoarsePointer,
    () => window.matchMedia(COARSE_POINTER).matches,
    () => false
  );
}

function FlamingWingsFx({ tier }: { tier: WingsTier }) {
  const uid = useId();
  const motion = useAmbientMotion();
  const coarse = useCoarsePointer();
  const [flames, setFlames] = useState<FlameData | null>(null);
  useEffect(() => {
    let cancelled = false;
    readFlames().then((data) => {
      if (!cancelled) setFlames(data);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  const shown = flames ? flamesForPointer(flames, coarse) : null;
  const fill = (grad: "fl" | "fl2") => `url(#${uid}-${grad})`;
  const flame = (f: Flame, i: number) => (
    <path
      key={i}
      className={f.class === "flame fi" ? "wings-flame wings-flame--inner" : "wings-flame"}
      d={f.d}
      fill={fill(f.grad)}
      style={{ animationDuration: `${f.dur}s`, animationDelay: `${f.delay}s` }}
    />
  );
  return (
    <>
      <span className="wings-halo" style={{ "--wings-halo": WINGS_HALO[tier] } as CSSProperties} />
      <svg
        viewBox="0 0 1075 695"
        className={`wings-fx ${motion ? "wings-fx--on" : ""}`}
        aria-hidden="true"
        focusable="false"
      >
        {flames && (
          <defs>
            <filter id={`${uid}-blur`} x="-10%" y="-10%" width="120%" height="120%">
              <feGaussianBlur stdDeviation={flames.blur} />
            </filter>
            {(["fl", "fl2"] as const).map((grad) => (
              <linearGradient key={grad} id={`${uid}-${grad}`} x1="0" y1="1" x2="0" y2="0">
                {flames.gradients[grad].map(([offset, color, opacity]) => (
                  <stop key={offset} offset={offset} stopColor={color} stopOpacity={opacity} />
                ))}
              </linearGradient>
            ))}
          </defs>
        )}
        {flames && (
          <g opacity={0.8} filter={`url(#${uid}-blur)`}>
            {flames.back.map(flame)}
          </g>
        )}
        <image href={wingsUrl(tier, "full")} width={1075} height={695} />
        <image href={emberUrl("full")} width={1075} height={695} className="wings-glow" />
        {shown && (
          <g>
            {shown.front.map(flame)}
            {shown.embers.map((e, i) => (
              <circle
                key={i}
                className="wings-spark"
                cx={e.cx}
                cy={e.cy}
                r={e.r}
                fill="#ffb347"
                style={{ animationDuration: `${e.dur}s`, animationDelay: `${e.delay}s` }}
              />
            ))}
          </g>
        )}
      </svg>
    </>
  );
}

// Loads a tier's full art ahead of a moment that lasts only seconds. Resolves
// when it's ready, or anyway after a moment.
export function preloadFullWings(tier: WingsTier): Promise<unknown> {
  const load = (url: string) => {
    const image = new Image();
    image.src = url;
    return image.decode().catch(() => {});
  };
  const ready = Promise.all(
    hasFlames(tier) ? [load(wingsUrl(tier, "full")), load(emberUrl("full")), readFlames()] : [load(wingsUrl(tier, "full"))]
  );
  return Promise.race([ready, new Promise((resolve) => setTimeout(resolve, 1500))]);
}

// THE SETTING, read live (as Card animations and Sound).
const WINGS_SETTING_EVENT = "nobs:wings-change";

function subscribeWingsSetting(onChange: () => void) {
  window.addEventListener("storage", onChange);
  window.addEventListener(WINGS_SETTING_EVENT, onChange);
  return () => {
    window.removeEventListener("storage", onChange);
    window.removeEventListener(WINGS_SETTING_EVENT, onChange);
  };
}

export function useWingsOn(): boolean {
  return useSyncExternalStore(subscribeWingsSetting, readWingsOn, () => true);
}

export function setWingsOn(on: boolean) {
  writeWingsOn(on);
  window.dispatchEvent(new Event(WINGS_SETTING_EVENT));
}
