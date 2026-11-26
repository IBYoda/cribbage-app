"use client";

import { useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore, type FormEvent, type SyntheticEvent } from "react";
import { createPortal } from "react-dom";
import { Avatar } from "@/components/Avatar";
import { SpectatorEyeGlyph } from "@/components/SpectatorsTag";
import {
  CHAT_LAYER_Z,
  CHAT_MAX_CARDS,
  CHAT_MAX_LENGTH,
  OWN_CARD_FADE_MS,
  OWN_CARD_MS,
  chatStackCounts,
  chatStackRoom,
  cleanChatText,
  visibleChatCards,
  type ChatMessage,
} from "@/lib/tableChat";
import type { ChatSendResult } from "@/components/table/useTableChat";
import { openPersonPopup, usePersonModeration } from "@/components/table/PersonMenu";
import { canOfferPersonMenu } from "@/lib/personMenu";

// TABLE CHAT's pieces on screen (PRD item 39). The channels are
// useTableChat; these only draw.
//
//   ChatButton     the speech bubble in the header, beside the speaker: the
//                  same 24px icon and 40px tap target. .sound-toggle keeps it
//                  above the deal overlay too, so a tap on it opens the
//                  composer instead of skipping the deal.
//   ChatComposer   a bar FIXED to the top of the screen (a portal to <body>:
//                  the table's middle is a size container, which would pin a
//                  fixed bar to itself), so a phone keyboard never covers it.
//                  It follows the visual viewport down when iOS scrolls the
//                  page for the keyboard.
//   ChatStack      the incoming messages, as cards at the top of the table's
//                  middle, on a layer above every table element (a portal
//                  to <body>, fixed over the middle, below its banner);
//                  never part of the flow, so nothing moves.
//   ChatAnnouncer  the newest message, read out politely by a screen reader;
//                  outside the stack so it still speaks while the stack is
//                  hidden (a deal).

// Stops a tap on chat reaching anything under it that listens for taps on
// the table (a "tap anywhere" skip).
const stop = (e: SyntheticEvent) => e.stopPropagation();

// True once on the client: the composer's portal is never drawn by the
// server, and never during hydration.
const noSubscribe = () => () => {};
const useOnClient = () => useSyncExternalStore(noSubscribe, () => true, () => false);

export function ChatButton({
  open,
  onToggle,
  buttonRef,
}: {
  open: boolean;
  onToggle: () => void;
  buttonRef?: React.Ref<HTMLButtonElement>;
}) {
  return (
    <button
      ref={buttonRef}
      type="button"
      aria-label="Chat"
      aria-expanded={open}
      aria-controls={open ? "table-chat-composer" : undefined}
      title="Chat"
      onClick={onToggle}
      className="sound-toggle tap-40 shrink-0 px-1 text-zinc-600 dark:text-zinc-400"
      data-chat-button=""
    >
      {/* A line tall, as tap-40 reckons: a 16px speech bubble. */}
      <svg viewBox="0 0 16 16" className="block h-[1lh] w-4" fill="none" aria-hidden="true">
        <path
          d="M3 3h10a1.5 1.5 0 0 1 1.5 1.5v5A1.5 1.5 0 0 1 13 11H7.5L4.5 13.5V11H3a1.5 1.5 0 0 1-1.5-1.5v-5A1.5 1.5 0 0 1 3 3Z"
          stroke="currentColor"
          strokeWidth="1.4"
          strokeLinejoin="round"
        />
      </svg>
    </button>
  );
}

