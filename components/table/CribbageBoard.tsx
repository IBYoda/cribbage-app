"use client";

import { memo, useEffect, useId, useMemo, useRef, useState, useSyncExternalStore } from "react";
import {
  BOARD_LANES,
  boardGeometry,
  boardHoles,
  holePosition,
  nextPegs,
  type BoardGeometry,
  type PegPair,
} from "@/lib/boardLayout";
import {
  DEFAULT_BOARD_SKIN,
  bannerTextColor,
  boardSkinById,
  darken,
  metalLaneStops,
  pegShades,
  readBoardSkinId,
  writeBoardSkinId,
  type BoardSkin,
} from "@/lib/boardSkins";

// THE BOARD STRIP (PRD item 31): a 3-lane cribbage board, drawn in SVG at the
// strip's own size (lib/boardLayout.ts), its look from a skin
// (lib/boardSkins.ts -- the one THIS player picked in Profile: useBoardSkin).
// All three lanes always show, as on a real board; a lane nobody sits in has
// no pegs. Not interactive.
//
// players: each with their lane, from the seat order (laneOf: the first seat
// lane 0, the second lane 1, the third lane 2), so every screen puts everyone
// in the same lane. Two pegs each (see nextPegs): the front on the score, the
// back on the score before the last scoring. A peg that moves slides to its
// new hole (~400ms; instant with reduced motion -- app/globals.css,
// .board-peg).
//
// fixedSize: draw the board for that strip size and scale the picture to the
// box's width (the Profile picker's previews), instead of measuring the box.

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
  fixedSize,
}: {
  players: BoardPlayer[];
  skin?: BoardSkin;
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
  const size = useMemo(
    () => (fixedW && fixedH ? { w: fixedW, h: fixedH } : measured),
    [fixedW, fixedH, measured]
  );
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
          width={fixedSize ? undefined : geometry.width}
          height={fixedSize ? undefined : geometry.height}
          viewBox={`0 0 ${geometry.width} ${geometry.height}`}
          className="block"
          style={fixedSize ? { width: "100%", height: "auto" } : undefined}
        >
          <BoardWood g={geometry} skin={skin} uid={uid} />
          <defs>
            {skin.lanes.map((lane, i) => {
              const shade = pegShades(lane.peg);
              return (
                <radialGradient key={i} id={`${uid}-peg${i}`} cx="36%" cy="30%" r="70%">
                  <stop offset="0%" stopColor={shade.light} />
                  <stop offset="32%" stopColor={shade.base} />
                  <stop offset="100%" stopColor={shade.dark} />
                </radialGradient>
              );
            })}
            <filter id={`${uid}-pegshadow`} x="-50%" y="-50%" width="200%" height="200%">
              <feDropShadow dx={0.5} dy={0.8} stdDeviation={0.8} floodColor="#000" floodOpacity={0.5} />
            </filter>
          </defs>
          {/* Two layers, each with every peg in the same order (each
              player's peg A, then peg B): the back pegs show in the first,
              the front pegs in the second, so a front peg is always drawn
              over a back peg it overlaps. Each peg is in both layers --
              shown in one, hidden in the other -- and moves in both, so
              when it changes layer it is already in place. Moving a peg's
              element in the DOM instead (to draw it last) would cancel its
              slide. */}
          {(["back", "front"] as const).map((layer) => (
            <g key={layer}>
              {seated.flatMap((p) =>
                ([0, 1] as const).map((peg) => {
                  const pair = next[p.userId];
                  const front = pair[1] >= pair[0] ? 1 : 0;
                  const shown = (peg === front) === (layer === "front");
                  const at = holePosition(geometry, p.lane, pair[peg], peg);
                  return (
                    <g
                      key={`${p.userId}-${peg}`}
                      data-peg={shown ? `${p.userId}-${peg}` : undefined}
                      visibility={shown ? undefined : "hidden"}
                      className={resizing ? "board-peg board-peg--still" : "board-peg"}
                      style={{ transform: `translate(${at.x}px, ${at.y}px)` }}
                    >
                      <PegShape r={geometry.pegR} fill={`url(#${uid}-peg${p.lane})`} shadow={`url(#${uid}-pegshadow)`} />
                    </g>
                  );
                })
              )}
            </g>
          ))}
        </svg>
      )}
    </div>
  );
}

// A peg, r px round (outline included), centred on (0, 0): a soft drop
// shadow, a round body (a radial gradient), a dark outline with a faint white
// ring inside it, and a small white glint.
const PEG_OUTLINE = 1.7;

