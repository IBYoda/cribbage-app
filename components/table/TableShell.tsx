import type { ReactNode } from "react";

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
}: {
  header: ReactNode;
  opponents: ReactNode;
  // The only region that absorbs leftover height. Its own content must fit;
  // anything that appears mid-game (errors, notices) is an overlay inside it.
  middle: ReactNode;
  piles: ReactNode;
  hand: ReactNode;
  scores: ReactNode;
}) {
  return (
    <main className="table-shell mx-auto w-full max-w-4xl gap-1">
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
  right,
}: {
  code: string;
  handNo: number | null;
  right: ReactNode;
}) {
  return (
    <header className="flex h-6 items-center justify-between gap-2 text-sm">
      <h1 className="truncate font-semibold">
        Table {code}
        {handNo != null && (
          <span className="font-normal text-zinc-500"> · Hand {handNo}</span>
        )}
      </h1>
      <div className="flex shrink-0 items-center gap-3">{right}</div>
    </header>
  );
}