export function ChatComposer({
  draft,
  onDraft,
  onSend,
  onClose,
  below,
}: {
  draft: string;
  onDraft: (text: string) => void;
  onSend: (text: string) => Promise<ChatSendResult>;
  onClose: () => void;
  // Under the input row (moderation M2b/M2c): the "Muted: <name> [Unmute]"
  // line for people at this table I muted (PersonMenu's MutedHereLine); it draws
  // nothing when there are none.
  below?: React.ReactNode;
}) {
  const [note, setNote] = useState<"throttled" | "failed" | null>(null);
  const [sending, setSending] = useState(false);
  const barRef = useRef<HTMLFormElement>(null);
  const onClient = useOnClient();

  // Escape closes it, wherever focus is.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [onClose]);

  // "Slow down" and "Couldn't send" clear themselves.
  useEffect(() => {
    if (!note) return;
    const t = window.setTimeout(() => setNote(null), 2500);
    return () => window.clearTimeout(t);
  }, [note]);

  // iOS scrolls the page under a fixed bar to show the keyboard; the visual
  // viewport's top says how far, and the bar follows it.
  useEffect(() => {
    const vv = window.visualViewport;
    const bar = barRef.current;
    if (!vv || !bar) return;
    const follow = () => {
      bar.style.transform = vv.offsetTop > 0 ? `translateY(${vv.offsetTop}px)` : "";
    };
    follow();
    vv.addEventListener("resize", follow);
    vv.addEventListener("scroll", follow);
    return () => {
      vv.removeEventListener("resize", follow);
      vv.removeEventListener("scroll", follow);
    };
  }, [onClient]);

  const empty = cleanChatText(draft) === null;

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (empty || sending) return;
    setSending(true);
    setNote(null);
    const result = await onSend(draft);
    setSending(false);
    if (result === "ok") {
      onDraft("");
      onClose();
    } else {
      setNote(result);
    }
  }

  if (!onClient) return null;
  return createPortal(
    <form
      ref={barRef}
      id="table-chat-composer"
      onSubmit={submit}
      onPointerDown={stop}
      onClick={stop}
      className="chat-composer fixed inset-x-0 top-0 z-[70] border-b border-zinc-300 bg-background px-2 py-2 shadow-lg dark:border-zinc-700"
      aria-label="Send a chat message"
    >
      <div className="mx-auto flex max-w-4xl items-center gap-2">
        <input
          type="text"
          value={draft}
          onChange={(e) => onDraft(e.target.value)}
          maxLength={CHAT_MAX_LENGTH}
          enterKeyHint="send"
          autoFocus
          autoComplete="off"
          aria-label="Message"
          placeholder="Message the table"
          className="h-10 min-w-0 flex-1 rounded border border-zinc-300 bg-background px-2 text-base dark:border-zinc-700"
        />
        {note && (
          <span role="status" className="shrink-0 text-xs text-red-600 dark:text-red-400">
            {note === "throttled" ? "Slow down" : "Couldn't send"}
          </span>
        )}
        <button
          type="submit"
          disabled={empty || sending}
          className="h-10 shrink-0 rounded bg-foreground px-3 text-sm font-medium text-background disabled:opacity-40"
        >
          Send
        </button>
        <button
          type="button"
          onClick={onClose}
          className="h-10 shrink-0 px-1 text-sm text-zinc-600 underline dark:text-zinc-400"
        >
          Cancel
        </button>
      </div>
      {below}
    </form>,
    document.body
  );
}

// WHERE THE STACK GOES: a layer of its own, fixed over the table's middle (a
// portal to <body>, z CHAT_LAYER_Z), so no table element -- the crib and the
// starter hanging over the top of the middle, the cut's deck, cards, piles,
// avatars, the board -- can ever be drawn over a message. It starts below
// any table notice in the middle (the amber "game was ended" banner, marked
// data-table-notice), so it never covers the notice's text or its Dismiss.
// The middle is found from a hidden anchor this component leaves where it is
// rendered (middleOverlays).
//
// HOW MUCH ROOM: chatStackRoom (lib/tableChat.ts). Never past the middle's
// bottom (the piles and the hand stay clear) and, in a game, never down over
// the middle's first control (Next Hand, Confirm Count, the cut's deck...).
// With no hand dealt (`room` "full": the waiting room) all of the middle
// below the notice; in a game half of it, the newest card as far as the
// limit. Only when not even the newest card fits does the stack fold to
// "1 new message · Show"; Show lets the cards over the controls (the player
// asked; each card's x clears it).
const STACK_GAP = 4;

