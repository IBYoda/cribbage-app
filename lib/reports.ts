// REPORTS (moderation M6, docs/sql/moderation-m6-part1.sql): anyone at a
// human table may report another person -- an offensive nickname, an
// offensive picture, or behavior at the table -- with an optional note of
// up to 200 characters. The server (report_player) takes its own snapshot
// (both nicknames, the avatar address and the file's date and size), so the
// app sends only who, why, the note and this table's id. The reported
// person may have left already (a chat card's "..." still opens the popup).
//
// NOTHING HAPPENS to the reported person and nothing is broadcast: admins
// read the list (admin_list_reports) and may delete a report
// (admin_delete_report). Reports are deleted automatically after 90 days.
// The limits (10 an hour, 30 a day, one per person a day) are the server's;
// the app only shows its answers.
//
// MODERATION M7 (docs/sql/moderation-m7-part1.sql): a behavior report also
// carries a copy of the table's stored chat, taken by the server
// (report_player's arguments and answers are unchanged). Admins read one
// report's copy with readReportChat; the chat rules are lib/reportChat.ts.
//
// Pure rules plus the four RPC calls (writeReport, readReports,
// deleteReport, readReportChat). No component calls the server for reports
// itself, and nothing reads the player_reports table directly (no client
// can). Tested by scripts/test-phase3.ts.

import { blockQuestion } from "@/lib/personMenu";
import {
  REPORT_CHAT_LOAD_FAILED_TEXT,
  reportChatFromRows,
  reportChatStatus,
  type ReportChat,
  type ReportChatStatus,
} from "@/lib/reportChat";

export type ReportReason = "nickname" | "picture" | "behavior";

// The dialog's three choices, in order.
export const REPORT_REASONS: readonly { reason: ReportReason; label: string }[] = [
  { reason: "nickname", label: "Offensive nickname" },
  { reason: "picture", label: "Offensive picture" },
  { reason: "behavior", label: "Behavior at this table" },
];

// The admin list's words for a reason.
export function reportReasonWords(reason: string): string {
  return reason === "nickname" ? "Offensive nickname" : reason === "picture" ? "Offensive picture" : "Behavior";
}

export const REPORT_NOTE_MAX = 200;
// The counter shows from here on.
export const REPORT_NOTE_COUNTER_FROM = 150;
export const REPORT_QUESTION = "What's the problem?";
export const REPORT_NOTE_PLACEHOLDER = "Add details (optional, 200 characters)";
export const REPORT_CHOOSE_TEXT = "Choose what's wrong.";
export const REPORT_SEND_LABEL = "Send report";
export const REPORT_SENDING_LABEL = "Sending...";
export const REPORT_FAILED_TEXT = "Couldn't send your report. Try again.";
export const REPORT_LIMIT_TEXT = "You've sent a lot of reports. Try again a little later.";
export const REPORT_NOT_FOUND_TEXT = "That player isn't there anymore.";
export const REPORT_NOT_ALLOWED_TEXT = "You can't report this player.";
export const REPORT_SENT_TITLE = "Report sent";
export const REPORT_SENT_LINE = "We'll take a look.";

export function reportTitle(name: string): string {
  return `Report ${name}`;
}

export function reportAlreadyText(name: string): string {
  return `You already reported ${name} today.`;
}

// The note as sent: trimmed, at most 200 characters, null when empty. (The
// server cleans it again: control characters, spaces, the cap.)
export function reportNote(note: string): string | null {
  const t = note.trim().slice(0, REPORT_NOTE_MAX).trim();
  return t === "" ? null : t;
}

// Whether to show the counter under the note.
export function showNoteCounter(length: number): boolean {
  return length >= REPORT_NOTE_COUNTER_FROM;
}

// What report_player answered, plus "error" (anything that went wrong).
export type ReportOutcome = "reported" | "already_reported" | "limit" | "not_found" | "not_allowed";

export type ReportResult = { ok: true; outcome: ReportOutcome } | { ok: false; text: string };

