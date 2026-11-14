"use client";

import { useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore, type FormEvent, type SyntheticEvent } from "react";
import { createPortal } from "react-dom";
import { Avatar } from "@/components/Avatar";
import {
  CHAT_LAYER_Z,
  CHAT_MAX_CARDS,
  CHAT_MAX_LENGTH,
  chatStackRoom,
  cleanChatText,
  visibleChatCards,
  type ChatMessage,
} from "@/lib/tableChat";
import type { ChatSendResult } from "@/components/table/useTableChat";

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
}: {
  draft: string;
  onDraft: (text: string) => void;
  onSend: (text: string) => Promise<ChatSendResult>;
  onClose: () => void;
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
}: {
  messages: readonly ChatMessage[];
  onDismiss: (id: string) => void;
  onCloseAll: () => void;
  room?: "game" | "full";
}) {
  const anchorRef = useRef<HTMLSpanElement>(null);
  const stackRef = useRef<HTMLDivElement>(null);
  const onClient = useOnClient();
  const [fit, setFit] = useState(CHAT_MAX_CARDS);
  // Show was tapped while the newest message was this one; a newer message,
  // or closing that one, folds the stack again if it must.
  const [shownFor, setShownFor] = useState<string | null>(null);
  const expanded = shownFor !== null && messages.some((m) => m.id === shownFor);
  // The newest three; fewer of them may show (fit), the rest are "+N more".
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
      for (const card of stack.querySelectorAll<HTMLElement>("[data-chat-card]")) {
        const h = card.offsetHeight + STACK_GAP;
        // The newest card may run past the budget, never past the limit.
        if (used + h > (count === 0 ? place.limit : place.budget)) break;
        used += h;
        count++;
      }
      setFit(count);
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
  }, [messages, expanded, room, onClient]);

  if (messages.length === 0) return null;
  const shown = Math.min(fit, candidates.length);
  const folded = shown === 0;
  const more = messages.length - shown;
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
              {candidates.map((m, i) => (
                <div
                  key={m.id}
                  data-chat-card=""
                  aria-hidden={i >= shown || undefined}
                  className={`chat-card pointer-events-auto flex items-start gap-2 rounded-xl border border-zinc-300 bg-background/95 py-1 pl-2.5 text-sm shadow-md dark:border-zinc-700 ${
                    i >= shown ? "invisible absolute inset-x-0" : ""
                  }`}
                >
                  <span className="mt-1 shrink-0">
                    <Avatar name={m.name} url={m.avatarUrl} size="xs" tone="table" />
                  </span>
                  {/* Plain text: a React text node, so nothing in it is ever HTML or a link. */}
                  <p className="min-w-0 flex-1 self-center py-0.5 [overflow-wrap:anywhere]">
                    <span className="font-semibold">{m.name}</span>: {m.text}
                  </p>
                  <button
                    type="button"
                    aria-label={`Close message from ${m.name}`}
                    onClick={() => onDismiss(m.id)}
                    tabIndex={i >= shown ? -1 : undefined}
                    className="-my-1.5 flex h-11 w-11 shrink-0 items-center justify-center self-center rounded-full text-zinc-600 dark:text-zinc-400"
                  >
                    <svg viewBox="0 0 16 16" className="h-3.5 w-3.5" aria-hidden="true">
                      <path d="m4 4 8 8m0-8-8 8" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
                    </svg>
                  </button>
                </div>
              ))}
            </div>
          </div>,
          document.body
        )}
    </>
  );
}

export function ChatAnnouncer({ newest }: { newest: ChatMessage | undefined }) {
  return (
    <div aria-live="polite" aria-atomic="true" className="sr-only" data-chat-announcer="">
      {newest ? `${newest.name} says: ${newest.text}` : ""}
    </div>
  );
}
