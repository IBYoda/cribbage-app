"use client";

import { useEffect, useId, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  REPORT_CHOOSE_TEXT,
  REPORT_NOTE_MAX,
  REPORT_NOTE_PLACEHOLDER,
  REPORT_QUESTION,
  REPORT_REASONS,
  REPORT_SEND_LABEL,
  REPORT_SENDING_LABEL,
  reportTitle,
  showNoteCounter,
  type ReportReason,
} from "@/lib/reports";
import { REPORT_CHAT_NOTICE, showReportChatNotice } from "@/lib/reportChat";

// THE REPORT DIALOG (moderation M6): "Report <name>", "What's the
// problem?", three choices, an optional note (200 characters, a counter
// near the limit), "Send report" (the one gold-filled button) and "Cancel"
// (the spectator list's text link). AskDialog's look: a native <dialog>
// opened with showModal() in a portal, so it sits in the top layer above
// the eye list and the chat.
//
// No choice yet: Send report still works and says "Choose what's wrong."
// (the dialog stays). While sending: "Sending...", and a second tap does
// nothing. Cancel, Escape and a tap outside send nothing. What the server
// answered comes back from onSend: null closes (the parent opens the next
// step), a line stays in the dialog with the form as it was. Nothing here
// calls the server: onSend is TableView's (lib/reports.ts writeReport).
//
// The form is mounted only while open (keyed by person), so every open
// starts empty.
//
// Moderation M7: while "Behavior at this table" is chosen, one small line
// between the choices and the note says the report includes a copy of the
// table's recent chat (the server takes it; nothing more is sent).
export function ReportDialog({
  target,
  onSend,
  onClose,
}: {
  // null: closed.
  target: { userId: string; name: string } | null;
  // Resolves to a line to show (the dialog stays open), or null when done.
  onSend: (reason: ReportReason, note: string) => Promise<string | null>;
  onClose: () => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const open = target !== null;
  const openRef = useRef(open);

  useEffect(() => {
    openRef.current = open;
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) d.showModal();
    if (!open && d.open) d.close();
  }, [open]);

  if (typeof document === "undefined") return null;
  return createPortal(
    <dialog
      ref={ref}
      className="about-dialog report-dialog"
      aria-label={target ? reportTitle(target.name) : undefined}
      data-report-dialog=""
      onCancel={(e) => {
        // Escape: Cancel.
        e.preventDefault();
        onClose();
      }}
      onClose={() => {
        if (openRef.current) onClose();
      }}
      onClick={(e) => {
        // A tap on the backdrop lands on the <dialog> itself.
        if (e.target === ref.current) onClose();
      }}
    >
      {target && <ReportForm key={target.userId} name={target.name} onSend={onSend} onClose={onClose} />}
    </dialog>,
    document.body
  );
}

function ReportForm({
  name,
  onSend,
  onClose,
}: {
  name: string;
  onSend: (reason: ReportReason, note: string) => Promise<string | null>;
  onClose: () => void;
}) {
  const id = useId();
  const [reason, setReason] = useState<ReportReason | null>(null);
  const [note, setNote] = useState("");
  const [message, setMessage] = useState<string | null>(null);
  const [sending, setSending] = useState(false);
  const sendingRef = useRef(false);

  async function send() {
    if (sendingRef.current) return;
    if (!reason) {
      setMessage(REPORT_CHOOSE_TEXT);
      return;
    }
    sendingRef.current = true;
    setSending(true);
    setMessage(null);
    const line = await onSend(reason, note);
    sendingRef.current = false;
    setSending(false);
    if (line) setMessage(line);
  }

  return (
    <form
      className="flex flex-col gap-3"
      onSubmit={(e) => {
        e.preventDefault();
        void send();
      }}
    >
      <h2 className="font-display text-2xl font-bold italic break-words">{reportTitle(name)}</h2>
      <fieldset className="flex flex-col gap-1">
        <legend className="mb-1">{REPORT_QUESTION}</legend>
        {REPORT_REASONS.map((r) => (
          <label key={r.reason} className="report-choice">
            <input
              type="radio"
              name={`${id}-reason`}
              value={r.reason}
              checked={reason === r.reason}
              onChange={() => {
                setReason(r.reason);
                if (message === REPORT_CHOOSE_TEXT) setMessage(null);
              }}
            />
            <span>{r.label}</span>
          </label>
        ))}
      </fieldset>
      {/* (M7) only for a behavior report: the server copies the table's chat. */}
      {showReportChatNotice(reason) && <p className="text-sm opacity-80">{REPORT_CHAT_NOTICE}</p>}
      <div className="flex flex-col gap-1">
        <textarea
          className="report-note"
          aria-label="Details (optional)"
          placeholder={REPORT_NOTE_PLACEHOLDER}
          maxLength={REPORT_NOTE_MAX}
          rows={3}
          value={note}
          onChange={(e) => setNote(e.target.value)}
        />
        {showNoteCounter(note.length) && (
          <p className="self-end text-xs opacity-80" aria-live="polite">
            {note.length}/{REPORT_NOTE_MAX}
          </p>
        )}
      </div>
      {message && (
        <p role="alert" className="text-sm font-semibold text-[var(--error-on-felt)]">
          {message}
        </p>
      )}
      <div className="mt-1 flex flex-col gap-2">
        <button type="submit" className="peg-btn peg-btn--brass" aria-disabled={sending}>
          {sending ? REPORT_SENDING_LABEL : REPORT_SEND_LABEL}
        </button>
        <button type="button" onClick={onClose} className="join-choice__cancel">
          Cancel
        </button>
      </div>
    </form>
  );
}
