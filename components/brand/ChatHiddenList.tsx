"use client";

import { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { parseHidden, rawHidden, subscribeHidden, unhideSender } from "@/lib/chatHide";

export const CHAT_HIDDEN_EMPTY_TEXT = "You haven't hidden anyone in chat.";

// HIDDEN IN CHAT (moderation M2), on the Settings page under the look and
// sound: the people whose chat messages this player hid on THIS browser
// (lib/chatHide.ts), newest first, each with Unhide. Names are each person's
// current nickname from profiles when it can be read, else the name they had
// when hidden. Blocked players are not here: they live on the Profile page's
// Block List (Unblock brings their chat back).
export function ChatHiddenList({ userId }: { userId: string }) {
  // The stored list, kept in step with this tab and others.
  const raw = useSyncExternalStore(
    useCallback((onChange: () => void) => subscribeHidden(userId, onChange), [userId]),
    () => rawHidden(userId),
    () => ""
  );
  const list = useMemo(() => parseHidden(raw), [raw]);
  const [names, setNames] = useState<Map<string, string>>(new Map());

  // Current nicknames, for display only (profiles is readable when signed in).
  const idsKey = list.map((p) => p.userId).join(",");
  useEffect(() => {
    if (!idsKey) return;
    let cancelled = false;
    (async () => {
      try {
        const { supabase } = await import("@/lib/supabase");
        const { data, error } = await supabase.from("profiles").select("id, nickname").in("id", idsKey.split(","));
        if (cancelled || error || !Array.isArray(data)) return;
        setNames(new Map(data.map((p) => [p.id as string, ((p.nickname as string | null) ?? "").trim()])));
      } catch {
        // Keep the names stored when they were hidden.
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [idsKey]);

  return (
    <section className="felt-panel flex w-full flex-col gap-3" aria-labelledby="hidden-in-chat">
      <h2 id="hidden-in-chat" className="font-display text-2xl font-bold italic">
        Hidden in chat
      </h2>
      <p className="text-sm">
        Their chat messages don&apos;t show for you on this device. They can still play and watch as usual.
      </p>
      {list.length === 0 ? (
        <p className="text-sm">{CHAT_HIDDEN_EMPTY_TEXT}</p>
      ) : (
        <ul className="flex flex-col gap-2" aria-label="People hidden in chat">
          {list.map((person) => {
            const name = names.get(person.userId) || person.name.trim() || "Unnamed player";
            return (
              <li key={person.userId} className="leaderboard-card">
                <div className="flex min-w-0 items-center gap-3">
                  <span className="block min-w-0 flex-1 truncate font-bold">{name}</span>
                  <button
                    type="button"
                    onClick={() => unhideSender(userId, person.userId)}
                    className="peg-btn peg-btn--brass peg-btn--small shrink-0"
                    aria-label={`Unhide ${name}`}
                  >
                    Unhide
                  </button>
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
