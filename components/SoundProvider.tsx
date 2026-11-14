"use client";

import { useEffect, useSyncExternalStore } from "react";
import {
  BURST_WINDOW_MS,
  CARD_FADE_IN_S,
  DEFAULT_SOUND_VOLUME,
  audioRepair,
  clipTiming,
  cueAllowed,
  pickBurst,
  readSoundOn,
  readSoundVolume,
  writeSoundOn,
  writeSoundVolume,
  type SoundCue,
} from "@/lib/sounds";

// THE SOUND PLAYER: one AudioContext for the whole app, in this module so it
// outlives a page change. The Web Audio API, not <audio>, because iOS ignores
// an <audio> element's volume: the volume here is a gain node. What plays and
// when is lib/sounds.ts and the table's triggers (useTableSounds).
//
// LOCKED UNTIL A TAP. A browser keeps audio silent until the player has touched
// the page, so <SoundProvider> (app/layout.tsx) listens for any tap or key, and
// resumes the context then. It also tries when the tab comes back, since iOS
// can leave it "interrupted" after a call or the background.
//
// DROPPED, NEVER QUEUED. A sound that can't play now is gone: sound off, the
// context not running, the tab hidden, or its clip not loaded yet. A suspended
// context would otherwise hold them all and let them out together when it
// resumes.

let context: AudioContext | null = null;
let master: GainNode | null = null;

// A clip's journey: fetched when a table opens, decoded once there is a
// context. Fetching needs no tap, and making a context before one only earns
// a console warning.
const fetched = new Map<string, ArrayBuffer>();
const asked = new Set<string>();
const decoded = new Map<string, AudioBuffer>();

// What's playing, to stop it: everything on sound off, the deal on a skip.
const playing = new Set<{ source: AudioBufferSourceNode; url: string }>();

async function decodeFetched() {
  const ctx = context;
  if (!ctx) return;
  for (const [url, data] of [...fetched]) {
    // Out of the map first: decoding detaches the buffer.
    fetched.delete(url);
    try {
      decoded.set(url, await ctx.decodeAudioData(data));
    } catch {
      asked.delete(url); // A bad download: the next table tries again.
    }
  }
}

// Loads the clips not yet here. Never throws: a clip that fails just stays
// silent, and the next table tries it again.
export function prepareSounds(urls: string[]) {
  for (const url of urls) {
    if (asked.has(url)) continue;
    asked.add(url);
    fetch(url)
      .then((response) => {
        if (!response.ok) throw new Error(response.statusText);
        return response.arrayBuffer();
      })
      .then((data) => {
        fetched.set(url, data);
        return decodeFetched();
      })
      .catch(() => asked.delete(url));
  }
}

// Mixes with a phone or Zoom call instead of taking the audio over (Safari
// 16.4 and later; nothing elsewhere).
function mixWithOtherAudio() {
  try {
    const session = (navigator as Navigator & { audioSession?: { type: string } }).audioSession;
    if (session) session.type = "ambient";
  } catch {
    // Not supported: the sounds play, and the system decides.
  }
}

