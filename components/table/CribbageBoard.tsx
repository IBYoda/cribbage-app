"use client";

import { memo, useEffect, useId, useMemo, useRef, useState } from "react";
import {
  BOARD_LANES,
  boardGeometry,
  boardHoles,
  holePosition,
  nextPegs,
  type BoardGeometry,
  type PegPair,
} from "@/lib/boardLayout";
import { DEFAULT_BOARD_SKIN, type BoardSkin } from "@/lib/boardSkins";

// THE BOARD STRIP (PRD item 31, step 1b): a 3-lane cribbage board, drawn in
// SVG at the strip's own size (lib/boardLayout.ts), its look from a skin
// (lib/boardSkins.ts). All three lanes always show, as on a real board; a
// lane nobody sits in has no pegs. Not interactive.
//
// players: each with their lane, from the seat order (laneOf: the first seat
// lane 0 -- red on the classic board -- the second lane 1, the third lane 2),
// so every screen shows the same colours. Two pegs each (see nextPegs): the front on the
// score, the back on the score before the last scoring. A peg that moves
// slides to its new hole (~400ms; instant with reduced motion --
// app/globals.css, .board-peg).

export type BoardPlayer = {
  userId: string;
  name: string;
  lane: number;
  score: number;
  lastPoints: number | null;
};

