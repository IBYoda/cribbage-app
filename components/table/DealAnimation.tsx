"use client";

import { useEffect, useLayoutEffect, useRef, useSyncExternalStore } from "react";
import { FaceDownCard, PlayingCard } from "@/components/PlayingCard";
import {
  DEAL_SPIN_DEG,
  dealLength,
  discardPlan,
  readDealAnimationOn,
  writeDealAnimationOn,
  type DealPlan,
  type DealStep,
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
// card just appears at the end.

// Where each seat's hand cards, deck and crib are, by screen position. Only
// the 2-player square table's seats (me at the bottom, the other player
// across the top) exist so far.
const HAND_SLOTS: Partial<Record<SeatPosition, string>> = {
  bottom: ".sq-hand-row > div > :not(.absolute)",
  top: ".sq-opp-hand > .sq-opp-card",
};
const DECK_SLOTS: Partial<Record<SeatPosition, string>> = {
  bottom: ".sq-piles > div > div:last-child > div",
  top: ".sq-across-pile--deck",
};
const CRIB_SLOTS: Partial<Record<SeatPosition, string>> = {
  bottom: ".sq-piles > div > div:first-child > div",
  top: ".sq-across-pile--crib",
};

const EASE_OUT = "cubic-bezier(0.2, 0.7, 0.3, 1)";
const EASE_IN_OUT = "cubic-bezier(0.45, 0, 0.25, 1)";

const move = (dx: number, dy: number, turn: number, scale: number) =>
  `translate(${dx}px, ${dy}px) rotate(${turn}deg) scale(${scale})`;
const AT_REST = move(0, 0, 0, 1);

// A card box placed over a measured rectangle (viewport px; the overlay is
// fixed at the viewport's corner).
function cardBox(layer: HTMLElement, to: DOMRect, z: number): HTMLElement {
  const box = document.createElement("div");
  Object.assign(box.style, {
    position: "absolute",
    left: `${to.left}px`,
    top: `${to.top}px`,
    width: `${to.width}px`,
    height: `${to.height}px`,
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
export function DealAnimation({
  plan,
  seats,
  dealer,
  faces,
  onDone,
}: {
  plan: DealPlan;
  // Each seat's place on my screen, by its index in the seat order.
  seats: (SeatPosition | null)[];
  dealer: SeatPosition;
  // My dealt cards, in my hand's order: the fan's face-up sides.
  faces: string[];
  // Over: finished, skipped (a tap) or cut short (a resize).
  onDone: () => void;
}) {
  const layerRef = useRef<HTMLDivElement>(null);
  const finishRef = useRunOnce(
    layerRef,
    (layer, table) => {
      const back = template(layer, "back");
      const query = (selector: string | undefined) => (selector ? table.querySelector(selector) : null);
      const deck = query(DECK_SLOTS[dealer])?.getBoundingClientRect() ?? null;
      const slotsOf = (seat: SeatPosition | null) => {
        const selector = seat ? HAND_SLOTS[seat] : undefined;
        return selector ? [...table.querySelectorAll(selector)] : [];
      };
      const slotFor = (step: DealStep): Element | null =>
        step.target === "crib" ? query(CRIB_SLOTS[dealer]) : (slotsOf(seats[step.target])[step.cardIndex] ?? null);

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
          const to = slot.getBoundingClientRect();
          if (to.width === 0) continue;
          const z = Number.parseInt(getComputedStyle(slot).zIndex, 10);
          const fromDx = deck.left + deck.width / 2 - (to.left + to.width / 2);
          const fromDy = deck.top + deck.height / 2 - (to.top + to.height / 2);
          const from = move(fromDx, fromDy, -DEAL_SPIN_DEG, deck.width / to.width);
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
                  { transform: AT_REST, opacity: 1 },
                ],
                { delay: step.delayMs, duration: step.durationMs, fill: "both" }
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
          const stackDx = stackCentre.x - (to.left + to.width / 2) + step.cardIndex * 0.6;
          const stackDy = stackCentre.y - (to.top + to.height / 2) - step.cardIndex * 0.9;
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
                { transform: AT_REST, opacity: 1, offset: 1 },
              ],
              { delay: step.delayMs, duration: length, fill: "both" }
            )
          );
          animations.push(
            inner.animate([{ transform: "rotateY(0deg)" }, { transform: "rotateY(180deg)" }], {
              delay: fan.delayMs,
              duration: fan.durationMs,
              easing: EASE_IN_OUT,
              fill: "both",
            })
          );
        }
      }
      return {
        lengthMs: plan.totalMs,
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
      const cribSelector = CRIB_SLOTS[dealer];
      const crib = cribSelector ? table.querySelector(cribSelector)?.getBoundingClientRect() : null;
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
            const from = source.getBoundingClientRect();
            if (from.width === 0) continue;
            const dx = from.left + from.width / 2 - (crib.left + crib.width / 2);
            const dy = from.top + from.height / 2 - (crib.top + crib.height / 2);
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
                    { transform: move(dx, dy, 0, from.width / crib.width), easing: EASE_OUT },
                    { transform: AT_REST },
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
              animations.push(
                box.animate(
                  [
                    { transform: move(dx, dy, -DEAL_SPIN_DEG, from.width / crib.width), opacity: 0 },
                    { transform: move(dx, dy, -DEAL_SPIN_DEG, from.width / crib.width), opacity: 1, offset: 0.02, easing: EASE_OUT },
                    { transform: AT_REST, opacity: 1 },
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
