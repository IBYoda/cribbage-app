import type { ReactNode } from "react";
import { MugginsTag } from "@/components/MugginsTag";
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
  surface = DEFAULT_TABLE_SURFACE,
  back = DEFAULT_CARD_BACK,
}: {
  header: ReactNode;
  opponents: ReactNode;
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
      <div className="table-middle relative flex min-h-0 min-w-0 flex-col items-center justify-center gap-2 overflow-hidden">
        {middle}
      </div>
      <div className="min-w-0">{piles}</div>
      <div className="min-w-0">{hand}</div>
      <div className="min-w-0">{scores}</div>
    </main>
  );
}

// The header line: table code, hand number, and whatever controls go on the
// right (reconnecting, Leave). One line, small text -- it costs ~24px.
export function TableHeader({
  code,
  handNo,
  muggins = false,
  right,
}: {
  code: string;
  handNo: number | null;
  // A Muggins table: the "Muggins · no scoring" tag under the header line.
  muggins?: boolean;
  right: ReactNode;
}) {
  const line = (
    <>
      <h1 className="truncate font-semibold">
        Table {code}
        {handNo != null && (
          <span className="font-normal text-zinc-500"> · Hand {handNo}</span>
        )}
      </h1>
      <div className="flex shrink-0 items-center gap-3">{right}</div>
    </>
  );
  if (!muggins) {
    return <header className="flex h-6 items-center justify-between gap-2 text-sm">{line}</header>;
  }
  // A Muggins table: the tag gets a short line of its own under the header
  // line -- there is no room beside the code and the header buttons on a
  // phone. It costs ~20px, well inside the score strip's height, which a
  // Muggins table doesn't have.
  return (
    <header className="flex flex-col gap-0.5 text-sm">
      <div className="flex h-6 items-center justify-between gap-2">{line}</div>
      <div className="flex">
        <MugginsTag />
      </div>
    </header>
  );
}