// The line the dialog shows for an answer that isn't "reported" (null for
// "reported": the dialog closes and the next step opens).
export function reportOutcomeText(outcome: ReportOutcome, name: string): string | null {
  switch (outcome) {
    case "reported":
      return null;
    case "already_reported":
      return reportAlreadyText(name);
    case "limit":
      return REPORT_LIMIT_TEXT;
    case "not_found":
      return REPORT_NOT_FOUND_TEXT;
    case "not_allowed":
      return REPORT_NOT_ALLOWED_TEXT;
  }
}

// AFTER "reported": "Report sent" with the block question when I haven't
// blocked them; a plain "Report sent. We'll take a look." when I have.
export function afterReportStep(state: { blocked: boolean }): "ask_block" | "sent_notice" {
  return state.blocked ? "sent_notice" : "ask_block";
}

// The block question after a report: the Mute/Kick question's buttons and
// Block List explanation, titled "Report sent", first line "We'll take a
// look." (Paragraphs are separated by a blank line; AskDialog keeps them.)
export function reportedBlockQuestion(name: string): { title: string; body: string; yesLabel: string; noLabel: string } {
  const q = blockQuestion(name);
  return {
    title: REPORT_SENT_TITLE,
    body: `${REPORT_SENT_LINE}\n\n${q.title}\n\n${q.body}`,
    yesLabel: q.yesLabel,
    noLabel: q.noLabel,
  };
}

// The confirmation when I already block them: one button.
export function reportSentNotice(): { title: string; body: string; yesLabel: string; noLabel: string } {
  return { title: REPORT_SENT_TITLE, body: REPORT_SENT_LINE, yesLabel: "", noLabel: "OK" };
}

// The server's plain refusals (report_player raises these two); anything
// else is the generic line, never raw database text.
const REPORT_SERVER_TEXTS = new Set(["You must be logged in to report a player.", "Unknown report reason."]);

export function reportFailureText(error: { message?: string | null } | null | undefined): string {
  const message = error?.message ?? "";
  return REPORT_SERVER_TEXTS.has(message) ? message : REPORT_FAILED_TEXT;
}

const OUTCOMES = new Set<ReportOutcome>(["reported", "already_reported", "limit", "not_found", "not_allowed"]);

// THE REPORT: report_player(target, reason, note, table). The only place the
// app files a report.
export async function writeReport(input: {
  targetId: string;
  reason: ReportReason;
  note: string;
  tableId: string | null;
}): Promise<ReportResult> {
  try {
    const { supabase } = await import("@/lib/supabase");
    const { data, error } = await supabase.rpc("report_player", {
      p_target: input.targetId,
      p_reason: input.reason,
      p_note: reportNote(input.note),
      p_table_id: input.tableId,
    });
    if (error) return { ok: false, text: reportFailureText(error) };
    if (typeof data === "string" && OUTCOMES.has(data as ReportOutcome)) return { ok: true, outcome: data as ReportOutcome };
    return { ok: false, text: REPORT_FAILED_TEXT };
  } catch {
    return { ok: false, text: REPORT_FAILED_TEXT };
  }
}

// THE ADMIN PAGE'S REPORTS (admin_list_reports: admins only; anyone else is
// refused "Admins only."). Newest first.
export const REPORTS_AUTO_DELETE_TEXT = "Reports are deleted automatically after 90 days.";
export const REPORTS_EMPTY_TEXT = "No reports.";
export const REPORTS_LOAD_FAILED_TEXT = "Couldn't load the reports.";
export const REPORT_DELETE_FAILED_TEXT = "Couldn't delete the report.";
export const REPORT_DELETE_QUESTION = { title: "Delete this report?", body: "", yesLabel: "Delete", noLabel: "Cancel" };

export type AdminReport = {
  id: string;
  createdAt: string;
  reason: string;
  note: string | null;
  tableCode: string | null;
  reporterNickname: string | null;
  reporterNicknameNow: string | null;
  // (M7) whose chat lines the card highlights.
  reportedId: string | null;
  reportedNickname: string | null;
  reportedNicknameNow: string | null;
  reportedAvatarUrl: string | null;
  pictureChanged: boolean;
  reporterReportCount: number;
  reportedReportCount: number;
  // (M7) the chat copy's status and how many messages were stored; null for
  // nickname and picture reports and reports from before M7.
  chatStatus: ReportChatStatus | null;
  chatTotal: number | null;
};

const str = (v: unknown): string | null => (typeof v === "string" ? v : null);
const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : 0);

