"use client";

import { useEffect, useRef, useSyncExternalStore, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Avatar } from "@/components/Avatar";
import { canOfferPersonMenu, mutedAtTable, mutedMark, mutedMarkText, personPopupButtons, type MutedMark } from "@/lib/personMenu";

// THE PERSON POPUP (moderation M2b/M2c): ONE centred popup window for another
// person at the table, in the spectator list's look (the About dialog's dark
// green panel and gold border, large gold-outlined buttons, "Close" under
// them). Top to bottom: their avatar and name, the buttons, Close.
//   Everyone: "Mute" or "Unmute". The HOST: also "Kick" beside it.
// It opens from
//   PersonTap      a seat's avatar (plates, the top and side seats, the
//                  square layout's header and side tags): an invisible 44px
//                  tap area over the avatar, so nothing moves or resizes;
//   PersonName     the name beside it;
//   openPersonPopup  the chat card's "..." (TableChat).
// Also here: PersonMuteButton (the spectator list's inline Mute/Unmute),
// PersonMark (the quiet mark on an avatar), MutedHereLine (the composer's
// "Muted: <name> [Unmute]" line). The rules are lib/personMenu.ts.
//
// THE STORE: TableView publishes who I muted here and blocked, whether I am
// the host, the roster (for avatars) and the actions
// (publishPersonModeration); these components read it with
// useSyncExternalStore, so no prop threading through every seat. TableView
// also draws the one <PersonPopup /> (beside the spectator list). Off the
// table screen nothing is published, and every component here draws its
// children exactly as before.
//
// THE POPUP is a native <dialog> opened with showModal(): the browser's top
// layer, above the chat cards (z 55), the composer (z 70) and -- opened after
// it -- the spectator list's own dialog. Escape, Close and a tap outside
// (on the backdrop) close it. Mute and Unmute close it first, then act (Mute
// then asks "Also block <name>?", TableView's AskDialog, opened after this
// one closes).

export type PersonModeration = {
  // A human table I'm signed in at (never a computer table).
  enabled: boolean;
  myUserId: string | null;
  // The host gets Kick (TableView decides: never a spectator).
  isHost: boolean;
  // Muted by me at THIS table (lib/chatMute.ts).
  muted: ReadonlySet<string>;
  // On my Block List (for the quiet mark, and to skip "Also block?").
  blocked: ReadonlySet<string>;
  // The people at the table (players, then spectators), for the avatar.
  people: readonly { user_id: string; nickname: string | null; avatar_url: string | null }[];
  // Mutes at once, then (unless already blocked) asks "Also block <name>?".
  mute: (userId: string, name: string) => void;
  unmute: (userId: string) => void;
  // The host's Kick (moderation M3): opens the kick confirm, then
  // kick_player -- a player or a spectator alike.
  kick: (userId: string, name: string) => void;
};

type OpenState = { userId: string; name: string } | null;

let moderation: PersonModeration | null = null;
let openState: OpenState = null;
const listeners = new Set<() => void>();
const emit = () => listeners.forEach((l) => l());
const subscribe = (l: () => void) => {
  listeners.add(l);
  return () => {
    listeners.delete(l);
  };
};

export function publishPersonModeration(next: PersonModeration | null) {
  moderation = next;
  if (!next) openState = null;
  emit();
}

export function usePersonModeration(): PersonModeration | null {
  return useSyncExternalStore(subscribe, () => moderation, () => null);
}

function useOpenState(): OpenState {
  return useSyncExternalStore(subscribe, () => openState, () => null);
}

// Whether the popup is open now (TableView holds the kick notice back
// while it is).
export function usePersonPopupOpen(): boolean {
  return useOpenState() !== null;
}

// Opens the popup for one person (only someone the table offers it for).
export function openPersonPopup(userId: string, name: string) {
  if (!moderation || !canOfferPersonMenu({ userId, myUserId: moderation.myUserId, enabled: moderation.enabled })) return;
  openState = { userId, name };
  emit();
}

function closePersonPopup() {
  if (openState) {
    openState = null;
    emit();
  }
}

// The state of one person, for labels and the quiet mark.
function personState(mod: PersonModeration | null, userId: string) {
  return { muted: !!mod?.muted.has(userId), blocked: !!mod?.blocked.has(userId) };
}

