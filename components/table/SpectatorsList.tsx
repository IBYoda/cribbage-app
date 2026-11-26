"use client";

import { useEffect, useRef } from "react";
import { Avatar } from "@/components/Avatar";
import { PersonMark, PersonMuteButton } from "@/components/table/PersonMenu";
import type { TableSpectator } from "@/lib/spectatorData";

// THE SPECTATORS LIST (spectator chat, PRD item 40): opened from the header's
// eye. Who is watching right now (get_table_spectators): avatar and name.
// For the HOST only, each row has Kick (moderation M3: kick_player), which
// asks TableView's one kick confirm ("Kick <name>?", an AskDialog opened
// above this list) -- the same confirm the person popup's Kick and a
// spectator's chat-card eye open. A kick is permanent for this table. A
// Kick that worked is followed by "Also block <name>?"; one that failed
// shows its line here (`error`).
//
// A native <dialog> opened with showModal(): it sits in the browser's top
// layer, above the chat cards' portal (z 55), the counts menu (62) and the
// composer (70) alike. Escape, a click on the backdrop and Close all close
// it; nothing is sent from here.
//
// MODERATION M2c: every OTHER watcher's row has its buttons inline after the
// name -- "Mute"/"Unmute" for everyone (PersonMuteButton), then the host's
// "Kick". Their avatar carries the quiet mark when I muted or blocked them.
// No Mute on my own row.

export type SpectatorsListMode = { kind: "list" };

export function SpectatorsList({
  mode,
  spectators,
  canKick,
  error,
  onAskKick,
  onClose,
}: {
  // null: closed.
  mode: SpectatorsListMode | null;
  spectators: readonly TableSpectator[];
  // The host (the page decides: isHost, never a spectator).
  canKick: boolean;
  // A Kick that failed while this list is open.
  error: string | null;
  // Opens TableView's kick confirm (above this list).
  onAskKick: (userId: string, name: string) => void;
  onClose: () => void;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  const open = mode !== null;
  const openRef = useRef(open);

  useEffect(() => {
    openRef.current = open;
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) d.showModal();
    if (!open && d.open) d.close();
  }, [open]);

  const nameOf = (s: TableSpectator) => s.nickname?.trim() || "A spectator";

  return (
    <dialog
      ref={ref}
      className="about-dialog spectators-dialog"
      aria-labelledby="spectators-title"
      onCancel={(e) => {
        e.preventDefault();
        onClose();
      }}
      onClose={() => {
        if (openRef.current) onClose();
      }}
      onClick={(e) => {
        if (e.target === ref.current) onClose();
      }}
    >
      <div className="flex flex-col gap-3">
        <h2 id="spectators-title" className="font-display text-xl font-bold">
          Watching ({spectators.length})
        </h2>
        {spectators.length === 0 ? (
          <p className="text-sm">Nobody is watching right now.</p>
        ) : (
          <ul className="flex flex-col gap-1" aria-label="Spectators">
            {spectators.map((s) => (
              <li key={s.userId} className="flex min-h-11 items-center gap-2">
                <PersonMark userId={s.userId}>
                  <Avatar name={nameOf(s)} url={s.avatarUrl} size="sm" />
                </PersonMark>
                <span className="min-w-0 flex-1 truncate font-semibold">{nameOf(s)}</span>
                <PersonMuteButton userId={s.userId} name={nameOf(s)} />
                {canKick && (
                  <button
                    type="button"
                    onClick={() => onAskKick(s.userId, nameOf(s))}
                    className="person-btn"
                    data-person-action="kick"
                    aria-label={`Kick ${nameOf(s)}`}
                  >
                    Kick
                  </button>
                )}
              </li>
            ))}
          </ul>
        )}
        {error && (
          <p role="alert" className="text-sm text-[var(--error-on-felt)]">
            {error}
          </p>
        )}
        <button type="button" onClick={onClose} className="join-choice__cancel" autoFocus>
          Close
        </button>
      </div>
    </dialog>
  );
}
