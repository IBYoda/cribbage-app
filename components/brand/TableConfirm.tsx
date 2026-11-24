import Link from "next/link";
import { Avatar } from "@/components/Avatar";
import { confirmView, type JoinPreview } from "@/lib/joinConfirm";
import { watchHref } from "@/lib/spectators";

// THE CONFIRM SCREEN (step 3, slice B): "Join table NNNN hosted by X?" or
// "Watch table NNNN hosted by X?" for someone arriving by a bare code (no
// ?t=). ONE screen: the old Play-or-Watch choice is its Join / Watch
// buttons and the Self-Scoring (Muggins) agreement is its line plus the
// "Join Self-Scoring (Muggins) table" button. What it shows is decided by
// confirmView (lib/joinConfirm.ts). Watch links carry the table's id, so
// the watch page doesn't ask again.
export function TableConfirm({
  preview,
  mode,
  onJoin,
  onWatch,
  busy = false,
}: {
  preview: JoinPreview;
  mode: "join" | "watch";
  // The seat (join mode): the table page takes it by the previewed id.
  onJoin?: () => void;
  // Watch, in watch mode (the watch page watches by the previewed id). In
  // join mode Watch is a link to the watch page with the id.
  onWatch?: () => void;
  busy?: boolean;
}) {
  const view = confirmView(preview, mode);
  return (
    <div className="flex flex-col gap-4" aria-labelledby="table-confirm-title">
      <div className="flex items-center gap-3">
        {view.hostName && <Avatar name={view.hostName} url={preview.hostAvatarUrl} />}
        <h2 id="table-confirm-title" className="font-display text-2xl font-bold">
          {view.title}
        </h2>
      </div>
      <ul className="flex flex-wrap gap-2 text-sm" aria-label="Table options">
        {view.badges.map((b) => (
          <li key={b} className="rounded-full px-3 py-1 ring-1 ring-[var(--brass,#e2c17d)]/60">
            {b}
          </li>
        ))}
      </ul>
      <p className="text-sm">{view.seatsLine}</p>
      {view.notice && <p className="text-sm">{view.notice}</p>}
      {view.mugginsLine && <p className="text-sm">{view.mugginsLine}</p>}
      <div className="flex flex-col gap-2.5">
        {view.join && onJoin && (
          <button type="button" onClick={onJoin} disabled={busy} className="peg-btn peg-btn--brass disabled:opacity-60">
            {busy ? "Joining..." : view.join.label}
          </button>
        )}
        {view.watch &&
          (mode === "watch" && onWatch ? (
            <button type="button" onClick={onWatch} disabled={busy} className="peg-btn peg-btn--brass disabled:opacity-60">
              {busy ? "Opening..." : "Watch"}
            </button>
          ) : (
            <Link
              href={watchHref(preview.code, preview.tableId)}
              className={view.join ? "peg-btn peg-btn--ghost" : "peg-btn peg-btn--brass"}
            >
              Watch
            </Link>
          ))}
        <Link href="/" className="peg-btn peg-btn--ghost">
          Back to home
        </Link>
      </div>
    </div>
  );
}
