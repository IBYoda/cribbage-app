"use client";

import { useEffect, useLayoutEffect, useRef, useSyncExternalStore } from "react";
import { FaceDownCard, PlayingCard } from "@/components/PlayingCard";
import {
  dealLength,
  discardPlan,
  discardShowStep,
  flightTurn,
  readDealAnimationOn,
  readDiscardShown,
  STARTER_SLIDE_MS,
  writeDealAnimationOn,
  writeDiscardShown,
  type DealPlan,
  type DealStep,
  type DiscardShow,
} from "@/lib/dealAnimation";
import type { SeatPosition } from "@/lib/tableLayout";

// THE CARD ANIMATIONS' OVERLAYS (PRD item 31), over the square table: the
// deal (DealAnimation) and a discard thrown to the crib (DiscardToss). Both
// run a plan from lib/dealAnimation.ts, with every place measured from the
// DOM when they start -- the real slots, hidden meanwhile -- so each flying
// card ends exactly where, and as big as, the card it stands for.
//
// transform and opacity only (the Web Animations API), will-change dropped
// as each card finishes, nothing left in the DOM afterwards. Must be
// rendered inside the square table's shell (SquareTableShell's overlay): the
// slots are found there, and the card back comes from its data-back. A slot
// that can't be found (a seat whose layout isn't built yet) is skipped: that
// card just appears at the end. The side seats' cards (3 players) are
// sideways: a card flying to or from one turns to match (flightTurn).

// Where each seat's hand cards, deck and crib are, by screen position: me at
// the bottom, the across player at the top (2 players), the side seats
// (3 players: SquareRing.tsx). A side seat's slots are sized for a sideways
// card, which is drawn turned (TURN).
const HAND_SLOTS: Record<SeatPosition, string> = {
  bottom: ".sq-hand-row > div > :not(.absolute)",
  top: ".sq-opp-hand > .sq-opp-card",
  left: '[data-seat="left"] [data-hand-stack] > .sq-side__slot',
  right: '[data-seat="right"] [data-hand-stack] > .sq-side__slot',
};
const DECK_SLOTS: Record<SeatPosition, string> = {
  bottom: ".sq-piles > div > div:last-child > div",
  top: ".sq-across-pile--deck",
  left: '[data-seat="left"] [data-pile="deck"] .sq-side__slot',
  right: '[data-seat="right"] [data-pile="deck"] .sq-side__slot',
};
const CRIB_SLOTS: Record<SeatPosition, string> = {
  bottom: ".sq-piles > div > div:first-child > div",
  top: ".sq-across-pile--crib",
  left: '[data-seat="left"] [data-pile="crib"] .sq-side__slot',
  right: '[data-seat="right"] [data-pile="crib"] .sq-side__slot',
};
// How a seat's cards are turned on screen (seatGeometry's rotation for the
// side seats; the across player's backs are drawn upright).
const TURN: Record<SeatPosition, number> = { bottom: 0, top: 0, left: 90, right: -90 };

// A card's place: its centre, its own width and height (a sideways card's
// slot is as wide as the card is tall), and its turn.
type CardPlace = { x: number; y: number; w: number; h: number; turn: number };

function placeOf(el: Element, turn: number): CardPlace {
  const r = el.getBoundingClientRect();
  const sideways = turn === 90 || turn === -90;
  return {
    x: r.left + r.width / 2,
    y: r.top + r.height / 2,
    w: sideways ? r.height : r.width,
    h: sideways ? r.width : r.height,
    turn,
  };
}

const EASE_OUT = "cubic-bezier(0.2, 0.7, 0.3, 1)";
const EASE_IN_OUT = "cubic-bezier(0.45, 0, 0.25, 1)";

const move = (dx: number, dy: number, turn: number, scale: number) =>
  `translate(${dx}px, ${dy}px) rotate(${turn}deg) scale(${scale})`;
const atRestOn = (place: CardPlace) => move(0, 0, place.turn, 1);
// The keyframe a card flies from: at `from`, turned `turn`, at from's size.
const leaving = (from: CardPlace, to: CardPlace, turn: number) =>
  move(from.x - to.x, from.y - to.y, turn, from.w / to.w);

// A card box placed at a card's place, upright (viewport px; the overlay is
// fixed at the viewport's corner). Its keyframes turn it (AT_REST_ON).
function cardBox(layer: HTMLElement, to: CardPlace, z: number): HTMLElement {
  const box = document.createElement("div");
  Object.assign(box.style, {
    position: "absolute",
    left: `${to.x - to.w / 2}px`,
    top: `${to.y - to.h / 2}px`,
    width: `${to.w}px`,
    height: `${to.h}px`,
    zIndex: String(z),
    willChange: "transform, opacity",
  });
  layer.appendChild(box);
  return box;
}