export function adminReportsFromRows(rows: unknown): AdminReport[] {
  if (!Array.isArray(rows)) return [];
  return rows.flatMap((r) => {
    const row = r as Record<string, unknown> | null;
    if (!row || typeof row.id !== "string" || typeof row.created_at !== "string") return [];
    return [
      {
        id: row.id,
        createdAt: row.created_at,
        reason: str(row.reason) ?? "",
        note: str(row.note),
        tableCode: str(row.table_code),
        reporterNickname: str(row.reporter_nickname),
        reporterNicknameNow: str(row.reporter_nickname_now),
        reportedId: str(row.reported_id),
        reportedNickname: str(row.reported_nickname),
        reportedNicknameNow: str(row.reported_nickname_now),
        reportedAvatarUrl: str(row.reported_avatar_url),
        pictureChanged: row.picture_changed === true,
        reporterReportCount: num(row.reporter_report_count),
        reportedReportCount: num(row.reported_report_count),
        chatStatus: reportChatStatus(row.chat_status),
        chatTotal: typeof row.chat_total === "number" && Number.isInteger(row.chat_total) ? row.chat_total : null,
      },
    ];
  });
}

// A nickname as shown: the snapshot, plus "now: <current>" when it differs
// (a deleted account has no current nickname).
export function nicknameThenNow(snapshot: string | null, now: string | null): { name: string; now: string | null } {
  const name = snapshot?.trim() || "Unnamed player";
  const current = now?.trim() || "";
  if (now === null) return { name, now: null };
  return { name, now: current && current !== name ? current : null };
}

// The note on one line (line breaks and runs of spaces collapsed); drawn as
// a text node, never HTML.
export function noteOneLine(note: string | null): string {
  return (note ?? "").replace(/\s+/g, " ").trim();
}

export function countLine(n: number, what: "filed" | "against"): string {
  const reports = n === 1 ? "report" : "reports";
  return what === "filed" ? `${n} ${reports} filed by this person` : `${n} ${reports} against this person`;
}

export async function readReports(limit = 100): Promise<{ ok: true; data: AdminReport[] } | { ok: false; text: string }> {
  try {
    const { supabase } = await import("@/lib/supabase");
    const { data, error } = await supabase.rpc("admin_list_reports", { p_limit: limit });
    if (error) return { ok: false, text: error.message === "Admins only." ? error.message : REPORTS_LOAD_FAILED_TEXT };
    return { ok: true, data: adminReportsFromRows(data) };
  } catch {
    return { ok: false, text: REPORTS_LOAD_FAILED_TEXT };
  }
}

// Delete one report. not_found means it is already gone: the row goes too.
export async function deleteReport(id: string): Promise<{ ok: true } | { ok: false; text: string }> {
  try {
    const { supabase } = await import("@/lib/supabase");
    const { data, error } = await supabase.rpc("admin_delete_report", { p_id: id });
    if (error) return { ok: false, text: error.message === "Admins only." ? error.message : REPORT_DELETE_FAILED_TEXT };
    if (data === "deleted" || data === "not_found") return { ok: true };
    return { ok: false, text: REPORT_DELETE_FAILED_TEXT };
  } catch {
    return { ok: false, text: REPORT_DELETE_FAILED_TEXT };
  }
}

// (M7) One report's chat copy (admin_report_chat: admins only; one row, none
// for a report that is gone). Any failure is the plain "Couldn't load the
// chat. Try again." -- never raw database text ("Admins only." aside).
export type ReportChatResult = { ok: true; chat: ReportChat } | { ok: false; text: string };

export async function readReportChat(id: string): Promise<ReportChatResult> {
  try {
    const { supabase } = await import("@/lib/supabase");
    const { data, error } = await supabase.rpc("admin_report_chat", { p_id: id });
    if (error) return { ok: false, text: error.message === "Admins only." ? error.message : REPORT_CHAT_LOAD_FAILED_TEXT };
    const chat = reportChatFromRows(data);
    if (!chat) return { ok: false, text: REPORT_CHAT_LOAD_FAILED_TEXT };
    return { ok: true, chat };
  } catch {
    return { ok: false, text: REPORT_CHAT_LOAD_FAILED_TEXT };
  }
}