export function CribbageBoard({
  players,
  skin = DEFAULT_BOARD_SKIN,
}: {
  players: BoardPlayer[];
  skin?: BoardSkin;
}) {
  const uid = useId().replace(/:/g, "");
  const boxRef = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState<{ w: number; h: number } | null>(null);
  useEffect(() => {
    const el = boxRef.current;
    if (!el) return;
    const measure = () => {
      const w = Math.round(el.clientWidth);
      const h = Math.round(el.clientHeight);
      setSize((cur) => (cur && cur.w === w && cur.h === h ? cur : w > 0 && h > 0 ? { w, h } : null));
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  // Pegs slide only when a score moves them. A new size (the first
  // measure, a resize, a rotation) redraws them in place: they are drawn
  // without a transition until a moment after the size settles (a timer,
  // not an animation frame, so a hidden tab catches up too).
  const [settledSize, setSettledSize] = useState(size);
  const resizing = settledSize !== size;
  useEffect(() => {
    if (!resizing) return;
    const timer = setTimeout(() => setSettledSize(size), 60);
    return () => clearTimeout(timer);
  }, [resizing, size]);

  // Each player's two pegs, kept from render to render so the back peg
  // survives a 0 award and the pegs leapfrog. Updated during render (as
  // ScoreFlash does): the next pegs follow only from the scores and the
  // pegs before, so this settles in one pass.
  const seated = players.filter((p) => p.lane >= 0 && p.lane < BOARD_LANES);
  const [pegs, setPegs] = useState<Record<string, PegPair>>({});
  const next: Record<string, PegPair> = {};
  for (const p of seated) next[p.userId] = nextPegs(pegs[p.userId] ?? null, p.score, p.lastPoints);
  const changed =
    Object.keys(next).length !== Object.keys(pegs).length ||
    seated.some((p) => {
      const a = pegs[p.userId];
      const b = next[p.userId];
      return !a || a[0] !== b[0] || a[1] !== b[1];
    });
  if (changed) setPegs(next);

  const geometry = useMemo(() => (size ? boardGeometry(size.w, size.h) : null), [size]);
  const label = `Scoreboard: ${[...seated]
    .sort((a, b) => a.lane - b.lane)
    .map((p) => `${p.name} ${p.score}`)
    .join(", ")}`;

  return (
    <div ref={boxRef} className="h-full w-full">
      {geometry && (
        <svg
          role="img"
          aria-label={label}
          width={geometry.width}
          height={geometry.height}
          viewBox={`0 0 ${geometry.width} ${geometry.height}`}
          className="block"
        >
          <BoardWood g={geometry} skin={skin} uid={uid} />
          <defs>
            {skin.lanes.map((lane, i) => (
              <radialGradient key={i} id={`${uid}-peg${i}`} cx="35%" cy="30%" r="70%">
                <stop offset="0%" stopColor={lane.pegLight} />
                <stop offset="45%" stopColor={lane.peg} />
                <stop offset="100%" stopColor={lane.pegDark} />
              </radialGradient>
            ))}
          </defs>
          {/* Always in the same order (each player's peg A, then peg B):
              moving a peg's element in the DOM -- say, to draw the front
              peg last -- would cancel its slide. */}
          {seated.flatMap((p) =>
            ([0, 1] as const).map((peg) => {
              const at = holePosition(geometry, p.lane, next[p.userId][peg], peg);
              return (
                <g
                  key={`${p.userId}-${peg}`}
                  data-peg={`${p.userId}-${peg}`}
                  className={resizing ? "board-peg board-peg--still" : "board-peg"}
                  style={{ transform: `translate(${at.x}px, ${at.y}px)` }}
                >
                  <circle cx={geometry.pegR * 0.18} cy={geometry.pegR * 0.28} r={geometry.pegR} fill="#000" opacity={0.35} />
                  <circle r={geometry.pegR} fill={`url(#${uid}-peg${p.lane})`} />
                </g>
              );
            })
          )}
        </svg>
      )}
    </div>
  );
}

// THE SELF-SCORING BANNER (a Muggins table): in the board strip's own slot
// and size (.sq-board), in the board skin's palette and rim -- the wood's
// colours, its dark edge and lit inner bevel, the same corner -- but flat:
// no grain, holes, lanes or pegs. The players keep their own board.
export function SelfScoringBanner({ skin = DEFAULT_BOARD_SKIN }: { skin?: BoardSkin }) {
  return (
    <div
      className="self-scoring-banner"
      style={{
        background: `linear-gradient(${skin.wood.top}, ${skin.wood.bottom})`,
        borderColor: skin.rim.edge,
        boxShadow: `inset 0 0 0 3px ${skin.rim.highlight}55, inset 0 0 0 4px ${skin.rim.edge}73`,
        color: skin.rim.edge,
      }}
    >
      <p className="self-scoring-banner__title">SELF SCORING</p>
      <p className="self-scoring-banner__note">Keep your own board</p>
    </div>
  );
}

// The wood, the lanes' paint and every hole: drawn once per size and skin,
// so a score change re-renders only the pegs.
const BoardWood = memo(function BoardWood({ g, skin, uid }: { g: BoardGeometry; skin: BoardSkin; uid: string }) {
  const holes = boardHoles(g);
  const lastX = g.columnX[g.columnX.length - 1];
  // Grain: a tile of gently wavy lines, as wide as a plank's figure.
  const tileW = 220;
  const grainLines = Array.from({ length: 9 }, (_, i) => {
    const y = (g.height * (i + 0.5)) / 9;
    const d = 1.2 + (i % 3) * 0.6;
    return { y, d, w: i % 2 === 0 ? 0.7 : 0.4 };
  });
  return (
    <>
      <defs>
        <linearGradient id={`${uid}-wood`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor={skin.wood.top} />
          <stop offset="100%" stopColor={skin.wood.bottom} />
        </linearGradient>
        <linearGradient id={`${uid}-sheen`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#fff" stopOpacity={0.22} />
          <stop offset="40%" stopColor="#fff" stopOpacity={0} />
          <stop offset="100%" stopColor="#000" stopOpacity={0.12} />
        </linearGradient>
        <pattern id={`${uid}-grain`} width={tileW} height={g.height} patternUnits="userSpaceOnUse">
          {grainLines.map((l, i) => (
            <path
              key={i}
              d={`M0 ${l.y} C${tileW * 0.3} ${l.y - l.d}, ${tileW * 0.6} ${l.y + l.d}, ${tileW} ${l.y}`}
              fill="none"
              stroke={skin.wood.grain}
              strokeWidth={l.w}
            />
          ))}
          <ellipse
            cx={tileW * 0.62}
            cy={g.height * 0.35}
            rx={tileW * 0.05}
            ry={g.height * 0.035}
            fill="none"
            stroke={skin.wood.grain}
            strokeWidth={0.5}
          />
        </pattern>
      </defs>
      {/* The board: the wood, its grain, a sheen, and the rim's bevel. */}
      <rect x={0.5} y={0.5} width={g.width - 1} height={g.height - 1} rx={g.corner} fill={`url(#${uid}-wood)`} />
      <rect
        x={0.5}
        y={0.5}
        width={g.width - 1}
        height={g.height - 1}
        rx={g.corner}
        fill={`url(#${uid}-grain)`}
        opacity={skin.wood.grainOpacity}
      />
      <rect x={0.5} y={0.5} width={g.width - 1} height={g.height - 1} rx={g.corner} fill={`url(#${uid}-sheen)`} />
      <rect
        x={0.5}
        y={0.5}
        width={g.width - 1}
        height={g.height - 1}
        rx={g.corner}
        fill="none"
        stroke={skin.rim.edge}
        strokeWidth={1}
      />
      <rect
        x={g.rim}
        y={g.rim}
        width={g.width - 2 * g.rim}
        height={g.height - 2 * g.rim}
        rx={Math.max(g.corner - g.rim, 2)}
        fill="none"
        stroke={skin.rim.highlight}
        strokeOpacity={0.55}
        strokeWidth={0.8}
      />
      <rect
        x={g.rim - 0.8}
        y={g.rim - 0.8}
        width={g.width - 2 * g.rim + 1.6}
        height={g.height - 2 * g.rim + 1.6}
        rx={Math.max(g.corner - g.rim, 2)}
        fill="none"
        stroke={skin.rim.edge}
        strokeOpacity={0.45}
        strokeWidth={0.8}
      />
      {/* Each lane's paint: a line between its two rows, from the home end
          to the far end. */}
      {g.rows.map((row, lane) => {
        const mid = (row.out + row.back) / 2;
        return (
          <path
            key={lane}
            d={`M${g.startX[0]} ${mid} H${lastX + g.pitch * 0.5}`}
            fill="none"
            stroke={skin.lanes[lane].paint}
            strokeWidth={Math.max(1, (row.back - row.out) * 0.16)}
            strokeLinecap="round"
            opacity={0.85}
          />
        );
      })}
      {/* The holes: dark, with a lighter lip on the lit side. */}
      <g>
        {holes.map((h, i) => (
          <g key={i}>
            <circle cx={h.x} cy={h.y + 0.3} r={g.holeR + 0.35} fill={skin.hole.edge} opacity={0.55} />
            <circle cx={h.x} cy={h.y} r={g.holeR} fill={skin.hole.fill} />
          </g>
        ))}
      </g>
    </>
  );
});
