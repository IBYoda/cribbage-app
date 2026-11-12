"use client";

import { useDealAnimationOn, usePrefersReducedMotion } from "@/components/table/DealAnimation";

// Whether anything may move just for looks: the Settings page's animations setting
// and the system's reduced motion, both read live. Off on the first render,
// because the server can't know the second (usePrefersReducedMotion), so
// nothing starts moving and then stops.
export function useAmbientMotion(): boolean {
  const on = useDealAnimationOn();
  const reduced = usePrefersReducedMotion();
  return on && !reduced;
}
