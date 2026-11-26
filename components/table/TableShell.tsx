import type { ReactNode } from "react";
import { SpectatorsEye, WatchingRow } from "@/components/SpectatorsTag";
import {
  DEFAULT_CARD_BACK,
  DEFAULT_TABLE_SURFACE,
  surfaceIsDark,
  type CardBack,
  type TableSurface,
} from "@/lib/appearance";

// The fixed-height table. Six regions, top to bottom, sized by .table-shell in
// app/globals.css: exactly one screen tall, never scrolling, never wider than
// the screen. Only `middle` flexes; everything else has a fixed height, so the
// hand, the piles and the scores sit in the same place for the whole game.
//
// Shared by the real table page and the layout mock (app/dev/table-mock), so
// what the mock proves about fit is true of the page.
export function TableShell({
  header,
  opponents,
  middle,
  piles,
  hand,
  scores,
  sides,
  surface = DEFAULT_TABLE_SURFACE,
  back = DEFAULT_CARD_BACK,
}: {
  header: ReactNode;
  opponents: ReactNode;
  // Phase 3 (3 and 4 players): the seats on my left and right, as narrow
  // columns either side of the middle. Absent (every 2-player table), the
  // middle is rendered exactly as before.
  sides?: { left: ReactNode; right: ReactNode } | null;
  // The only region that absorbs leftover height. Its own content must fit;
  // anything that appears mid-game (errors, notices) is an overlay inside it.
  middle: ReactNode;
  piles: ReactNode;
  hand: ReactNode;
  scores: ReactNode;
  // THIS player's table surface (lib/appearance.ts). data-surface paints it
  // (app/globals.css, "TABLE SURFACES"); data-scheme="dark" turns on the dark
  // palette for the whole table on every surface but Classic.
  surface?: TableSurface;
  // THIS player's card back: every face-down card in the table uses it
  // (app/globals.css, "CARD BACKS").
  back?: CardBack;
}) {
  return (
    <main
      className="table-shell mx-auto w-full max-w-4xl gap-1"
      data-surface={surface}
      data-scheme={surfaceIsDark(surface) ? "dark" : undefined}
      data-back={back}
    >
      <div className="min-w-0">{header}</div>
      <div className="min-w-0">{opponents}</div>
      {/* table-middle: the size container the play area measures itself
          against (app/globals.css), so its cards always fit this region.
          relative: overlays (notices, error toasts) position against it.
          overflow-hidden: nothing in here scrolls. Since stage 3 everything
          the middle can hold -- the play area, the counting stage, the
          result, the cut -- sizes itself from this region's height, so it
          fits rather than relying on a scrollbar. */}
      {sides ? (
        // The side seats around the same middle (.table-midrow in
        // app/globals.css); the middle keeps its class and size container.
        <div className="table-midrow">
          <div className="table-side table-side--left">{sides.left}</div>
          <div className="table-middle relative flex min-h-0 min-w-0 flex-1 flex-col items-center justify-center gap-2 overflow-hidden">
            {middle}
          </div>
          <div className="table-side table-side--right">{sides.right}</div>
        </div>
      ) : (
        <div className="table-middle relative flex min-h-0 min-w-0 flex-col items-center justify-center gap-2 overflow-hidden">
          {middle}
        </div>
      )}
      <div className="min-w-0">{piles}</div>
      <div className="min-w-0">{hand}</div>
      <div className="min-w-0">{scores}</div>
    </main>
  );
}

// The header line: table code, hand number, and whatever controls go on the
// right (reconnecting, Leave). Small text -- it costs ~24px. "Hand N" sits
// directly UNDER "Table CODE", in the header's own 24px (a 14px line over a
// 10px one), so it takes no width from the line and the header grows by
// nothing; the spectators eye stays beside the code on the top line.
// The SAME header for players and spectators (spectator chat): a spectator
// only gets the thin "Watching" row under it (watching).
export function TableHeader({
  code,
  handNo,
  spectators = 0,
  onSpectators,
  watching = false,
  right,
}: {
  code: string;
  handNo: number | null;
  // How many CURRENT spectators are watching (get_table_spectators). Only
  // while it is above 0: an eye with the count beside the code -- on every
  // table, a Muggins one too (2026-11-26: the Muggins tag line is gone; the
  // "Self Scoring" bar at the bottom of the screen says the mode); tapping
  // it calls onSpectators (the list).
  spectators?: number;
  onSpectators?: () => void;
  // A spectator's screen: the "Watching" row under the header.
  watching?: boolean;
  // Ignored since 2026-11-26 (a Muggins table's header is the same as any
  // other's); still accepted so older callers (the dev mocks) compile.
  muggins?: boolean;
  right: ReactNode;
}) {
  const line = (
    <>
      <h1 className="flex min-w-0 flex-col justify-center font-semibold" data-header="title">
        <span className="flex min-w-0 items-center leading-[14px]" data-header="code">
          <span className="truncate">Table {code}</span>
          <SpectatorsEye count={spectators} onOpen={onSpectators} />
        </span>
        {handNo != null && (
          <span className="truncate text-[10px] font-normal leading-[10px] text-zinc-500" data-header="hand">
            Hand {handNo}
          </span>
        )}
      </h1>
      <div className="flex shrink-0 items-center gap-3">{right}</div>
    </>
  );
  return (
    <>
      <header className="flex h-6 items-center justify-between gap-2 text-sm">{line}</header>
      {watching && <WatchingRow />}
    </>
  );
}
