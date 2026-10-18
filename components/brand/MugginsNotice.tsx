"use client";

import { useEffect, useRef } from "react";

// THE MUGGINS NOTICE: one native <dialog> (styled like About), shown before
// anyone takes a seat at a Muggins table -- to the creator on Start a Table
// (mode "create") and to a joiner on the table page (mode "join"). The same
// text for both; only the confirm button differs.
//
// Controlled: the parent says when it is open. Go back, Escape and a click
// on the backdrop all call onCancel; only the confirm button calls
// onConfirm. Focus starts on Go back, so Enter never confirms by accident.
export function MugginsNotice({
  open,
  mode,
  onConfirm,
  onCancel,
}: {
  open: boolean;
  mode: "create" | "join";
  onConfirm: () => void;
  onCancel: () => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  // The latest `open`, for the close event: a close the parent asked for is
  // not a cancel.
  const openRef = useRef(open);

  useEffect(() => {
    openRef.current = open;
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) d.showModal();
    if (!open && d.open) d.close();
  }, [open]);

  return (
    <dialog
      ref={ref}
      className="about-dialog"
      aria-labelledby="muggins-title"
      aria-describedby="muggins-body"
      onCancel={(e) => {
        // Escape: Go back.
        e.preventDefault();
        onCancel();
      }}
      onClose={() => {
        // Closed by the browser without the parent asking (e.g. a second
        // Escape): still a Go back.
        if (openRef.current) onCancel();
      }}
      onClick={(e) => {
        // A click on the backdrop lands on the <dialog> itself.
        if (e.target === ref.current) onCancel();
      }}
    >
      <div className="flex flex-col gap-3">
        <h2 id="muggins-title" className="font-display text-2xl font-bold italic">
          Muggins mode
        </h2>
        <p id="muggins-body">
          All scoring is turned off. The app only deals the cards, so you will NEED to keep your own
          score, on a physical board or a tracker of your choice.
        </p>
        <p>
          To end a match, tap &quot;I win&quot; when you&apos;ve won. The other player then taps
          &quot;Confirm loss&quot; and the match is over. Made a mistake or changed your mind? Tap
          &quot;I win&quot; again to take it back.
        </p>
        <p>
          Muggins matches don&apos;t count toward rankings. The app never sees the score, so there is
          no way to check a win.
        </p>
        <p>
          Be honest with that button, and don&apos;t leave before you&apos;ve confirmed a loss.
          Don&apos;t be a bitch.
        </p>
        <div className="mt-2 flex flex-col gap-2">
          <button type="button" onClick={onCancel} className="peg-btn peg-btn--ghost" autoFocus>
            Go back
          </button>
          <button type="button" onClick={onConfirm} className="peg-btn peg-btn--brass">
            {mode === "create" ? "Start Muggins table" : "Join Muggins table"}
          </button>
        </div>
      </div>
    </dialog>
  );
}
