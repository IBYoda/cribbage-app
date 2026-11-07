"use client";

import { useEffect, useId, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import type { ScorePlate } from "@/components/table/ScoreStrip";
import { useAmbientMotion } from "@/components/table/useAmbientMotion";
import { emberUrl, placementFor, wingsBox, wingsUrl, type WingsTier } from "@/lib/wings";
import { boardGeometry } from "@/lib/boardLayout";
import {
  BEER_DRAIN_MS,
  BEER_FOAM_COLOR,
  beerAriaLabel,
  beerDrains,
  beerDrawing,
  beerEase,
  beerLayerUrl,
  beerScene,
  type BeerDrawing,
  type BeerSceneAvatar,
  type BeerSceneMug,
  type BeerSceneScore,
} from "@/lib/beerBoard";

// THE BEER BOARD (lib/customBoards.ts, lib/beerBoard.ts): a shelf of mugs, one
// or two a player, draining as the scores rise. Its own component, as The
// Derby is. It replaces the score plates too, so it is drawn from the plates
// (their numbers, avatars and order), and shows every score and avatar itself.
// Display only.
//
// A MUG is five layers (lib/beerBoard.ts has the numbers): the base; the ghost
// glass above the beer's surface; the beer below it; the foam (a scalloped cap
// and the band) riding the surface; the crown, only when nearly full. All of it
// is SVG: HTML inside an SVG misplaces on iOS Safari.
//
// A DRAIN sets attributes through refs, frame by frame, with no React state: a
// score sets the final level, and React draws that; the effect then puts the
// old level straight back, before paint, and walks it down. So a re-render
// mid-drain changes nothing, and a drain always lands on what React drew.

const subscribeNothing = () => () => {};
const clientSnapshot = () => true;
const serverSnapshot = () => false;

export function BeerBoard({ plates, fixedSize }: { plates: ScorePlate[]; fixedSize?: { w: number; h: number } }) {
  const uid = useId().replace(/:/g, "");
  const boxRef = useRef<HTMLDivElement>(null);
  const [measured, setMeasured] = useState<{ w: number; h: number } | null>(null);
  useEffect(() => {
    const el = boxRef.current;
    if (!el || fixedSize) return;
    const measure = () => {
      const w = Math.round(el.clientWidth);
      const h = Math.round(el.clientHeight);
      setMeasured((cur) => (cur && cur.w === w && cur.h === h ? cur : w > 0 && h > 0 ? { w, h } : null));
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, [fixedSize]);
  const fixedW = fixedSize?.w;
  const fixedH = fixedSize?.h;
  const size = useMemo(() => (fixedW && fixedH ? { w: fixedW, h: fixedH } : measured), [fixedW, fixedH, measured]);
  const onClient = useSyncExternalStore(subscribeNothing, clientSnapshot, serverSnapshot);

  if (!size || !onClient) return <div ref={boxRef} className="h-full w-full" />;

  const { w, h } = size;
  const scene = beerScene(w, h, plates);
  const corner = boardGeometry(w, h).corner;
  const shelfY = h * 0.9;

  return (
    <div ref={boxRef} className="h-full w-full">
      <svg
        role="img"
        aria-label={beerAriaLabel(plates)}
        width={fixedSize ? undefined : w}
        height={fixedSize ? undefined : h}
        viewBox={`0 0 ${w} ${h}`}
        className="block"
        style={fixedSize ? { width: "100%", height: "auto" } : undefined}
      >
        <defs>
          <clipPath id={`${uid}-beerstrip`}>
            <rect width={w} height={h} rx={corner} />
          </clipPath>
          <linearGradient id={`${uid}-wall`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#241c16" />
            <stop offset="1" stopColor="#0d0a08" />
          </linearGradient>
          <linearGradient id={`${uid}-shelf`} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#4a2d1a" />
            <stop offset="1" stopColor="#1c100a" />
          </linearGradient>
          <radialGradient id={`${uid}-warm`} cx="50%" cy="100%" r="75%">
            <stop offset="0" stopColor="#ffb347" stopOpacity={0.22} />
            <stop offset="1" stopColor="#ffb347" stopOpacity={0} />
          </radialGradient>
          <filter id={`${uid}-score`} x="-30%" y="-30%" width="160%" height="160%">
            <feDropShadow dx={0} dy={0} stdDeviation={h * 0.012} floodColor="#ffb347" floodOpacity={0.45} />
          </filter>
        </defs>
        <g clipPath={`url(#${uid}-beerstrip)`}>
          <rect width={w} height={h} fill={`url(#${uid}-wall)`} />
          <rect width={w} height={h} fill={`url(#${uid}-warm)`} />
          <rect y={shelfY} width={w} height={h - shelfY} fill={`url(#${uid}-shelf)`} />
          <rect y={shelfY} width={w} height={1} fill="#b07a48" fillOpacity={0.55} />
        </g>
        {scene.mugs.map((mug) => (
          <BeerMug key={mug.id} mug={mug} uid={uid} />
        ))}
        {/* Under the numbers as well as the avatars: wings never cover a score. */}
        {scene.avatars.map(
          (avatar) => avatar.wings && <MugWings key={avatar.key} tier={avatar.wings} x={avatar.x} y={avatar.y} r={avatar.r} />
        )}
        {scene.scores.map((score) => (
          <ScoreText key={score.key} score={score} filter={`url(#${uid}-score)`} />
        ))}
        {scene.avatars.map((avatar, i) => (
          <MugAvatar key={avatar.key} avatar={avatar} clipId={`${uid}-avatar${i}`} />
        ))}
      </svg>
    </div>
  );
}

// The elements a drain moves.
type MugParts = {
  coverClip: SVGRectElement | null;
  beerClip: SVGRectElement | null;
  cap: SVGPathElement | null;
  band: SVGImageElement | null;
  crown: SVGGElement | null;
};

// What React draws, as attributes, so a frame sets exactly the same names.
function paint(parts: MugParts, height: number, d: BeerDrawing) {
  parts.coverClip?.setAttribute("height", String(d.levelY));
  parts.beerClip?.setAttribute("y", String(d.levelY));
  parts.beerClip?.setAttribute("height", String(Math.max(height + 10 - d.levelY, 0)));
  parts.cap?.setAttribute("d", d.cap.d);
  parts.cap?.setAttribute("opacity", String(d.cap.opacity));
  parts.band?.setAttribute("y", String(d.band.y));
  parts.band?.setAttribute("height", String(d.band.height));
  parts.band?.setAttribute("opacity", String(d.band.opacity));
  parts.crown?.setAttribute("transform", `translate(0 ${d.crown.y})`);
  parts.crown?.setAttribute("opacity", String(d.crown.opacity));
}

function BeerMug({ mug, uid }: { mug: BeerSceneMug; uid: string }) {
  const { id, art, level, score } = mug;
  const parts = useRef<MugParts>({ coverClip: null, beerClip: null, cap: null, band: null, crown: null });
  // The level on screen, the level being headed for, the last score, and the
  // running drain.
  const shown = useRef(level);
  const target = useRef(level);
  const lastScore = useRef(score);
  const frame = useRef<number | null>(null);

  useLayoutEffect(() => {
    const from = lastScore.current;
    lastScore.current = score;
    if (level === target.current) return;
    target.current = level;
    if (frame.current !== null) cancelAnimationFrame(frame.current);
    frame.current = null;
    const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (still || !beerDrains(from, score)) {
      shown.current = level;
      paint(parts.current, art.h, beerDrawing(id, level));
      return;
    }
    const start = shown.current;
    paint(parts.current, art.h, beerDrawing(id, start));
    let began: number | null = null;
    const step = (now: number) => {
      began ??= now;
      const t = Math.min((now - began) / BEER_DRAIN_MS, 1);
      const at = t === 1 ? level : start + (level - start) * beerEase(t);
      shown.current = at;
      paint(parts.current, art.h, beerDrawing(id, at));
      frame.current = t === 1 ? null : requestAnimationFrame(step);
    };
    frame.current = requestAnimationFrame(step);
  }, [level, score, id, art.h]);

  useEffect(
    () => () => {
      if (frame.current !== null) cancelAnimationFrame(frame.current);
    },
    []
  );

  const drawing = beerDrawing(id, level);
  const clip = `${uid}-mug${id}`;
  return (
    <g transform={`translate(${mug.x} ${mug.y}) scale(${mug.scale})`}>
      <defs>
        <clipPath id={`${clip}-cover`}>
          <rect
            ref={(el) => {
              parts.current.coverClip = el;
            }}
            x={0}
            y={0}
            width={art.w}
            height={drawing.levelY}
          />
        </clipPath>
        <clipPath id={`${clip}-beer`}>
          <rect
            ref={(el) => {
              parts.current.beerClip = el;
            }}
            x={0}
            y={drawing.levelY}
            width={art.w}
            height={Math.max(art.h + 10 - drawing.levelY, 0)}
          />
        </clipPath>
        <clipPath id={`${clip}-cap`}>
          <rect x={art.glassX0 - 3} y={0} width={art.glassX1 + 4 - (art.glassX0 - 3)} height={art.h} />
        </clipPath>
      </defs>
      <image href={beerLayerUrl(id, "base")} width={art.w} height={art.h} />
      <image href={beerLayerUrl(id, "cover")} width={art.w} height={art.h} clipPath={`url(#${clip}-cover)`} />
      <image href={beerLayerUrl(id, "beer")} width={art.w} height={art.h} clipPath={`url(#${clip}-beer)`} />
      <g clipPath={`url(#${clip}-cap)`}>
        <path
          ref={(el) => {
            parts.current.cap = el;
          }}
          d={drawing.cap.d}
          fill={BEER_FOAM_COLOR}
          opacity={drawing.cap.opacity}
        />
      </g>
      <image
        ref={(el) => {
          parts.current.band = el;
        }}
        href={beerLayerUrl(id, "band")}
        width={art.w}
        y={drawing.band.y}
        height={drawing.band.height}
        opacity={drawing.band.opacity}
        preserveAspectRatio="none"
      />
      <g
        ref={(el) => {
          parts.current.crown = el;
        }}
        transform={`translate(0 ${drawing.crown.y})`}
        opacity={drawing.crown.opacity}
      >
        <image href={beerLayerUrl(id, "crown")} width={art.w} height={art.h} />
      </g>
    </g>
  );
}

function ScoreText({ score, filter }: { score: BeerSceneScore; filter: string }) {
  return (
    <text
      x={score.x}
      y={score.y}
      fontSize={score.fontSize}
      fontWeight={800}
      textAnchor="middle"
      dominantBaseline="central"
      fill="#fffaf0"
      stroke="#2a1500"
      strokeOpacity={0.8}
      strokeWidth={0.075 * score.fontSize}
      strokeLinejoin="round"
      paintOrder="stroke"
      filter={filter}
      className="tabular-nums"
    >
      {score.text}
    </text>
  );
}

// Mini wings behind a mug's avatar: SVG images, because iOS Safari can't draw
// HTML inside an SVG. The same art and place as WingsFrame (wingsBox,
// lib/wings.ts), with black's slow pulse. Nothing at all without a tier.
function MugWings({ tier, x, y, r }: { tier: WingsTier; x: number; y: number; r: number }) {
  const motion = useAmbientMotion();
  const box = wingsBox(2 * r, placementFor("beer").scale);
  const place = { x: x - r + box.left, y: y - r + box.top, width: box.width, height: box.height };
  return (
    <>
      <image href={wingsUrl(tier, "mini")} {...place} />
      {tier === "black" && (
        <image href={emberUrl("mini")} {...place} className={`wings-ember ${motion ? "wings-ember--on" : ""}`} />
      )}
    </>
  );
}

// The avatar: the lane's ring, a white hairline outside it, and on my own a
// thin gold ring outside that. No photo: the app's letter on grey.
function MugAvatar({ avatar, clipId }: { avatar: BeerSceneAvatar; clipId: string }) {
  const { x, y, r } = avatar;
  return (
    <g>
      {avatar.url ? (
        <>
          <clipPath id={clipId}>
            <circle cx={x} cy={y} r={r} />
          </clipPath>
          <image
            href={avatar.url}
            x={x - r}
            y={y - r}
            width={2 * r}
            height={2 * r}
            preserveAspectRatio="xMidYMid slice"
            clipPath={`url(#${clipId})`}
          />
        </>
      ) : (
        <>
          <circle cx={x} cy={y} r={r} fill="#5d6672" />
          <text
            x={x}
            y={y}
            fontSize={1.15 * r}
            fontWeight={800}
            textAnchor="middle"
            dominantBaseline="central"
            fill="#fff"
          >
            {avatar.letter}
          </text>
        </>
      )}
      <circle cx={x} cy={y} r={r} fill="none" stroke={avatar.ringColor} strokeWidth={0.2 * r} />
      <circle cx={x} cy={y} r={1.14 * r} fill="none" stroke="#fff" strokeOpacity={0.75} strokeWidth={0.06 * r} />
      {avatar.mine && <circle cx={x} cy={y} r={1.24 * r} fill="none" stroke="#ffd24a" strokeWidth={0.09 * r} />}
    </g>
  );
}
