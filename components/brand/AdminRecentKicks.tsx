"use client";

import { useEffect, useState } from "react";
import { readRecentKicks, recentKickLine, type RecentKick } from "@/lib/kicks";

// THE ADMIN PAGE'S RECENT KICKS (moderation M3): the newest 50 kicks from
// admin_recent_kicks (admins only; the server refuses anyone else), each
// with its time, the table's code, who kicked whom, and whether it ended a
// live game. Read once when the page opens.
export function AdminRecentKicks() {
  const [kicks, setKicks] = useState<RecentKick[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    readRecentKicks(50).then((read) => {
      if (cancelled) return;
      if (read.ok) setKicks(read.data);
      else setError(read.text);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  return (
    <section className="flex w-full flex-col gap-2" aria-labelledby="admin-recent-kicks">
      <h2 id="admin-recent-kicks" className="font-display text-xl font-bold">
        Recent kicks
      </h2>
      {error ? (
        <p className="text-sm text-[var(--error-on-felt)]">{error}</p>
      ) : kicks === null ? (
        <p className="text-sm">Loading...</p>
      ) : kicks.length === 0 ? (
        <p className="text-sm">No kicks yet.</p>
      ) : (
        <ul className="flex flex-col gap-1 text-sm" data-admin-kicks="">
          {kicks.map((k) => (
            <li key={`${k.tableId}:${k.kickedAt}:${k.kickedNickname ?? ""}`}>
              <time dateTime={k.kickedAt} className="opacity-75">
                {new Date(k.kickedAt).toLocaleString()}
              </time>{" "}
              {recentKickLine(k)}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