// Makes the context if there isn't one, and resumes it. Call it from a tap.
function unlockAudio(): Promise<void> {
  if (typeof window === "undefined") return Promise.resolve();
  if (audioRepair(context?.state ?? null) === "make") {
    mixWithOtherAudio();
    const Context =
      window.AudioContext ?? (window as Window & { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Context) return Promise.resolve();
    context = new Context();
    master = context.createGain();
    master.gain.value = readSoundVolume();
    master.connect(context.destination);
    void decodeFetched();
  }
  if (!context || audioRepair(context.state) !== "resume") return Promise.resolve();
  return context.resume().catch(() => {});
}

const running = (ctx: AudioContext | null): ctx is AudioContext => ctx?.state === "running";

// Whether a cue played now would be heard (cueAllowed, lib/sounds.ts). Decided
// again as it starts.
export function canPlayNow(urls: string[] = []): boolean {
  return cueAllowed({
    hidden: typeof document === "undefined" || document.hidden,
    on: readSoundOn(),
    contextState: context?.state ?? null,
    loaded: urls.every((url) => decoded.has(url)),
  });
}

// offset: seconds into the clip (the card's tick, clipTiming). Played to its
// end either way; a start mid-clip fades in over CARD_FADE_IN_S so it can't
// click, through a gain of its own, so a quick second card is its own source
// and fade and never cuts the first.
function startClip(ctx: AudioContext, url: string, at: number, offset = 0) {
  const buffer = decoded.get(url);
  if (!buffer || !master) return;
  const source = ctx.createBufferSource();
  source.buffer = buffer;
  let fade: GainNode | null = null;
  if (offset > 0) {
    fade = ctx.createGain();
    fade.gain.setValueAtTime(0, at);
    fade.gain.linearRampToValueAtTime(1, at + CARD_FADE_IN_S);
    source.connect(fade);
    fade.connect(master);
  } else {
    source.connect(master);
  }
  const entry = { source, url };
  playing.add(entry);
  source.onended = () => {
    source.disconnect();
    fade?.disconnect();
    playing.delete(entry);
  };
  source.start(at, Math.min(offset, buffer.duration));
}

// A cue's steps, together: one after the other, or a set gap apart. A card
// cue is moved as a whole so its first tick meets the first card landing
// (clipTiming); the gap keeps the rest with theirs. elapsedMs: how long the
// cue waited for its burst, already gone from its landInMs.
function startCue(cue: SoundCue, elapsedMs = 0) {
  const urls = cue.steps.map((s) => s.url);
  if (!canPlayNow(urls) || !context || !master) return;
  master.gain.value = readSoundVolume();
  const first = cue.steps[0];
  const { delayS, offsetS } =
    first?.event === "card"
      ? clipTiming(first.url, ((cue.landInMs ?? 0) - elapsedMs) / 1000)
      : { delayS: 0, offsetS: 0 };
  let at = context.currentTime + delayS;
  for (const { url, event } of cue.steps) {
    startClip(context, url, at, event === "card" ? offsetS : 0);
    at += cue.gapMs === null ? (decoded.get(url)?.duration ?? 0) : cue.gapMs / 1000;
  }
}

// THE BURST: cues landing together wait out a moment, then only the winner
// plays (pickBurst). Each remembers when it was asked for (landInMs counts
// from then).
let pending: SoundCue[] = [];
const askedAt = new WeakMap<SoundCue, number>();
let burstTimer: number | null = null;

export function playCue(cue: SoundCue) {
  pending.push(cue);
  askedAt.set(cue, performance.now());
  if (burstTimer !== null) return;
  burstTimer = window.setTimeout(() => {
    const winner = pickBurst(pending);
    pending = [];
    burstTimer = null;
    if (winner) startCue(winner, performance.now() - (askedAt.get(winner) ?? performance.now()));
  }, BURST_WINDOW_MS);
}

// Stops a clip that's playing, wherever it's got to: the deal, when the deal
// animation is skipped.
export function stopClip(url: string) {
  for (const { source, url: playingUrl } of playing) {
    if (playingUrl === url) stopSource(source);
  }
}

function stopSource(source: AudioBufferSourceNode) {
  try {
    source.stop();
  } catch {
    // Already over.
  }
}

// The Settings page's Test sound: at once, not through a burst. Called from the tap,
// which is also what unlocks audio. A first test may have to load the clip.
export async function playTestSound(url: string) {
  await unlockAudio();
  if (!decoded.has(url)) {
    const response = await fetch(url).catch(() => null);
    if (!response?.ok || !context) return;
    decoded.set(url, await context.decodeAudioData(await response.arrayBuffer()));
    asked.add(url);
  }
  if (running(context) && master) {
    master.gain.value = readSoundVolume();
    startClip(context, url, context.currentTime);
  }
}

// THE SETTINGS, read live: a change in another tab arrives as a storage event,
// one in this tab through setSoundOn / setSoundVolume (as Card animations).
const SOUND_SETTING_EVENT = "nobs:sound-change";

function subscribeSoundSetting(onChange: () => void) {
  window.addEventListener("storage", onChange);
  window.addEventListener(SOUND_SETTING_EVENT, onChange);
  return () => {
    window.removeEventListener("storage", onChange);
    window.removeEventListener(SOUND_SETTING_EVENT, onChange);
  };
}

export function useSoundOn(): boolean {
  return useSyncExternalStore(subscribeSoundSetting, readSoundOn, () => true);
}

export function useSoundVolume(): number {
  return useSyncExternalStore(subscribeSoundSetting, readSoundVolume, () => DEFAULT_SOUND_VOLUME);
}

// Off stops what's playing too. On comes from a tap, so it can unlock.
export function setSoundOn(on: boolean) {
  writeSoundOn(on);
  if (on) void unlockAudio();
  else for (const { source } of playing) stopSource(source);
  window.dispatchEvent(new Event(SOUND_SETTING_EVENT));
}

export function setSoundVolume(volume: number) {
  writeSoundVolume(volume);
  if (master) master.gain.value = readSoundVolume();
  window.dispatchEvent(new Event(SOUND_SETTING_EVENT));
}

// Renders nothing. Mounted once, in app/layout.tsx, so the first tap anywhere
// unlocks audio, and a tap on the way to a table still counts there. Stays on
// after that: iOS can suspend the context again. The capture phase, so a
// control that stops a tap can't hide it. Sound off: nothing is made, until
// the switch's own tap turns it on. click as well as pointerup, because not
// every browser counts a pointerup as the tap that unlocks audio.
export function SoundProvider() {
  useEffect(() => {
    const onTap = () => {
      if (readSoundOn()) void unlockAudio();
    };
    const onVisible = () => {
      if (!document.hidden && context && readSoundOn()) void unlockAudio();
    };
    const capture = { capture: true };
    window.addEventListener("pointerup", onTap, capture);
    window.addEventListener("keydown", onTap, capture);
    window.addEventListener("click", onTap, capture);
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      window.removeEventListener("pointerup", onTap, capture);
      window.removeEventListener("keydown", onTap, capture);
      window.removeEventListener("click", onTap, capture);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, []);
  return null;
}