function PegShape({ r, fill, shadow }: { r: number; fill: string; shadow: string }) {
  return (
    <>
      <circle
        r={r - PEG_OUTLINE / 2}
        fill={fill}
        stroke="#000"
        strokeOpacity={0.8}
        strokeWidth={PEG_OUTLINE}
        filter={shadow}
      />
      <circle r={r - PEG_OUTLINE - 0.5} fill="none" stroke="#fff" strokeOpacity={0.5} strokeWidth={1} />
      <circle cx={-r * 0.32} cy={-r * 0.38} r={Math.max(r * 0.2, 0.8)} fill="#fff" opacity={0.85} />
    </>
  );
}

// THE PROFILE SETTING "Board" (lib/boardSkins.ts: this device only), read
// live. A change in another tab arrives as a storage event, one in this tab
// through setBoardSkin. Before the page is hydrated: Classic Pine.
const BOARD_SETTING_EVENT = "nobs:board-change";

function subscribeBoardSetting(onChange: () => void) {
  window.addEventListener("storage", onChange);
  window.addEventListener(BOARD_SETTING_EVENT, onChange);
  return () => {
    window.removeEventListener("storage", onChange);
    window.removeEventListener(BOARD_SETTING_EVENT, onChange);
  };
}

export function useBoardSkin(): BoardSkin {
  return boardSkinById(useSyncExternalStore(subscribeBoardSetting, readBoardSkinId, () => DEFAULT_BOARD_SKIN.id));
}

export function setBoardSkin(id: string) {
  writeBoardSkinId(id);
  window.dispatchEvent(new Event(BOARD_SETTING_EVENT));
}

// THE SELF-SCORING BANNER (a Muggins table): in the board strip's own slot
// and size (.sq-board), in the board skin's palette and rim -- the board's
// colours, its edge and lit inner bevel, the same corner -- but flat: no
// grain, holes, lanes or pegs. The text is the rim colour, or a light cream
// where that wouldn't read (bannerTextColor). The players keep their own
// board.
export function SelfScoringBanner({ skin = DEFAULT_BOARD_SKIN }: { skin?: BoardSkin }) {
  return (
    <div
      className="self-scoring-banner"
      style={{
        background: `linear-gradient(${skin.wood.top}, ${skin.wood.bottom})`,
        borderColor: skin.rim.edge,
        boxShadow: `inset 0 0 0 3px ${skin.rim.highlight}55, inset 0 0 0 4px ${skin.rim.edge}73`,
        color: bannerTextColor(skin),
      }}
    >
      <p className="self-scoring-banner__title">SELF SCORING</p>
      <p className="self-scoring-banner__note">Keep your own board</p>
    </div>
  );
}

