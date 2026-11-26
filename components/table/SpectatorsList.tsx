"use client";

import { useEffect, useRef } from "react";
import { Avatar } from "@/components/Avatar";
import { PersonMark, PersonMuteButton } from "@/components/table/PersonMenu";
import { SPECTATOR_REMOVE_CONFIRM } from "@/lib/spectators";
import type { TableSpectator } from "@/lib/spectatorData";

// THE SPECTATORS LIST (spectator chat, PRD item 40): opened from the header's
// eye. Who is watching right now (get_table_spectators): avatar and name.
// For the HOST only, each row has Kick (moderation M2c: the old Remove,
// renamed; the same remove_spectator), which asks first ("They can't watch
// this table again."); the same confirm opens straight from a spectator's
// chat card (the host's shortcut) and from the person popup's Kick. Removal
// is permanent for this table (remove_spectator). A Kick that worked is
// followed by "Also block <name>?" (TableView).
//
// A native <dialog> opened with showModal(): it sits in the browser's top
// layer, above the chat cards' portal (z 55), the counts menu (62) and the
// composer (70) alike. Escape, a click on the backdrop and Close all close
// it; nothing is sent until Kick is confirmed.
//
// MODERATION M2c: every OTHER watcher's row has its buttons inline after the
// name -- "Mute"/"Unmute" for everyone (PersonMuteButton), then the host's
// "Kick". Their avatar carries the quiet mark when I muted or blocked them.
// No Mute on my own row.

export type SpectatorsListMode = { kind: "list" } | { kind: "confirm"; userId: string; name: string };

export function SpectatorsList({
  mode,
  spectators,
  canRemove,
  busy,
  error,
  onAskRemove,
  onConfirmRemove,
  onClose,
}: {
  // null: closed.
  mode: SpectatorsListMode | null;
  spectators: readonly TableSpectator[];
  // The host (the page decides: isHost, never a spectator).
  canRemove: boolean;
  busy: boolean;
  error: string | null;
  onAskRemove: (userId: string, name: string) => void;
  onConfirmRemove: (userId: string, name: string) => void;
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
      {mode?.kind === "confirm" ? (
        <div className="flex flex-col gap-3">
          <h2 id="spectators-title" className="font-display text-xl font-bold">
            Kick {mode.name}?
          </h2>
          <p className="text-sm">{SPECTATOR_REMOVE_CONFIRM}</p>
          {error && (
            <p role="alert" className="text-sm text-[var(--error-on-felt)]">
              {error}
            </p>
          )}
          <div className="flex flex-col gap-2">
            <button
              type="button"
              onClick={() => onConfirmRemove(mode.userId, mode.name)}
              disabled={busy}
              className="peg-btn peg-btn--brass join-choice__btn"
            >
              {busy ? "Kicking..." : "Kick"}
            </button>
            <button type="button" onClick={onClose} className="join-choice__cancel" autoFocus>
              Cancel
            </button>
          </div>
        </div>
      ) : (
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
                  {canRemove && (
                    <button
                      type="button"
                      onClick={() => onAskRemove(s.userId, nameOf(s))}
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
          <button type="button" onClick={onClose} className="join-choice__cancel" autoFocus>
            Close
          </button>
        </div>
      )}
    </dialog>
  );
}