// THE POPUP itself: drawn once by TableView; shows the open person, if any.
export function PersonPopup() {
  const mod = usePersonModeration();
  const open = useOpenState();
  const ref = useRef<HTMLDialogElement>(null);
  const closeRef = useRef<HTMLButtonElement>(null);
  const shown = !!open && !!mod && canOfferPersonMenu({ userId: open.userId, myUserId: mod.myUserId, enabled: mod.enabled });
  const shownRef = useRef(shown);

  useEffect(() => {
    shownRef.current = shown;
    const d = ref.current;
    if (!d) return;
    if (shown && !d.open) {
      d.showModal();
      // showModal focuses the first button (Mute); start on Close instead.
      closeRef.current?.focus();
    }
    if (!shown && d.open) d.close();
  }, [shown]);

  if (typeof document === "undefined") return null;
  const person = shown && open && mod ? open : null;
  const avatarUrl = person ? (mod?.people.find((p) => p.user_id === person.userId)?.avatar_url ?? null) : null;
  const mark = person ? mutedMark(personState(mod, person.userId)) : null;
  return createPortal(
    <dialog
      ref={ref}
      className="about-dialog person-popup"
      aria-labelledby="person-popup-name"
      data-person-popup=""
      onCancel={(e) => {
        // Escape: close.
        e.preventDefault();
        closePersonPopup();
      }}
      onClose={() => {
        if (shownRef.current) closePersonPopup();
      }}
      onClick={(e) => {
        // A tap on the backdrop lands on the <dialog> itself.
        if (e.target === ref.current) closePersonPopup();
      }}
    >
      {person && mod && (
        <div className="flex flex-col items-center gap-4">
          <div className="flex flex-col items-center gap-2">
            <span className="person-tap">
              <Avatar name={person.name} url={avatarUrl} size="lg" />
              <MutedBadge mark={mark} />
            </span>
            <h2 id="person-popup-name" className="max-w-full truncate font-display text-xl font-bold">
              {person.name}
              <span className="sr-only">{mutedMarkText(mark)}</span>
            </h2>
          </div>
          <div className="flex w-full gap-2">
            {personPopupButtons({ muted: mod.muted.has(person.userId), isHost: mod.isHost }).map((b) => (
              <button
                key={b.action}
                type="button"
                className="person-btn person-btn--large flex-1"
                data-person-action={b.action}
                onClick={() => {
                  // Close first, then act: Mute's "Also block?" opens after.
                  closePersonPopup();
                  if (b.action === "mute") mod.mute(person.userId, person.name);
                  else if (b.action === "unmute") mod.unmute(person.userId);
                  else mod.kick(person.userId, person.name);
                }}
              >
                {b.label}
              </button>
            ))}
          </div>
          <button ref={closeRef} type="button" onClick={closePersonPopup} className="join-choice__cancel">
            Close
          </button>
        </div>
      )}
    </dialog>,
    document.body
  );
}

// THE QUIET MARK: a 12px badge on the avatar's lower right -- a slashed
// speech bubble for muted, a no-entry sign for blocked. Absolutely placed,
// pointer-events none: it never moves anything or takes a tap.
export function MutedBadge({ mark }: { mark: MutedMark }) {
  if (!mark) return null;
  return (
    <span className={`person-badge person-badge--${mark}`} aria-hidden="true" data-person-badge={mark}>
      {mark === "blocked" ? (
        <svg viewBox="0 0 12 12" className="h-2 w-2">
          <circle cx="6" cy="6" r="4.6" fill="none" stroke="currentColor" strokeWidth="1.6" />
          <path d="M2.8 9.2 9.2 2.8" stroke="currentColor" strokeWidth="1.6" />
        </svg>
      ) : (
        <svg viewBox="0 0 12 12" className="h-2 w-2">
          <path d="M2 2.5h8v5H5.5L3.5 9.5v-2H2z" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinejoin="round" />
          <path d="M1.5 10.5 10.5 1.5" stroke="currentColor" strokeWidth="1.4" />
        </svg>
      )}
    </span>
  );
}