// A two-sided card that can turn over (as FlipCard): `first` shows, `second`
// is on its back; turning the returned inner element rotateY(180deg) shows
// `second`.
function twoSided(box: HTMLElement, first: Element, second: Element): HTMLElement {
  box.style.perspective = "900px";
  const inner = document.createElement("div");
  Object.assign(inner.style, { position: "relative", width: "100%", height: "100%", transformStyle: "preserve-3d" });
  for (const [face, turned] of [
    [first, false],
    [second, true],
  ] as const) {
    const side = document.createElement("div");
    Object.assign(side.style, {
      position: "absolute",
      inset: "0",
      display: "flex",
      backfaceVisibility: "hidden",
      transform: turned ? "rotateY(180deg)" : "none",
    });
    side.appendChild(face.cloneNode(true));
    inner.appendChild(side);
  }
  box.appendChild(inner);
  return inner;
}

// The hidden pieces the flying cards are cloned from: the player's card back
// and the face cards needed.
function Templates({ faces }: { faces: string[] }) {
  return (
    <div hidden>
      <div data-template="back">
        <FaceDownCard sizing="h-full w-full" />
      </div>
      {faces.map((card, i) => (
        <div key={`${card}-${i}`} data-template={`face-${i}`}>
          <PlayingCard card={card} sizing="h-full w-full" />
        </div>
      ))}
    </div>
  );
}

const template = (layer: HTMLElement, name: string) =>
  layer.querySelector(`[data-template="${name}"]`)?.firstElementChild ?? null;