// The board, the lanes and every hole: drawn once per size and skin, so a
// score change re-renders only the pegs.
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
  // A lane's panel (not "paint" lanes): round both rows, from the start
  // holes to past hole 60.
  const panels = g.rows.map((row) => {
    const gap = row.back - row.out;
    const x = g.startX[0] - g.pitch * 0.55;
    return { x, y: row.out - gap * 0.5, w: lastX + g.pitch * 0.55 - x, h: gap * 2, rx: gap * 0.5 };
  });
  const face = { x: 0.5, y: 0.5, width: g.width - 1, height: g.height - 1, rx: g.corner };
  const chrome = skin.rim.chrome;
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
        {skin.wood.grain && (
          <pattern id={`${uid}-grain`} width={tileW} height={g.height} patternUnits="userSpaceOnUse">
            {grainLines.map((l, i) => (
              <path
                key={i}
                d={`M0 ${l.y} C${tileW * 0.3} ${l.y - l.d}, ${tileW * 0.6} ${l.y + l.d}, ${tileW} ${l.y}`}
                fill="none"
                stroke={skin.wood.grain!}
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
        )}
        {/* Brushed metal: fine horizontal lines, light and dark, every 3px. */}
        <pattern id={`${uid}-brushed`} width={8} height={3} patternUnits="userSpaceOnUse">
          <rect y={0} width={8} height={1} fill="#fff" fillOpacity={0.1} />
          <rect y={1.5} width={8} height={1} fill="#000" fillOpacity={0.12} />
        </pattern>
        {/* One soft diagonal streak of light across the steel. */}
        <linearGradient id={`${uid}-streak`} x1="0" y1="0" x2="1" y2="1">
          <stop offset="30%" stopColor="#fff" stopOpacity={0} />
          <stop offset="45%" stopColor="#fff" stopOpacity={0.14} />
          <stop offset="60%" stopColor="#fff" stopOpacity={0} />
        </linearGradient>
        {chrome && (
          <linearGradient id={`${uid}-chrome`} x1="0" y1="0" x2="1" y2="1">
            {chrome.map((c, i) => (
              <stop key={i} offset={`${(i * 100) / (chrome.length - 1)}%`} stopColor={c} />
            ))}
          </linearGradient>
        )}
        {skin.laneStyle === "metal" &&
          skin.lanes.map((lane, i) => (
            <linearGradient key={i} id={`${uid}-metal${i}`} x1="0" y1="0" x2="0" y2="1">
              {metalLaneStops(lane.color).map(([at, c]) => (
                <stop key={at} offset={`${at}%`} stopColor={c} />
              ))}
            </linearGradient>
          ))}
      </defs>
      {/* The board: its face, grain or brushed finish, a sheen, and the rim. */}
      <rect {...face} fill={`url(#${uid}-wood)`} />
      {skin.wood.grain && <rect {...face} fill={`url(#${uid}-grain)`} opacity={skin.wood.grainOpacity} />}
      {skin.finish === "brushed-steel" && (
        <>
          <rect {...face} fill={`url(#${uid}-brushed)`} />
          <rect {...face} fill={`url(#${uid}-streak)`} />
        </>
      )}
      <rect {...face} fill={`url(#${uid}-sheen)`} />
      {chrome ? (
        // A chrome rim: a 5px band in the chrome gradient, a dark hairline
        // outside it.
        <>
          <rect
            x={2.5}
            y={2.5}
            width={g.width - 5}
            height={g.height - 5}
            rx={Math.max(g.corner - 2.5, 1)}
            fill="none"
            stroke={`url(#${uid}-chrome)`}
            strokeWidth={5}
          />
          <rect {...face} fill="none" stroke="#1a1c20" strokeWidth={1} />
        </>
      ) : (
        <>
          <rect {...face} fill="none" stroke={skin.rim.edge} strokeWidth={1} />
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
        </>
      )}
      {/* Each lane: a painted line between its two rows (Classic Pine), or
          a panel round both -- filled, outlined or brushed metal. */}
      {g.rows.map((row, lane) => {
        const color = skin.lanes[lane].color;
        const p = panels[lane];
        if (skin.laneStyle === "paint") {
          const mid = (row.out + row.back) / 2;
          return (
            <path
              key={lane}
              d={`M${g.startX[0]} ${mid} H${lastX + g.pitch * 0.5}`}
              fill="none"
              stroke={skin.lanes[lane].paint ?? color}
              strokeWidth={Math.max(1, (row.back - row.out) * 0.16)}
              strokeLinecap="round"
              opacity={0.85}
            />
          );
        }
        if (skin.laneStyle === "outline") {
          return (
            <rect
              key={lane}
              x={p.x}
              y={p.y}
              width={p.w}
              height={p.h}
              rx={p.rx}
              fill={skin.panel}
              stroke={color}
              strokeOpacity={0.85}
              strokeWidth={1.4}
            />
          );
        }
        if (skin.laneStyle === "metal") {
          return (
            <g key={lane}>
              <rect
                x={p.x}
                y={p.y}
                width={p.w}
                height={p.h}
                rx={p.rx}
                fill={`url(#${uid}-metal${lane})`}
                stroke={darken(color, 0.6)}
                strokeWidth={1}
              />
              <rect x={p.x} y={p.y} width={p.w} height={p.h} rx={p.rx} fill={`url(#${uid}-brushed)`} />
              <rect
                x={p.x + 1}
                y={p.y + 1}
                width={p.w - 2}
                height={p.h - 2}
                rx={Math.max(p.rx - 1, 0)}
                fill="none"
                stroke="#fff"
                strokeOpacity={0.35}
                strokeWidth={1}
              />
            </g>
          );
        }
        return (
          <rect
            key={lane}
            x={p.x}
            y={p.y}
            width={p.w}
            height={p.h}
            rx={p.rx}
            fill={color}
            stroke={darken(color, 0.45)}
            strokeWidth={0.8}
          />
        );
      })}
      {/* The holes: dark, with a lighter lip on the lit side (Classic Pine)
          or a thin edge in the lane's colour (outlined lanes). */}
      <g>
        {holes.map((h, i) => (
          <g key={i}>
            {skin.hole.lip && (
              <circle cx={h.x} cy={h.y + 0.3} r={g.holeR + 0.35} fill={skin.hole.lip} opacity={0.55} />
            )}
            <circle
              cx={h.x}
              cy={h.y}
              r={g.holeR}
              fill={skin.hole.fill}
              stroke={skin.hole.laneStroke ? skin.lanes[h.lane].color : undefined}
              strokeOpacity={skin.hole.laneStroke ? 0.85 : undefined}
              strokeWidth={skin.hole.laneStroke ? 0.6 : undefined}
            />
          </g>
        ))}
      </g>
    </>
  );
});
