"use client";

import { useRef } from "react";

// "About", as a native <dialog> modal: Escape and the Close button shut it,
// focus moves in and back on its own, and a click on the dimmed backdrop
// closes it too. Rendered as the footer's "About" link plus the dialog.
export function AboutDialog() {
  const dialogRef = useRef<HTMLDialogElement>(null);

  return (
    <>
      <button
        type="button"
        onClick={() => dialogRef.current?.showModal()}
        className="footer-link"
      >
        About
      </button>
      <dialog
        ref={dialogRef}
        className="about-dialog"
        aria-labelledby="about-title"
        onClick={(e) => {
          // A click on the backdrop lands on the <dialog> itself.
          if (e.target === dialogRef.current) dialogRef.current.close();
        }}
      >
        <div className="flex flex-col gap-3">
          <h2 id="about-title" className="font-display text-2xl font-bold italic">
            About Nobs!
          </h2>
          <p>
            Nobs! was born on a Zoom call, when it became clear that four people with four separate
            decks were, statistically, playing four different games.
          </p>
          <p>
            So: one shared deck, and everyone&apos;s hand stays private. The app counts the pegging,
            so nobody can argue about it. Counting your own hand is still on you. Muggins lives.
          </p>
          <p>Bring your own board, your own drink and your own excuses.</p>
          <button
            type="button"
            onClick={() => dialogRef.current?.close()}
            className="peg-btn peg-btn--brass mt-2"
            autoFocus
          >
            Close
          </button>
        </div>
      </dialog>
    </>
  );
}