// A SEAT'S AVATAR: the avatar as it was, plus (for another person at a human
// table) an invisible 44px tap area centred on it and the quiet mark. The
// wrapper is an inline-flex box the avatar's own size, so the seat's layout
// doesn't change. surface: which place on screen (a data attribute only).
export function PersonTap({ userId, name, surface, children }: { userId: string; name: string; surface: string; children: ReactNode }) {
  const mod = usePersonModeration();
  if (!mod || !canOfferPersonMenu({ userId, myUserId: mod.myUserId, enabled: mod.enabled })) return <>{children}</>;
  const mark = mutedMark(personState(mod, userId));
  return (
    <span className="person-tap" data-person-tap={surface}>
      {children}
      <MutedBadge mark={mark} />
      <button
        type="button"
        className="person-tap__hit"
        aria-label={`Options for ${name}${mutedMarkText(mark)}`}
        aria-haspopup="dialog"
        onClick={() => openPersonPopup(userId, name)}
      />
    </span>
  );
}

// A SEAT'S NAME: the same element and classes as before (span or p), and a
// tap on it opens the same popup as the avatar beside it.
export function PersonName({
  userId,
  name,
  surface,
  as = "span",
  className,
  title,
  sq,
  children,
}: {
  userId: string;
  name: string;
  surface: string;
  as?: "span" | "p";
  className?: string;
  title?: string;
  // The element's data-sq, kept as the seat had it.
  sq?: string;
  children: ReactNode;
}) {
  const mod = usePersonModeration();
  const Tag = as;
  if (!mod || !canOfferPersonMenu({ userId, myUserId: mod.myUserId, enabled: mod.enabled })) {
    return (
      <Tag className={className} title={title} data-sq={sq}>
        {children}
      </Tag>
    );
  }
  return (
    <Tag
      className={`${className ?? ""} person-name-tap`}
      title={title}
      data-sq={sq}
      data-person-name={surface}
      onClick={() => openPersonPopup(userId, name)}
    >
      {children}
    </Tag>
  );
}

// THE SPECTATOR LIST'S INLINE MUTE: "Mute" or "Unmute" for another person's
// row (nothing for my own row, or at a computer table). Mute asks "Also
// block <name>?" after, above the list.
export function PersonMuteButton({ userId, name }: { userId: string; name: string }) {
  const mod = usePersonModeration();
  if (!mod || !canOfferPersonMenu({ userId, myUserId: mod.myUserId, enabled: mod.enabled })) return null;
  const muted = mod.muted.has(userId);
  return (
    <button
      type="button"
      className="person-btn"
      data-person-action={muted ? "unmute" : "mute"}
      aria-label={`${muted ? "Unmute" : "Mute"} ${name}`}
      onClick={() => (muted ? mod.unmute(userId) : mod.mute(userId, name))}
    >
      {muted ? "Unmute" : "Mute"}
    </button>
  );
}

// The quiet mark for one person (for rows that draw their own avatar).
export function PersonMark({ userId, children }: { userId: string; children: ReactNode }) {
  const mod = usePersonModeration();
  const mark = mod && canOfferPersonMenu({ userId, myUserId: mod.myUserId, enabled: mod.enabled }) ? mutedMark(personState(mod, userId)) : null;
  if (!mark) return <>{children}</>;
  return (
    <span className="person-tap">
      {children}
      <MutedBadge mark={mark} />
    </span>
  );
}

// THE COMPOSER'S LINE: "Muted: <name> [Unmute] ..." for the people at this
// table I have muted; nothing when there are none. Unmute brings their NEW
// messages back at once (already-dropped ones stay gone).
export function MutedHereLine({ roster }: { roster: readonly { user_id: string; nickname: string | null }[] }) {
  const mod = usePersonModeration();
  if (!mod || !mod.enabled) return null;
  const here = mutedAtTable(roster, mod.muted, mod.myUserId);
  if (here.length === 0) return null;
  return (
    <p className="mx-auto mt-1 flex max-w-4xl flex-wrap items-center gap-x-3 gap-y-1 text-xs" data-chat-muted-here="">
      <span className="text-zinc-600 dark:text-zinc-400">Muted:</span>
      {here.map((p) => (
        <span key={p.userId} className="flex items-center gap-1">
          <span className="font-medium">{p.name}</span>
          <button
            type="button"
            onClick={() => mod.unmute(p.userId)}
            className="chat-tap rounded px-1 underline"
            aria-label={`Unmute ${p.name}`}
          >
            Unmute
          </button>
        </span>
      ))}
    </p>
  );
}
