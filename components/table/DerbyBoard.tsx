"use client";

import { useEffect, useId, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { preload } from "react-dom";
import { boardGeometry, clampScore } from "@/lib/boardLayout";
import { skinLane } from "@/lib/boardSkins";
import type { TrackBoard } from "@/lib/customBoards";
import {
  derbyHorseScale,
  derbyHorseTransform,
  derbyLaneCount,
  derbyPose,
  derbySlideFrames,
} from "@/lib/derbyTrack";

// THE DERBY (lib/customBoards.ts, lib/derbyTrack.ts): a racetrack picture
// stretched to the strip, and one horse a player round the oval. Its own
// component, because a curved track shares nothing with the board code: the
// straight line of the pegs' CSS transition would cut across the infield, and
// boardPatternFor / boardGeometryFor would turn a 4-lane game into Straight.
// Display only: a horse is just its score.
//
// DRAW ORDER: the nearer horse (lower on screen) on top. That order changes
// during a race, and moving a node in the DOM would cancel its slide, so every
// horse is in every layer, shown in one -- as the two layers in
// CribbageBoard.tsx, for any number of horses.

type Player = { userId: string; name: string; lane: number; score: number };

// A slide's length: the same as the other boards' pegs.
const SLIDE_MS = 400;
// Behind the picture while it loads.
const FALLBACK = "#3d5a2a";

// "Are we in the browser?" without an effect: the track is worked out with
// trigonometry, which differs in its last decimal places between the server
// and the browser, so it is drawn in the browser only.
const subscribeNothing = () => () => {};
const clientSnapshot = () => true;
const serverSnapshot = () => false;

export function DerbyBoard({
  board,
  players,
  lanes,
  fixedSize,
}: {
  board: TrackBoard;
  players: Player[];
  lanes: 3 | 4;
  fixedSize?: { w: number; h: number };
}) {
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

  // For the Settings page's preview, where the table's own preload hasn't run.
  useEffect(() => {
    preload(board.image, { as: "image" });
  }, [board.image]);

  const seated = players.filter((p) => p.lane >= 0 && p.lane < lanes);
  const laneCount = derbyLaneCount(lanes, seated.map((p) => p.lane));
  const drawKey = size ? `${size.w} ${size.h} ${laneCount}` : null;

  // A slide along the lane when a score moves a horse forward a little;
  // anything else (a New Game's reset, a long jump, a new size) just arrives.
  // All of a horse's copies, and its shadow, move together.
  const horseEls = useRef(new Map<string, SVGGElement>());
  const shadowEls = useRef(new Map<string, SVGEllipseElement>());
  const drawn = useRef<{ key: string | null; at: Record<string, number> }>({ key: null, at: {} });
  useLayoutEffect(() => {
    const before = drawn.current;
    const at: Record<string, number> = {};
    const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    for (const p of seated) {
      const score = clampScore(p.score);
      at[p.userId] = score;
      const from = before.at[p.userId];
      if (!size || before.key !== drawKey || from === undefined || from === score) continue;
      const els = [...horseEls.current].filter(([key]) => key.endsWith(` ${p.userId}`)).map(([, el]) => el);
      const shadow = shadowEls.current.get(p.userId);
      for (const el of [...els, ...(shadow ? [shadow] : [])]) {
        for (const running of el.getAnimations?.() ?? []) running.cancel();
      }
      const frames = still ? null : derbySlideFrames(size.w, size.h, laneCount, p.lane, from, score);
      if (!frames) continue;
      const scale = derbyHorseScale(size.w, laneCount);
      const timing = { duration: SLIDE_MS, easing: "ease-in-out" };
      const horseFrames = frames.map((f) => ({ transform: derbyHorseTransform(f, scale) }));
      for (const el of els) el.animate?.(horseFrames, timing);
      shadow?.animate?.(
        frames.map((f) => ({ transform: `translate(${f.x}px, ${f.y}px)` })),
        timing
      );
    }
    drawn.current = { key: drawKey, at };
  });

  const label = `Scoreboard: ${[...seated]
    .sort((a, b) => a.lane - b.lane)
    .map((p) => `${p.name} ${p.score}`)
    .join(", ")}`;

  if (!size || !onClient) return <div ref={boxRef} className="h-full w-full" />;

  const scale = derbyHorseScale(size.w, laneCount);
  const horses = seated.map((p) => ({
    player: p,
    pose: derbyPose(size.w, size.h, laneCount, p.lane, p.score),
    color: skinLane(board.skin, p.lane).peg,
  }));
  // Far to near: a horse's place in this list is the layer it shows in.
  const order = [...horses].sort((a, b) => a.pose.y - b.pose.y || a.player.lane - b.player.lane);
  const corner = boardGeometry(size.w, size.h).corner;

  return (
    <div ref={boxRef} className="h-full w-full">
      <svg
        role="img"
        aria-label={label}
        width={fixedSize ? undefined : size.w}
        height={fixedSize ? undefined : size.h}
        viewBox={`0 0 ${size.w} ${size.h}`}
        className="block"
        style={fixedSize ? { width: "100%", height: "auto" } : undefined}
      >
        <defs>
          <clipPath id={`${uid}-track`}>
            <rect width={size.w} height={size.h} rx={corner} />
          </clipPath>
          <HorseDefs uid={uid} />
        </defs>
        <g clipPath={`url(#${uid}-track)`}>
          <rect width={size.w} height={size.h} fill={FALLBACK} />
          <image href={board.image} width={size.w} height={size.h} preserveAspectRatio="none" />
        </g>
        <g>
          {horses.map(({ player, pose }) => (
            <ellipse
              key={player.userId}
              ref={(el) => {
                if (el) shadowEls.current.set(player.userId, el);
                else shadowEls.current.delete(player.userId);
              }}
              cy={0.8}
              rx={scale * 58}
              ry={scale * 11}
              fill="#1b1208"
              opacity={0.38}
              style={{ transform: `translate(${pose.x}px, ${pose.y}px)` }}
            />
          ))}
        </g>
        {order.map((_, layer) => (
          <g key={layer}>
            {horses.map(({ player, pose, color }) => (
              <g
                key={player.userId}
                ref={(el) => {
                  const key = `${layer} ${player.userId}`;
                  if (el) horseEls.current.set(key, el);
                  else horseEls.current.delete(key);
                }}
                data-peg={order[layer].player.userId === player.userId ? player.userId : undefined}
                visibility={order[layer].player.userId === player.userId ? undefined : "hidden"}
                style={{ color, transform: derbyHorseTransform(pose, scale) }}
              >
                <use href={`#${uid}-horse`} />
              </g>
            ))}
          </g>
        ))}
      </svg>
    </div>
  );
}

// The horse, defined once a board: it faces right, its hooves about (55, 60).
// The rider's silks are currentColor, so each horse gets its lane's colour.
function HorseDefs({ uid }: { uid: string }) {
  return (
    <>
      <linearGradient id={`${uid}-coat`} x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stopColor="#9a5628" />
        <stop offset="0.55" stopColor="#6f3a1c" />
        <stop offset="1" stopColor="#43220f" />
      </linearGradient>
      <g id={`${uid}-horse`}>
        <path d="M25 28 C15 22 4 24 -6 33 C4 31 13 33 20 37 C22 34 24 31 25 28Z" fill="#24120a" />
        <g fill="none" strokeLinecap="round" strokeLinejoin="round" stroke="#3a1d0d">
          <path d="M72 41 L81 51" strokeWidth="5" />
          <path d="M81 51 L90 54" strokeWidth="3" />
          <path d="M90 54 L96 61" strokeWidth="2.4" stroke="#1c0e06" />
          <path d="M33 40 L41 54" strokeWidth="6.4" />
          <path d="M41 54 L31 59" strokeWidth="3.2" />
          <path d="M31 59 L24 66" strokeWidth="2.4" stroke="#1c0e06" />
        </g>
        <path
          d="M24 28 C28 22 40 22 48 23 C56 24 62 21 67 19 C72 14 78 8 85 7 C88 6 91 7 93 9 C98 12 104 16 108 21 C109 23 108 25 105 25 C100 25 96 22 92 21 C88 22 84 28 80 36 C78 42 74 46 68 47 C60 48 46 47 38 46 C32 45 27 42 24 38 C21 34 22 30 24 28Z"
          fill={`url(#${uid}-coat)`}
          stroke="#2a160a"
          strokeWidth="1"
        />
        <path d="M91 9 L92.5 2.5 L95.5 9Z" fill="#43220f" stroke="#2a160a" strokeWidth="0.8" strokeLinejoin="round" />
        <path d="M68 18 C74 11 80 6 90 7 C84 9 78 13 72 21Z" fill="#24120a" />
        <path d="M96 11 L105 20" stroke="#f3ece0" strokeWidth="1.6" strokeLinecap="round" opacity="0.9" />
        <circle cx="96.5" cy="13.5" r="1" fill="#120904" />
        <path d="M30 30 C36 28 40 32 38 40" fill="none" stroke="#b46a37" strokeWidth="1.2" opacity="0.55" strokeLinecap="round" />
        <path d="M62 28 C68 30 70 36 66 42" fill="none" stroke="#b46a37" strokeWidth="1.2" opacity="0.55" strokeLinecap="round" />
        <g fill="none" strokeLinecap="round" strokeLinejoin="round">
          <path d="M74 42 L88 49" strokeWidth="6" stroke="#6a3519" />
          <path d="M88 49 L102 51" strokeWidth="3.6" stroke="#4a2410" />
          <path d="M102 51 L110 57" strokeWidth="2.8" stroke="#1c0e06" />
          <path d="M103 52 L107 55" strokeWidth="2.8" stroke="#f3ece0" />
          <path d="M30 38 L19 50" strokeWidth="8" stroke="#6a3519" />
          <path d="M19 50 L8 54" strokeWidth="3.8" stroke="#4a2410" />
          <path d="M8 54 L1 60" strokeWidth="2.8" stroke="#1c0e06" />
          <path d="M9 54 L5 57" strokeWidth="2.8" stroke="#f3ece0" />
        </g>
        <rect x="50" y="22.5" width="9" height="9" rx="1.5" fill="currentColor" stroke="#2a160a" strokeWidth="0.7" />
        <g strokeLinecap="round" strokeLinejoin="round" fill="none">
          <path d="M55 27 L60 34 L67 36" stroke="#f3ece0" strokeWidth="3" />
          <path d="M66 36 L69 36.5" stroke="#1c0e06" strokeWidth="3.2" />
          <path d="M55 25 L68 14" stroke="currentColor" strokeWidth="7.5" />
          <path d="M66 16 L79 17" stroke="#f3ece0" strokeWidth="2.6" />
        </g>
        <circle cx="71.5" cy="12" r="4.6" fill="currentColor" stroke="#2a160a" strokeWidth="0.8" />
        <path d="M68 11 H75" stroke="#f3ece0" strokeWidth="1.4" />
      </g>
    </>
  );
}
