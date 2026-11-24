"use client";

import Link from "next/link";
import { useEffect, useRef } from "react";
import { playHref, watchHref } from "@/lib/spectators";

// PLAY OR WATCH (PRD item 40, join-or-watch): a table that allows spectators
// and still has a free seat before its game asks a newcomer which they want,
// before anyone is seated. Three choices, each a 44px target with 12px
// corners (.join-choice__btn): Play (the seat, as Join always did), Watch
// (the watch page) and Cancel.
//
// Play never asks again: from Home it goes to the table page with ?play=1
// (playHref); on the table page itself it calls onPlay, which remembers the
// choice and goes on to the seat. Either way joinOrWatch then answers "seat".

export function JoinChoice({
  code,
  tableId,
  hostName,
  onPlay,
  onCancel,
  headingId = "join-choice-title",
}: {
  code: string;
  // The table's id: Play and Watch carry it (?t=, step 3 slice B).
  tableId?: string | null;
  hostName?: string | null;
  // The table page's own choice: stay on the page and take the seat.
  // Omitted (Home): Play is a link to the table page with ?play=1.
  onPlay?: () => void;
  onCancel: () => void;
  headingId?: string;
}) {
  return (
    <div className="join-choice">
      <div className="flex flex-col gap-1">
        <h2 id={headingId} className="font-display text-2xl font-bold">
          Play or watch?
        </h2>
        <p className="text-sm">
          {hostName ? `${hostName}'s table ${code}` : `Table ${code}`} has a free seat and allows spectators.
        </p>
      </div>
      <div className="flex flex-col gap-2">
        {onPlay ? (
          <button type="button" onClick={onPlay} className="peg-btn peg-btn--brass join-choice__btn" autoFocus>
            Play
          </button>
        ) : (
          <Link href={playHref(code, tableId)} className="peg-btn peg-btn--brass join-choice__btn" autoFocus>
            Play
          </Link>
        )}
        <Link href={watchHref(code, tableId)} className="peg-btn peg-btn--ghost join-choice__btn">
          Watch
        </Link>
        <button type="button" onClick={onCancel} className="join-choice__cancel">
          Cancel
        </button>
      </div>
    </div>
  );
}

// HOME's choice: the same three, in a bottom sheet (a native <dialog>, the
// About dialog's look). Escape, a click on the backdrop and Cancel all close
// it; nothing is written until Play or Watch.
export function JoinChoiceSheet({
  table,
  onClose,
}: {
  table: { code: string; hostName: string; id?: string } | null;
  onClose: () => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const open = table !== null;

  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) d.showModal();
    if (!open && d.open) d.close();
  }, [open]);

  return (
    <dialog
      ref={ref}
      className="about-dialog join-sheet"
      aria-labelledby="join-sheet-title"
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
      onClose={() => {
        if (open) onClose();
      }}
      onClick={(e) => {
        if (e.target === ref.current) onClose();
      }}
    >
      {table && (
        <JoinChoice code={table.code} tableId={table.id} hostName={table.hostName} onCancel={onClose} headingId="join-sheet-title" />
      )}
    </dialog>
  );
}
