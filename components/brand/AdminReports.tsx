"use client";

import { useEffect, useState } from "react";
import { AskDialog } from "@/components/brand/AskDialog";
import {
  REPORT_DELETE_QUESTION,
  REPORTS_AUTO_DELETE_TEXT,
  REPORTS_EMPTY_TEXT,
  countLine,
  deleteReport,
  nicknameThenNow,
  noteOneLine,
  readReports,
  reportReasonWords,
  type AdminReport,
} from "@/lib/reports";

// THE ADMIN PAGE'S REPORTS (moderation M6): the newest 100 reports from
// admin_list_reports (admins only; the server refuses anyone else), read
// once when the page opens. Each row: when, the reason in plain words, the
// reported person (the nickname at the time, and "now: <current>" when it
// changed) with a small thumbnail of the picture's address at the time and
// "picture changed since report" when the server says so, the reporter
// (and how many reports they have filed), how many reports exist against
// the reported person, the note as PLAIN TEXT on one line (a React text
// node, never HTML), and the table's code. Delete asks "Delete this
// report?" first; a report already gone (not_found) leaves the list too.
export function AdminReports() {
  const [reports, setReports] = useState<AdminReport[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [deleteAsk, setDeleteAsk] = useState<string | null>(null);
  const [deleteError, setDeleteError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    readReports(100).then((read) => {
      if (cancelled) return;
      if (read.ok) setReports(read.data);
      else setError(read.text);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  async function confirmDelete() {
    const id = deleteAsk;
    setDeleteAsk(null);
    if (!id) return;
    setDeleteError(null);
    const result = await deleteReport(id);
    if (!result.ok) {
      setDeleteError(result.text);
      return;
    }
    setReports((list) => (list ? list.filter((r) => r.id !== id) : list));
  }

  return (
    <section className="flex w-full flex-col gap-2" aria-labelledby="admin-reports">
      <h2 id="admin-reports" className="font-display text-xl font-bold">
        Reports
      </h2>
      <p className="text-sm opacity-80">{REPORTS_AUTO_DELETE_TEXT}</p>
      {deleteError && <p className="text-sm text-[var(--error-on-felt)]">{deleteError}</p>}
      {error ? (
        <p className="text-sm text-[var(--error-on-felt)]">{error}</p>
      ) : reports === null ? (
        <p className="text-sm">Loading...</p>
      ) : reports.length === 0 ? (
        <p className="text-sm">{REPORTS_EMPTY_TEXT}</p>
      ) : (
        <ul className="flex flex-col gap-3 text-sm" data-admin-reports="">
          {reports.map((r) => (
            <AdminReportRow key={r.id} report={r} onDelete={() => setDeleteAsk(r.id)} />
          ))}
        </ul>
      )}
      <AskDialog
        open={deleteAsk !== null}
        title={REPORT_DELETE_QUESTION.title}
        body={REPORT_DELETE_QUESTION.body}
        yesLabel={REPORT_DELETE_QUESTION.yesLabel}
        noLabel={REPORT_DELETE_QUESTION.noLabel}
        onYes={() => void confirmDelete()}
        onNo={() => setDeleteAsk(null)}
      />
    </section>
  );
}

function AdminReportRow({ report: r, onDelete }: { report: AdminReport; onDelete: () => void }) {
  const reported = nicknameThenNow(r.reportedNickname, r.reportedNicknameNow);
  const reporter = nicknameThenNow(r.reporterNickname, r.reporterNicknameNow);
  const note = noteOneLine(r.note);
  return (
    <li className="flex gap-3 rounded-xl border border-[var(--brass)] p-3">
      {r.reportedAvatarUrl ? (
        // The address saved with the report; the file itself is the current
        // one (an upload overwrites it), hence the flag below.
        // eslint-disable-next-line @next/next/no-img-element
        <img src={r.reportedAvatarUrl} alt="" className="h-10 w-10 shrink-0 rounded-full object-cover" />
      ) : (
        <span className="h-10 w-10 shrink-0 rounded-full bg-black/30" aria-hidden="true" />
      )}
      <div className="flex min-w-0 flex-1 flex-col gap-0.5">
        <p>
          <time dateTime={r.createdAt} className="opacity-75">
            {new Date(r.createdAt).toLocaleString()}
          </time>{" "}
          <span className="font-semibold">{reportReasonWords(r.reason)}</span>
          {r.tableCode ? <span className="opacity-75"> &middot; Table {r.tableCode}</span> : null}
        </p>
        <p className="break-words">
          Reported: <span className="font-semibold">{reported.name}</span>
          {reported.now ? <span className="opacity-75"> (now: {reported.now})</span> : null}
          {r.pictureChanged ? <span className="font-semibold"> &middot; picture changed since report</span> : null}
        </p>
        <p className="opacity-90">{countLine(r.reportedReportCount, "against")}</p>
        <p className="break-words">
          By: {reporter.name}
          {reporter.now ? <span className="opacity-75"> (now: {reporter.now})</span> : null}
          <span className="opacity-75"> &middot; {countLine(r.reporterReportCount, "filed")}</span>
        </p>
        {note && <p className="break-words italic">&ldquo;{note}&rdquo;</p>}
      </div>
      <button type="button" onClick={onDelete} className="person-btn self-start" aria-label={`Delete report about ${reported.name}`}>
        Delete
      </button>
    </li>
  );
}