// Runs once, before the first paint; ends by the clock (not the animations'
// own events, which a hidden tab may hold back) or a resize.
function useRunOnce(
  layerRef: React.RefObject<HTMLDivElement | null>,
  run: (layer: HTMLElement, table: Element) => { lengthMs: number; cleanup: () => void },
  onEnd: () => void,
  endOnResize: boolean
) {
  const onEndRef = useRef(onEnd);
  useEffect(() => {
    onEndRef.current = onEnd;
  });
  const finishRef = useRef<() => void>(() => {});
  useLayoutEffect(() => {
    const layer = layerRef.current;
    const table = layer?.closest(".table-shell");
    let over = false;
    const finish = () => {
      if (over) return;
      over = true;
      onEndRef.current();
    };
    finishRef.current = finish;
    if (!layer || !table) {
      finish();
      return;
    }
    const { lengthMs, cleanup } = run(layer, table);
    const timer = window.setTimeout(finish, lengthMs + 60);
    if (endOnResize) window.addEventListener("resize", finish);
    return () => {
      over = true;
      window.clearTimeout(timer);
      window.removeEventListener("resize", finish);
      cleanup();
    };
    // Runs once, with what it had when it started.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  return finishRef;
}

// THE DEAL. Every card flies face-down from the dealer's deck, making a half
// turn in the plane. The other seats' cards land in their places; mine land
// in a small stack in the middle of my hand, then (the fan) spread into my
// places, turning face-up. Landed cards stay until it is all over; then the
// overlay goes and the real cards show. A tap anywhere skips to the end; a
// resize cuts it short (the measured places are stale).
//
// onStart: called as it starts (never during render); its answer holds every
// card that long first, so the shuffle plays before the first card leaves and
// the deal sound runs with the cards. Nothing to play, nothing held.
export function DealAnimation({
  plan,
  seats,
  dealer,
  faces,
  onStart,
  onDone,
}: {
  plan: DealPlan;
  // Each seat's place on my screen, by its index in the seat order.
  seats: (SeatPosition | null)[];
  dealer: SeatPosition;
  // My dealt cards, in my hand's order: the fan's face-up sides.
  faces: string[];
  onStart?: () => number;
  // Over: finished, skipped (a tap) or cut short (a resize).
  onDone: () => void;
}) {
  const layerRef = useRef<HTMLDivElement>(null);
  const finishRef = useRunOnce(
    layerRef,
    (layer, table) => {
      const leadInMs = onStart?.() ?? 0;
      const back = template(layer, "back");
      const query = (selector: string | undefined) => (selector ? table.querySelector(selector) : null);
      const deckSlot = query(DECK_SLOTS[dealer]);
      const deck = deckSlot ? placeOf(deckSlot, TURN[dealer]) : null;
      const slotsOf = (seat: SeatPosition | null) => {
        const selector = seat ? HAND_SLOTS[seat] : undefined;
        return selector ? [...table.querySelectorAll(selector)] : [];
      };
      const slotFor = (step: DealStep): Element | null =>
        step.target === "crib" ? query(CRIB_SLOTS[dealer]) : (slotsOf(seats[step.target])[step.cardIndex] ?? null);
      const turnFor = (step: DealStep) => {
        const seat = step.target === "crib" ? dealer : seats[step.target];
        return seat ? TURN[seat] : 0;
      };

      // The stack: the middle of the stack seat's row of places.
      const stackSlots = plan.deal.some((s) => s.stack)
        ? slotsOf(seats[plan.deal.find((s) => s.stack)!.target as number]).map((s) => s.getBoundingClientRect())
        : [];
      const stackCentre =
        stackSlots.length > 0
          ? {
              x: (stackSlots[0].left + stackSlots[stackSlots.length - 1].right) / 2,
              y: stackSlots[0].top + stackSlots[0].height / 2,
            }
          : null;

      const boxes: HTMLElement[] = [];
      const animations: Animation[] = [];
      const done = (box: HTMLElement) => (a: Animation) => {
        animations.push(a);
        a.finished.then(
          () => {
            box.style.willChange = "auto";
          },
          () => {}
        );
      };
      if (deck && back) {
        for (const step of plan.deal) {
          const slot = slotFor(step);
          if (!slot) continue;
          const to = placeOf(slot, turnFor(step));
          if (to.w === 0) continue;
          const z = Number.parseInt(getComputedStyle(slot).zIndex, 10);
          // From the deck, lined up with it, making a half turn (and a
          // quarter more between an upright and a sideways place).
          const from = leaving(deck, to, flightTurn(deck.turn, to.turn));
          const fan = step.stack ? plan.fan.find((f) => f.cardIndex === step.cardIndex) : undefined;

          if (!fan || !stackCentre) {
            // Straight to its place.
            const box = cardBox(layer, to, Number.isFinite(z) ? z : 0);
            box.appendChild(back.cloneNode(true));
            boxes.push(box);
            done(box)(
              box.animate(
                [
                  { transform: from, opacity: 0 },
                  { transform: from, opacity: 1, offset: 0.02, easing: EASE_OUT },
                  { transform: atRestOn(to), opacity: 1 },
                ],
                { delay: leadInMs + step.delayMs, duration: step.durationMs, fill: "both" }
              )
            );
            continue;
          }

          // Into the stack (a little offset per card, for depth), then out
          // to its place in the fan, turning face-up.
          const face = template(layer, `face-${step.cardIndex}`) ?? back;
          const box = cardBox(layer, to, 100 + step.cardIndex);
          const inner = twoSided(box, back, face);
          boxes.push(box);
          const stackDx = stackCentre.x - to.x + step.cardIndex * 0.6;
          const stackDy = stackCentre.y - to.y - step.cardIndex * 0.9;
          const inStack = move(stackDx, stackDy, 0, 1);
          const length = fan.delayMs + fan.durationMs - step.delayMs;
          const at = (ms: number) => Math.min(Math.max(ms / length, 0), 1);
          done(box)(
            box.animate(
              [
                { transform: from, opacity: 0, offset: 0 },
                { transform: from, opacity: 1, offset: at(step.durationMs * 0.02), easing: EASE_OUT },
                { transform: inStack, opacity: 1, offset: at(step.durationMs) },
                { transform: inStack, opacity: 1, offset: at(fan.delayMs - step.delayMs), easing: EASE_IN_OUT },
                { transform: atRestOn(to), opacity: 1, offset: 1 },
              ],
              { delay: leadInMs + step.delayMs, duration: length, fill: "both" }
            )
          );
          animations.push(
            inner.animate([{ transform: "rotateY(0deg)" }, { transform: "rotateY(180deg)" }], {
              delay: leadInMs + fan.delayMs,
              duration: fan.durationMs,
              easing: EASE_IN_OUT,
              fill: "both",
            })
          );
        }
      }
      return {
        lengthMs: leadInMs + plan.totalMs,
        cleanup: () => {
          for (const a of animations) a.cancel();
          for (const box of boxes) box.remove();
        },
      };
    },
    onDone,
    true
  );

  return (
    <div
      ref={layerRef}
      className="deal-overlay"
      aria-hidden="true"
      data-deal-overlay=""
      onPointerDown={() => finishRef.current()}
    >
      <Templates faces={faces} />
    </div>
  );
}

// A DISCARD THROWN TO THE CRIB, for each seat given: its cards fly from its
// hand to the dealer's crib pile (discardPlan's order and stagger). Mine are
// face-up and turn face-down as they go (from the cards I picked, hidden
// meanwhile); anyone else's are face-down and make a half turn in the plane.
// Short, so no skip: taps pass straight through it.
export type TossSeat = {
  key: string;
  position: SeatPosition;
  cards: number;
  // Mine: the cards thrown, and where they are in my hand row.
  faces?: string[];
  fromSlots?: number[];
};

export function DiscardToss({
  seats,
  dealer,
  onDone,
}: {
  seats: TossSeat[];
  dealer: SeatPosition;
  onDone: () => void;
}) {
  const layerRef = useRef<HTMLDivElement>(null);
  const allFaces = seats.flatMap((s) => s.faces ?? []);
  useRunOnce(
    layerRef,
    (layer, table) => {
      const back = template(layer, "back");
      const cribSlot = table.querySelector(CRIB_SLOTS[dealer]);
      const crib = cribSlot ? placeOf(cribSlot, TURN[dealer]) : null;
      const plan = discardPlan(seats.map((s) => ({ seat: s.key, cards: s.cards })));
      const boxes: HTMLElement[] = [];
      const animations: Animation[] = [];
      const hidden: HTMLElement[] = [];
      if (crib && back) {
        let faceIndex = 0;
        for (const seat of seats) {
          const selector = HAND_SLOTS[seat.position];
          const slots = selector ? [...table.querySelectorAll<HTMLElement>(selector)] : [];
          for (const step of plan.filter((s) => s.seat === seat.key)) {
            // Mine: the card I picked (hidden until the toss is over). Anyone
            // else's: from their hand, which already shows the cards left.
            const source = seat.fromSlots
              ? slots[seat.fromSlots[step.cardIndex]]
              : slots[Math.min(step.cardIndex, slots.length - 1)];
            if (!source) continue;
            const from = placeOf(source, TURN[seat.position]);
            if (from.w === 0) continue;
            const box = cardBox(layer, crib, 10 + boxes.length);
            boxes.push(box);
            const face = seat.faces ? template(layer, `face-${faceIndex++}`) : null;
            const timing = { delay: step.delayMs, duration: step.durationMs, fill: "both" as const };
            if (face) {
              source.style.visibility = "hidden";
              hidden.push(source);
              const inner = twoSided(box, face, back);
              animations.push(
                box.animate(
                  [
                    // Upright in my hand; turned as the crib is when it lands.
                    { transform: leaving(from, crib, 0), easing: EASE_OUT },
                    { transform: atRestOn(crib) },
                  ],
                  timing
                ),
                inner.animate([{ transform: "rotateY(0deg)" }, { transform: "rotateY(180deg)" }], {
                  ...timing,
                  easing: EASE_IN_OUT,
                })
              );
            } else {
              box.appendChild(back.cloneNode(true));
              const start = leaving(from, crib, flightTurn(from.turn, crib.turn));
              animations.push(
                box.animate(
                  [
                    { transform: start, opacity: 0 },
                    { transform: start, opacity: 1, offset: 0.02, easing: EASE_OUT },
                    { transform: atRestOn(crib), opacity: 1 },
                  ],
                  timing
                )
              );
            }
          }
        }
      }
      return {
        lengthMs: dealLength(plan),
        cleanup: () => {
          for (const a of animations) a.cancel();
          for (const box of boxes) box.remove();
          // A card still in my hand (the discard was refused) shows again.
          for (const el of hidden) el.style.visibility = "";
        },
      };
    },
    onDone,
    false
  );

  return (
    <div ref={layerRef} className="deal-overlay deal-overlay--pass" aria-hidden="true" data-toss-overlay="">
      <Templates faces={allFaces} />
    </div>
  );
}

// Before the deal can start: the slots are hidden, waiting for my dealt
// cards to arrive. If they don't within a few seconds (a lost read), give up
// on the animation so the table never stays empty.
// THE COMPUTER'S DISCARD, SHOWN ON TIME (lib/dealAnimation.ts): its clock.
// Renders nothing. Keeps `state` in step with the screen (discardShowStep)
// -- on a load, from what localStorage remembers for this hand -- and calls
// onShow(handKey) when the time is up. Its timer is cleared on any change
// and set again for the time left, so it is never stale.
export function ComputerDiscardClock({
  input,
  state,
  onState,
  onShow,
}: {
  input: Omit<Parameters<typeof discardShowStep>[0], "state" | "now" | "remembered">;
  state: DiscardShow;
  onState: (next: DiscardShow) => void;
  onShow: (handKey: string) => void;
}) {
  const latest = useRef({ onState, onShow });
  useLayoutEffect(() => {
    latest.current = { onState, onShow };
  });
  const { eligible, handKey, phase, handShown, dealInFlight, computerDiscarded, iDiscarding } = input;
  useLayoutEffect(() => {
    const waiting = eligible && !!handKey && phase === "discard" && !computerDiscarded;
    const remembered = waiting && readDiscardShown(handKey as string);
    // Nothing kept from another hand, nor once the real discard is in.
    if (eligible && !remembered) writeDiscardShown(null);
    const step = discardShowStep({
      eligible,
      handKey,
      phase,
      handShown,
      dealInFlight,
      computerDiscarded,
      iDiscarding,
      remembered,
      state,
      now: Date.now(),
    });
    if (step.state !== state) latest.current.onState(step.state);
    if (step.fireInMs === null || !handKey) return;
    const timer = window.setTimeout(() => latest.current.onShow(handKey), step.fireInMs);
    return () => window.clearTimeout(timer);
  }, [eligible, handKey, phase, handShown, dealInFlight, computerDiscarded, iDiscarding, state]);
  return null;
}

// THE STARTER IN COUNTING (countingStarterPlace, lib/tableLayout.ts): the
// starter, face-up and upright, in its counting place -- just above my hand
// when I deal, the middle of the table otherwise. slide: counting began on
// this screen just now (liveStarterStep), with the animations on -- it
// slides there from the dealer's deck (the empty box left there,
// data-starter-home, carries the deck's turn), turning upright, in
// STARTER_SLIDE_MS. Decided when it mounts; otherwise it is just there.
export function CountingStarter({ card, sizing, slide }: { card: string; sizing: string; slide: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const el = ref.current;
    const home = slide ? document.querySelector("[data-starter-home]") : null;
    if (!el || !home) return;
    const to = placeOf(el, 0);
    const from = placeOf(home, Number(home.getAttribute("data-starter-home")) || 0);
    if (to.w <= 0 || from.w <= 0) return;
    const run = el.animate([{ transform: leaving(from, to, from.turn) }, { transform: atRestOn(to) }], {
      duration: STARTER_SLIDE_MS,
      easing: EASE_IN_OUT,
    });
    return () => run.cancel();
  }, [slide]);
  return (
    <div ref={ref} data-counting-starter="">
      <PlayingCard card={card} sizing={sizing} />
    </div>
  );
}

export const DEAL_WAIT_MS = 5000;

export function DealStandby({ onGiveUp }: { onGiveUp: () => void }) {
  const onGiveUpRef = useRef(onGiveUp);
  useEffect(() => {
    onGiveUpRef.current = onGiveUp;
  });
  useEffect(() => {
    const timer = window.setTimeout(() => onGiveUpRef.current(), DEAL_WAIT_MS);
    return () => window.clearTimeout(timer);
  }, []);
  return null;
}

// THE TWO "DON'T ANIMATE" SWITCHES, read live.
//
// The Profile's "Card animations" setting (this device only; see
// lib/dealAnimation.ts). A change in another tab arrives as a storage event,
// one in this tab through setDealAnimationOn.
const DEAL_SETTING_EVENT = "nobs:deal-animation-change";

function subscribeDealSetting(onChange: () => void) {
  window.addEventListener("storage", onChange);
  window.addEventListener(DEAL_SETTING_EVENT, onChange);
  return () => {
    window.removeEventListener("storage", onChange);
    window.removeEventListener(DEAL_SETTING_EVENT, onChange);
  };
}

export function useDealAnimationOn(): boolean {
  return useSyncExternalStore(subscribeDealSetting, readDealAnimationOn, () => true);
}

export function setDealAnimationOn(on: boolean) {
  writeDealAnimationOn(on);
  window.dispatchEvent(new Event(DEAL_SETTING_EVENT));
}

// The system's reduced-motion setting.
const REDUCED_MOTION = "(prefers-reduced-motion: reduce)";

function subscribeReducedMotion(onChange: () => void) {
  const query = window.matchMedia(REDUCED_MOTION);
  query.addEventListener("change", onChange);
  return () => query.removeEventListener("change", onChange);
}

export function usePrefersReducedMotion(): boolean {
  return useSyncExternalStore(
    subscribeReducedMotion,
    () => window.matchMedia(REDUCED_MOTION).matches,
    () => true
  );
}
