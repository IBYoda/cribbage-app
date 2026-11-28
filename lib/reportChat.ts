// THE CHAT COPY ON A BEHAVIOR REPORT (moderation M7,
// docs/sql/moderation-m7-part1.sql): when someone files a behavior report
// while seated at (or watching) the table, report_player copies that
// table's stored chat into the report -- the newest 2,000 messages, at most
// 204,800 bytes of text, oldest dropped first. Nickname and picture reports
// copy nothing. The app sends nothing more: the copy is the server's.
//
// Admins see each report's chat_status in the list (admin_list_reports)
// and read one report's chat on demand (admin_report_chat, through
// lib/reports.ts readReportChat). Pure rules only (no server, no React);
// tested by scripts/test-phase3.ts.

import type { ReportReason } from "@/lib/reports";

// THE REPORT DIALOG'S LINE, shown only while "Behavior at this table" is
// chosen.
export const REPORT_CHAT_NOTICE = "Your report includes a copy of this table's recent chat, so an admin can read it.";

export function showReportChatNotice(reason: ReportReason | null): boolean {
  return reason === "behavior";
}

// What the server says about a report's chat copy. null: none was tried
// (a nickname or picture report, or a report from before M7).
export type ReportChatStatus = "copied" | "none" | "not_at_table" | "unavailable";

const STATUSES = new Set<string>(["copied", "none", "not_at_table", "unavailable"]);

export function reportChatStatus(v: unknown): ReportChatStatus | null {
  return typeof v === "string" && STATUSES.has(v) ? (v as ReportChatStatus) : null;
}

export const REPORT_CHAT_NONE_TEXT = "No chat was stored for this table.";
export const REPORT_CHAT_NOT_AT_TABLE_TEXT = "No chat copied. The reporter wasn't at this table.";
export const REPORT_CHAT_UNAVAILABLE_TEXT = "Chat wasn't available.";
export const REPORT_CHAT_LOAD_FAILED_TEXT = "Couldn't load the chat. Try again.";
export const REPORT_CHAT_HIDE_LABEL = "Hide chat";
export const REPORT_CHAT_DELETED_NAME = "account deleted";
export const REPORT_CHAT_REPORTED_TAG = "reported";

// The plain line an admin card shows for a status; null for "copied" (the
// card shows the View chat link instead) and for no status (nothing shown).
export function reportChatStatusText(status: ReportChatStatus | null): string | null {
  switch (status) {
    case "none":
      return REPORT_CHAT_NONE_TEXT;
    case "not_at_table":
      return REPORT_CHAT_NOT_AT_TABLE_TEXT;
    case "unavailable":
      return REPORT_CHAT_UNAVAILABLE_TEXT;
    default:
      return null;
  }
}

// The link on a "copied" card.
export function viewChatLabel(total: number): string {
  return `View chat (${total} ${total === 1 ? "message" : "messages"})`;
}

// How many older messages the cap dropped (never below 0).
export function earlierNotKeptCount(total: number, kept: number): number {
  return Math.max(0, total - kept);
}

export function earlierNotKeptText(n: number): string {
  return n === 1 ? "1 earlier message not kept" : `${n} earlier messages not kept`;
}

// A line's time: the viewer's local h:mm AM/PM ("3:04 PM").
export function chatLineTime(atMs: number): string {
  const d = new Date(atMs);
  const h = d.getHours();
  const m = d.getMinutes();
  return `${h % 12 === 0 ? 12 : h % 12}:${m < 10 ? "0" : ""}${m} ${h < 12 ? "AM" : "PM"}`;
}

export type ReportChatLine = { s: string; at: number; text: string };

export type ReportChat = {
  status: ReportChatStatus | null;
  total: number | null;
  kept: number | null;
  // Sender id -> the nickname when the report was filed (null: no account).
  people: Record<string, string | null>;
  // Oldest first, as the server keeps them.
  lines: ReportChatLine[];
};

// A sender's name as shown: the nickname at filing, or "account deleted".
export function chatSenderName(people: Record<string, string | null>, senderId: string): string {
  const name = Object.prototype.hasOwnProperty.call(people, senderId) ? people[senderId] : null;
  return typeof name === "string" && name.trim() !== "" ? name.trim() : REPORT_CHAT_DELETED_NAME;
}

// Whether a line is the reported person's (ids compared without case).
export function isReportedLine(line: { s: string }, reportedId: string | null): boolean {
  return reportedId !== null && line.s.toLowerCase() === reportedId.toLowerCase();
}

// What the card draws, in order: each line's key, time, name, text, and
// whether it is the reported person's. Plain strings; drawn as text nodes.
export function reportChatView(
  chat: ReportChat,
  reportedId: string | null
): { earlierNotKept: number; lines: { key: string; time: string; name: string; text: string; reported: boolean }[] } {
  return {
    earlierNotKept: earlierNotKeptCount(chat.total ?? 0, chat.kept ?? 0),
    lines: chat.lines.map((l, i) => ({
      key: `${i}:${l.at}:${l.s}`,
      time: chatLineTime(l.at),
      name: chatSenderName(chat.people, l.s),
      text: l.text,
      reported: isReportedLine(l, reportedId),
    })),
  };
}

const int = (v: unknown): number | null => (typeof v === "number" && Number.isInteger(v) ? v : null);

// admin_report_chat's answer (one row; none for an unknown report) as a
// ReportChat, or null. Malformed lines are skipped; malformed people are
// left out (their lines then show "account deleted").
export function reportChatFromRows(rows: unknown): ReportChat | null {
  const row = (Array.isArray(rows) ? rows[0] : rows) as Record<string, unknown> | null | undefined;
  if (!row || typeof row !== "object") return null;
  const chat = (row.chat ?? null) as { people?: unknown; lines?: unknown } | null;
  const people: Record<string, string | null> = {};
  if (chat && typeof chat.people === "object" && chat.people !== null && !Array.isArray(chat.people)) {
    for (const [id, name] of Object.entries(chat.people as Record<string, unknown>)) {
      if (typeof name === "string" || name === null) people[id] = name;
    }
  }
  const lines: ReportChatLine[] = [];
  if (chat && Array.isArray(chat.lines)) {
    for (const l of chat.lines as unknown[]) {
      const line = l as Record<string, unknown> | null;
      if (line && typeof line.s === "string" && typeof line.at === "number" && Number.isFinite(line.at) && typeof line.text === "string") {
        lines.push({ s: line.s, at: line.at, text: line.text });
      }
    }
  }
  return { status: reportChatStatus(row.chat_status), total: int(row.chat_total), kept: int(row.chat_kept), people, lines };
}