export function ChatStack({
  messages,
  onDismiss,
  onCloseAll,
  room = "game",
  own = null,
  onDismissOwn,
  onRemoveSpectator,
}: {
  messages: readonly ChatMessage[];
  onDismiss: (id: string) => void;
  onCloseAll: () => void;
  room?: "game" | "full";
  // THE HOST ONLY (the page passes it for the host and nobody else): a
  // spectator's card's eye becomes a 44px button that asks to kick them
  // (the page's confirm, a native dialog above this layer).
  onRemoveSpectator?: (userId: string, name: string) => void;
  // My own last message (useTableChat), on top for OWN_CARD_MS. Extra: it
  // shows only if it fits below the others' cards, never displacing one,
  // and never counts in the fold or "+N more".
  own?: ChatMessage | null;
  onDismissOwn?: () => void;
}) {
  const anchorRef = useRef<HTMLSpanElement>(null);
  const stackRef = useRef<HTMLDivElement>(null);
  const onClient = useOnClient();
  const [fit, setFit] = useState(CHAT_MAX_CARDS);
  const [ownFits, setOwnFits] = useState(true);
  // Show was tapped while the newest message was this one; a newer message,
  // or closing that one, folds the stack again if it must.
  const [shownFor, setShownFor] = useState<string | null>(null);
  const expanded = shownFor !== null && messages.some((m) => m.id === shownFor);
  // MODERATION M2 / M2c: each OTHER person's card gets a visible "..." that
  // opens the person popup (components/table/PersonMenu.tsx: their avatar
  // and name, Mute/Unmute, the host's Kick -- the same popup as a seat).
  // Never on my own card; only while the table offers it (a human table,
  // signed in). Room for "Report" later, in the popup.
  const moderation = usePersonModeration();

  // The newest CHAT_MAX_CARDS (5); fewer of them may show (fit), the rest are
  // "+N more".
  const candidates = visibleChatCards(messages).shown;

  // Places the layer over the middle (below its notices) and works out how
  // many of the newest cards fit, from their real heights (a long message
  // wraps) and where the middle's controls are. Again whenever the middle
  // or the page resizes, scrolls or changes (Next Hand appearing, the banner
  // going).
  useLayoutEffect(() => {
    const anchor = anchorRef.current;
    const stack = stackRef.current;
    if (!anchor || !stack) return;
    const middle = anchor.closest<HTMLElement>(".sq-middle, .table-middle") ?? anchor.parentElement;
    if (!middle) return;
    let frame = 0;
    const visible = (el: Element) => {
      const r = el.getBoundingClientRect();
      return r.width > 0 && r.height > 0 ? r : null;
    };
    const measure = () => {
      frame = 0;
      const m = visible(middle);
      if (!m) {
        stack.dataset.off = "";
        return;
      }
      delete stack.dataset.off;
      const notices = Array.from(middle.querySelectorAll("[data-table-notice]"));
      const controls: { top: number; bottom: number }[] = [];
      for (const control of middle.querySelectorAll<HTMLElement>("button, a[href], input, select")) {
        if (notices.some((n) => n.contains(control))) continue;
        const r = visible(control);
        if (r) controls.push(r);
      }
      const place = chatStackRoom({
        middle: m,
        notices: notices.map(visible).filter((r): r is DOMRect => r !== null),
        controls,
        mode: room,
        expanded,
        gap: STACK_GAP,
      });
      stack.style.left = `${m.left}px`;
      stack.style.width = `${m.width}px`;
      stack.style.top = `${place.top}px`;
      const controlsRow = stack.querySelector<HTMLElement>("[data-chat-controls]");
      let used = controlsRow ? controlsRow.offsetHeight + 2 * STACK_GAP : 0;
      let count = 0;
      for (const card of stack.querySelectorAll<HTMLElement>("[data-chat-card]:not([data-chat-own])")) {
        const h = card.offsetHeight + STACK_GAP;
        // The newest card may run past the budget, never past the limit.
        if (used + h > (count === 0 ? place.limit : place.budget)) break;
        used += h;
        count++;
      }
      setFit(count);
      // My own card: on top of the others, if it fits below the limit with
      // them; else it just doesn't show (it never folds or pushes).
      const ownCard = stack.querySelector<HTMLElement>("[data-chat-own]");
      setOwnFits(!ownCard || used + ownCard.offsetHeight + STACK_GAP <= place.limit);
    };
    const soon = () => {
      if (!frame) frame = requestAnimationFrame(measure);
    };
    measure();
    const resize = new ResizeObserver(soon);
    resize.observe(middle);
    resize.observe(document.body);
    const mutate = new MutationObserver(soon);
    mutate.observe(middle, { childList: true, subtree: true, attributes: true, attributeFilter: ["class", "style", "disabled"] });
    const vv = window.visualViewport;
    window.addEventListener("resize", soon);
    window.addEventListener("scroll", soon, { capture: true, passive: true });
    vv?.addEventListener("resize", soon);
    return () => {
      resize.disconnect();
      mutate.disconnect();
      window.removeEventListener("resize", soon);
      window.removeEventListener("scroll", soon, { capture: true });
      vv?.removeEventListener("resize", soon);
      if (frame) cancelAnimationFrame(frame);
    };
  }, [messages, own, expanded, room, onClient]);

  if (messages.length === 0 && !own) return null;
  const { shown, folded, more } = chatStackCounts(messages, fit);
  // The pills: "+N more", "Close all" and the folded line. 32px drawn,
  // 44px to tap (.chat-tap).
  const pill =
    "chat-pill pointer-events-auto flex h-8 items-center gap-2 rounded-full border border-zinc-300 bg-background/95 px-3 text-xs shadow dark:border-zinc-700";
  return (
    <>
      <span ref={anchorRef} hidden data-chat-anchor="" />
      {onClient &&
        createPortal(
          <div
            ref={stackRef}
            className="chat-stack pointer-events-none fixed px-1"
            style={{ zIndex: CHAT_LAYER_Z }}
            onPointerDown={stop}
            onClick={stop}
            data-chat-stack=""
          >
            <div className="relative mx-auto flex w-full max-w-md flex-col gap-1">
              {(messages.length >= 2 || folded) && (
                <div className="mb-1 flex items-center justify-end gap-2 self-end" data-chat-controls="">
                  {folded ? (
                    <span className={pill}>
                      <span className="text-zinc-600 dark:text-zinc-400">
                        {messages.length} new {messages.length === 1 ? "message" : "messages"}
                      </span>
                      <span aria-hidden="true">·</span>
                      <button
                        type="button"
                        onClick={() => setShownFor(messages[0].id)}
                        className="chat-tap font-medium underline"
                      >
                        Show
                      </button>
                    </span>
                  ) : (
                    more > 0 && <span className={`${pill} text-zinc-600 dark:text-zinc-400`}>+{more} more</span>
                  )}
                  {messages.length >= 2 && (
                    <button type="button" onClick={onCloseAll} className={`${pill} chat-tap font-medium`}>
                      Close all
                    </button>
                  )}
                </div>
              )}
              {own && (
                <ChatCard
                  key={own.id}
                  message={own}
                  hidden={!ownFits}
                  onClose={() => onDismissOwn?.()}
                  own
                />
              )}
              {candidates.map((m, i) => (
                <ChatCard
                  key={m.id}
                  message={m}
                  hidden={i >= shown}
                  onClose={() => onDismiss(m.id)}
                  onRemove={m.spectator && onRemoveSpectator ? () => onRemoveSpectator(m.senderId, m.name) : undefined}
                  onMore={
                    moderation &&
                    canOfferPersonMenu({ userId: m.senderId, myUserId: moderation.myUserId, enabled: moderation.enabled })
                      ? () => openPersonPopup(m.senderId, m.name)
                      : undefined
                  }
                />
              ))}
            </div>
          </div>,
          document.body
        )}
    </>
  );
}

