"use client";

import { useEffect, useRef } from "react";
import { createPortal } from "react-dom";

// A YES/NO QUESTION (moderation M2c): one native <dialog> opened with
// showModal(), styled like About -- real buttons, not window.confirm. The
// first use is "Also block <name>?" after a Mute; the Kick slice (M3) reuses
// it for "<name> was kicked from the table. Would you like to add them to
// your Block list?".
//
// It sits in the browser's TOP LAYER, opened after anything already there,
// so it shows above everything: the chat cards (z 55), the person menu
// (z 66), the composer (z 70) and the spectator list's own dialog (a later
// showModal stacks on top of an earlier one, and only the top one takes
// taps). Drawn in a portal to <body>, so no ancestor can hide it.
//
// Controlled: the parent says when it is open. Only the yes button calls
// onYes. The no button, Escape, a tap on the backdrop, and a close the
// parent didn't ask for all call onNo. Focus starts on the no button, so
// Enter never says yes by accident.
export function AskDialog({
  open,
  title,
  body,
  yesLabel,
  noLabel,
  onYes,
  onNo,
}: {
  open: boolean;
  title: string;
  body: string;
  yesLabel: string;
  noLabel: string;
  onYes: () => void;
  onNo: () => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const noRef = useRef<HTMLButtonElement>(null);
  // The latest `open`, for the close event: a close the parent asked for is
  // not a no.
  const openRef = useRef(open);

  useEffect(() => {
    openRef.current = open;
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) {
      d.showModal();
      // showModal focuses the first button; start on the no button instead.
      noRef.current?.focus();
    }
    if (!open && d.open) d.close();
  }, [open]);

  if (typeof document === "undefined") return null;
  return createPortal(
    <dialog
      ref={ref}
      className="about-dialog"
      aria-labelledby="ask-dialog-title"
      aria-describedby="ask-dialog-body"
      data-ask-dialog=""
      onCancel={(e) => {
        // Escape: no.
        e.preventDefault();
        onNo();
      }}
      onClose={() => {
        if (openRef.current) onNo();
      }}
      onClick={(e) => {
        // A tap on the backdrop lands on the <dialog> itself.
        if (e.target === ref.current) onNo();
      }}
    >
      {open && (
        <div className="flex flex-col gap-3">
          <h2 id="ask-dialog-title" className="font-display text-2xl font-bold italic">
            {title}
          </h2>
          <p id="ask-dialog-body">{body}</p>
          <div className="mt-2 flex flex-col gap-2">
            <button type="button" onClick={onYes} className="peg-btn peg-btn--brass">
              {yesLabel}
            </button>
            <button ref={noRef} type="button" onClick={onNo} className="peg-btn peg-btn--ghost">
              {noLabel}
            </button>
          </div>
        </div>
      )}
    </dialog>,
    document.body
  );
}
