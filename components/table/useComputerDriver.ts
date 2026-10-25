"use client";

// THE COMPUTER DRIVER: makes the computer opponent's moves from the human's
// browser, at a computer table (tables.computer_level set) that this user
// created. The server allows it only there (the computer_* functions'
// guard); this hook decides WHEN and WHAT:
//
//   * computerNextAction (lib/computer/next.ts) says what the computer owes
//     now, with a key naming that exact moment;
//   * on a new key it waits a "thinking" delay (THINK_MS), RE-COMPUTES from
//     the latest state, and acts only if the key is still the same;
//   * discards and plays are chosen by the brain (lib/computer/brain.ts)
//     from fresh reads: the computer's hand (computer_hand), and for a play
//     the games row and the play log as they are at that moment;
//   * every call goes through the page's trackAction, then a full re-read,
//     exactly like the human's own handlers.
//
// SAFETY: a key is sent at most once at a time (React runs effects twice in
// development), timers are cancelled on cleanup, and the latest state is
// always read through a ref, never a stale closure. A refusal that only
// means "the state moved on" is re-read and re-evaluated quietly; anything
// else is logged once. The same key failing again backs off (2, 4, 8, 16 s)
// and gives up after 5 tries (logged once) -- then tries that key again
// after 30 s or when the tab becomes visible, and a later state change (an
// event, the 12 s safety poll) gives a new key and starts over anyway.

import { useEffect, useRef, useState } from "react";
import { supabase } from "@/lib/supabase";
import { decideDiscard, decidePlay } from "@/lib/computer/brain";
import { THINK_MS, isComputerLevel, type ComputerLevel } from "@/lib/computer/config";
import { computerNextAction, type ComputerAction, type NextGame } from "@/lib/computer/next";

export type ComputerDriverInput = {
  // A computer table, created by this user, still open, and not being left.
  enabled: boolean;
  tableId: string | null;
  level: string | null; // tables.computer_level
  computerId: string | null; // the other seated member
  tableFull: boolean;
  humanHoldsPegging: boolean;
  game: NextGame | null; // the live game on screen
  finished: { id: string; players: string[]; ready_by: string[] } | null; // a WON game on screen
  humanHand: string[]; // the human's own hand (four kept cards from the discard on)
  trackAction: <T>(call: PromiseLike<T>) => Promise<T>;
  refresh: () => Promise<void>;
};

// Refusals that only mean "the game moved on": re-read and look again.
const HARMLESS = [
  "it is not your turn",
  "already",
  "not in the play phase",
  "no longer active",
  "not cutting",
  "not up yet",
  "not your turn to count",
];
const MAX_TRIES = 5;
// After giving up on a key, try it again this much later, or as soon as the
// tab becomes visible again -- so a stuck game never needs a reload.
const GIVE_UP_RETRY_MS = 30_000;

function thinkMs(kind: ComputerAction["kind"]) {
  const [min, max] =
    kind === "draw" || kind === "ack"
      ? THINK_MS.cut
      : kind === "discard"
        ? THINK_MS.discard
        : kind === "play"
          ? THINK_MS.play
          : kind === "confirm"
            ? THINK_MS.count
            : THINK_MS.ready;
  return min + Math.random() * (max - min);
}

function nextActionOf(input: ComputerDriverInput): ComputerAction | null {
  if (!input.enabled || !input.computerId || !input.tableId || !isComputerLevel(input.level)) return null;
  return computerNextAction({
    computerId: input.computerId,
    tableFull: input.tableFull,
    humanHoldsPegging: input.humanHoldsPegging,
    game: input.game,
    finished: input.finished ? { ...input.finished, ended_reason: "won" } : null,
  });
}

type PlayRow = { seq: number; segment: number; user_id: string; kind: string; card: string | null };