// One message card: avatar, "Name: text" as plain text, and its x (44px).
// `hidden`: laid out (so it can be measured) but invisible and out of the
// flow. `own`: my own message, which fades out over the end of OWN_CARD_MS
// (the hook removes it at OWN_CARD_MS; with reduced motion it just goes).
function ChatCard({
  message: m,
  hidden,
  onClose,
  own = false,
  onRemove,
  onMore,
}: {
  message: ChatMessage;
  hidden: boolean;
  onClose: () => void;
  own?: boolean;
  // The host's shortcut on a spectator's card (ChatStack's onRemoveSpectator).
  onRemove?: () => void;
  // MODERATION M2c: the "..." opens the person popup. Never on my own card.
  onMore?: () => void;
}) {
  const showMore = own ? undefined : onMore;
  return (
    <div
      data-chat-card=""
      data-chat-own={own ? "" : undefined}
      aria-hidden={hidden || undefined}
      style={
        own
          ? ({ "--own-fade-delay": `${OWN_CARD_MS - OWN_CARD_FADE_MS}ms`, "--own-fade": `${OWN_CARD_FADE_MS}ms` } as React.CSSProperties)
          : undefined
      }
      className={`chat-card pointer-events-auto flex items-start gap-2 rounded-xl border border-zinc-300 bg-background/95 py-1 pl-2.5 text-sm shadow-md dark:border-zinc-700 ${
        own ? "chat-card--own" : ""
      } ${hidden ? "invisible absolute inset-x-0" : "relative"}`}
    >
      <span className="mt-1 shrink-0">
        <Avatar name={m.name} url={m.avatarUrl} size="xs" tone="table" />
      </span>
      {/* Plain text: a React text node, so nothing in it is ever HTML or a link. */}
      <p className="min-w-0 flex-1 self-center py-0.5 [overflow-wrap:anywhere]">
        <span className="font-semibold">{m.name}</span>
        {/* A spectator's message: a small eye after the name. For the host it
            is a button (a 44px target, .chat-eye-tap) that asks to kick
            them; for everyone else just the mark. */}
        {m.spectator &&
          (onRemove ? (
            <button
              type="button"
              onClick={onRemove}
              tabIndex={hidden ? -1 : undefined}
              aria-label={`Kick ${m.name}`}
              title="Kick"
              className="chat-eye chat-eye-tap"
              data-chat-eye="remove"
            >
              <SpectatorEyeGlyph size={12} />
            </button>
          ) : (
            <span className="chat-eye" title="Watching" data-chat-eye="">
              <SpectatorEyeGlyph size={12} />
              <span className="sr-only"> (watching)</span>
            </span>
          ))}
        : {m.text}
      </p>
      {/* MODERATION M2: a VISIBLE "..." (Walt: a hidden control is easy to
          miss). 36px wide and 44px tall, as tall as the x beside it, so the
          card's height never changes. It opens the person popup (M2c), a
          native dialog above this layer. */}
      {showMore && (
        <button
          type="button"
          onClick={showMore}
          tabIndex={hidden ? -1 : undefined}
          aria-label={`More for ${m.name}`}
          aria-haspopup="dialog"
          title="More"
          data-chat-menu-button={m.id}
          className="-my-1.5 -mr-2 flex h-11 w-9 shrink-0 items-center justify-center self-center rounded-full text-zinc-600 dark:text-zinc-400"
        >
          <svg viewBox="0 0 16 16" className="h-4 w-4" aria-hidden="true">
            <circle cx="3" cy="8" r="1.5" fill="currentColor" />
            <circle cx="8" cy="8" r="1.5" fill="currentColor" />
            <circle cx="13" cy="8" r="1.5" fill="currentColor" />
          </svg>
        </button>
      )}
      <button
        type="button"
        aria-label={own ? "Close your message" : `Close message from ${m.name}`}
        onClick={onClose}
        tabIndex={hidden ? -1 : undefined}
        className="-my-1.5 flex h-11 w-11 shrink-0 items-center justify-center self-center rounded-full text-zinc-600 dark:text-zinc-400"
      >
        <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" aria-hidden="true">
          <path d="m4 4 8 8m0-8-8 8" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
        </svg>
      </button>
    </div>
  );
}

export function ChatAnnouncer({ newest }: { newest: ChatMessage | undefined }) {
  return (
    <div aria-live="polite" aria-atomic="true" className="sr-only" data-chat-announcer="">
      {newest ? `${newest.name} says: ${newest.text}` : ""}
    </div>
  );
}