// Performs one action. Returns null when done, or the refusal's message.
async function perform(action: ComputerAction, input: ComputerDriverInput): Promise<string | null> {
  const { trackAction } = input;
  const level = input.level as ComputerLevel;
  const computerId = input.computerId as string;
  const game = input.game;

  const call = async (fn: string, args: Record<string, unknown>) => {
    const { error } = await trackAction(supabase.rpc(fn, args));
    return error ? error.message : null;
  };
  // The computer's hand, or the real reason it couldn't be read (a guard
  // refusal, a network error) -- never hidden behind a "moved on" message.
  const computerHand = async (gameId: string): Promise<{ cards: string[] } | { error: string }> => {
    const { data, error } = await trackAction(supabase.rpc("computer_hand", { p_game_id: gameId }));
    if (error) return { error: `computer_hand: ${error.message}` };
    const row = (data as { user_id: string; cards: string[] }[] | null)?.[0];
    return row?.cards ? { cards: row.cards } : { error: "computer_hand: no hand for the computer in this game" };
  };

  switch (action.kind) {
    case "rematch":
      return call("computer_start_game_with_deal", { p_table_id: input.tableId });

    case "draw":
      return game ? call("computer_draw_cut_card", { p_game_id: game.id }) : "no game";

    case "ack":
      return game ? call("computer_acknowledge_deal_cut", { p_game_id: game.id }) : "no game";

    case "discard": {
      if (!game) return "no game";
      const read = await computerHand(game.id);
      if ("error" in read) return read.error;
      // Not six cards: the discard already happened (the game moved on).
      if (read.cards.length !== 6) return "already: the computer's hand is not the six dealt";
      const cards = decideDiscard({ hand: read.cards, isDealer: game.dealer_id === computerId, level });
      return call("computer_discard_to_crib", { p_game_id: game.id, p_cards: cards });
    }

    case "play": {
      if (!game) return "no game";
      // Everything from fresh reads, so the segment, the count and whose turn
      // it is all describe the same moment.
      const [{ data: row }, { data: playRows }, read] = await Promise.all([
        trackAction(
          supabase
            .from("games")
            .select("status, phase, current_player, play_count, play_segment, starter_card")
            .eq("id", game.id)
            .maybeSingle()
        ),
        trackAction(
          supabase
            .from("game_plays")
            .select("seq, segment, user_id, kind, card")
            .eq("game_id", game.id)
            .order("seq", { ascending: true })
        ),
        computerHand(game.id),
      ]);
      if ("error" in read) return read.error;
      const hand = read.cards;
      if (
        !row ||
        row.status !== "active" ||
        row.phase !== "play" ||
        row.current_player !== computerId ||
        !row.starter_card
      ) {
        return "it is not your turn (state moved on)";
      }
      const plays = ((playRows as PlayRow[] | null) ?? []).filter((p) => p.kind === "play" && p.card);
      const allPlayed = plays.map((p) => p.card as string);
      const mine = new Set(plays.filter((p) => p.user_id === computerId).map((p) => p.card as string));
      const humanPlayed = new Set(plays.filter((p) => p.user_id !== computerId).map((p) => p.card as string));
      const segmentCards = plays.filter((p) => p.segment === row.play_segment).map((p) => p.card as string);
      const humanRemaining = input.humanHand.filter((c) => !humanPlayed.has(c));
      const card = decidePlay({
        myRemaining: hand.filter((c) => !mine.has(c)),
        starter: row.starter_card,
        segmentCards,
        count: row.play_count ?? 0,
        allPlayed,
        opponentCardCount:
          input.humanHand.length === 4 ? humanRemaining.length : Math.max(0, 4 - humanPlayed.size),
        level,
        // The brain reads this only when the level peeks.
        opponentRemaining: input.humanHand.length === 4 ? humanRemaining : undefined,
      });
      return call("computer_play_card", { p_game_id: game.id, p_card: card });
    }

    case "confirm": {
      if (!game || action.step == null) return "no game";
      if (action.crib) {
        const shown = await call("computer_show_crib", { p_game_id: game.id });
        if (shown) return shown;
      }
      return call("computer_confirm_count", { p_game_id: game.id, p_step: action.step });
    }

    case "next_hand":
      return game && action.handNo != null
        ? call("computer_next_hand", { p_game_id: game.id, p_hand_no: action.handNo })
        : "no game";
  }
}

export function useComputerDriver(input: ComputerDriverInput): void {
  // The latest input, for the timer and the async work (no stale closures).
  const inputRef = useRef(input);
  useEffect(() => {
    inputRef.current = input;
  });

  const inFlightRef = useRef<Set<string>>(new Set());
  const doneRef = useRef<Set<string>>(new Set());
  const triesRef = useRef<Map<string, number>>(new Map());
  const warnedRef = useRef<Set<string>>(new Set());
  const givenUpRef = useRef<Set<string>>(new Set());
  // Bumped to look again after a refusal (same key, after a back-off).
  const [retryTick, setRetryTick] = useState(0);

  const action = nextActionOf(input);
  const key = action?.key ?? null;

  useEffect(() => {
    if (!key || !action) return;
    if (inFlightRef.current.has(key) || doneRef.current.has(key)) return;
    const tries = triesRef.current.get(key) ?? 0;
    if (tries >= MAX_TRIES) {
      // Given up: start this key over in GIVE_UP_RETRY_MS, or when the tab
      // becomes visible again, whichever comes first.
      const revive = () => {
        triesRef.current.delete(key);
        setRetryTick((t) => t + 1);
      };
      const reviveTimer = window.setTimeout(revive, GIVE_UP_RETRY_MS);
      const onVisible = () => {
        if (document.visibilityState === "visible") revive();
      };
      document.addEventListener("visibilitychange", onVisible);
      return () => {
        window.clearTimeout(reviveTimer);
        document.removeEventListener("visibilitychange", onVisible);
      };
    }

    const backoff = tries === 0 ? 0 : 1000 * 2 ** tries; // 2, 4, 8, 16 s
    let cancelled = false;
    const timer = window.setTimeout(async () => {
      if (cancelled) return;
      // Re-compute from the latest state: act only if nothing moved.
      const latest = inputRef.current;
      const now = nextActionOf(latest);
      if (!now || now.key !== key || inFlightRef.current.has(key) || doneRef.current.has(key)) return;

      inFlightRef.current.add(key);
      let message: string | null;
      try {
        message = await perform(now, latest);
      } catch (e) {
        message = e instanceof Error ? e.message : String(e);
      }
      inFlightRef.current.delete(key);

      if (message === null) {
        doneRef.current.add(key);
        triesRef.current.delete(key);
      } else {
        const failed = (triesRef.current.get(key) ?? 0) + 1;
        triesRef.current.set(key, failed);
        const harmless = HARMLESS.some((h) => message.toLowerCase().includes(h));
        if (!harmless && !warnedRef.current.has(key)) {
          warnedRef.current.add(key);
          console.warn("[computer] action refused:", now.kind, key, message);
        }
        if (failed === MAX_TRIES && !givenUpRef.current.has(key)) {
          givenUpRef.current.add(key);
          console.warn(`[computer] giving up on ${now.kind} ${key}`);
        }
      }
      // Re-read either way, then look again.
      if (inputRef.current.enabled) await inputRef.current.refresh();
      if (message !== null) setRetryTick((t) => t + 1);
    }, backoff + thinkMs(action.kind));

    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
    // action is derived from the same input as key; the key names it.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, retryTick]);
}
