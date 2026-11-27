"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { Wordmark } from "@/components/brand/Wordmark";
import { SiteFooter } from "@/components/brand/SiteFooter";
import { PlayingCard } from "@/components/PlayingCard";
import {
  CribbageBoard,
  useBoardPattern,
  useBoardSkin,
  useCustomBoard,
  useTableBoardSkin,
} from "@/components/table/CribbageBoard";
import type { ScorePlate } from "@/components/table/ScoreStrip";
import { skinLane } from "@/lib/boardSkins";
import {
  TRAVEL_DEFAULT_NAMES,
  TRAVEL_NAME_MAX,
  addToEntry,
  clearEntry,
  keysLive,
  newGame,
  parseCalcTotal,
  parseTravelBoard,
  plateName,
  pressOk,
  redo,
  renamePlate,
  selectPlate,
  serializeTravelBoard,
  setPlayers,
  travelBoardKey,
  travelMessage,
  undo,
  visiblePlates,
  winnerLines,
  type TravelBoardState,
} from "@/lib/travelBoard";

// THE TRAVEL BOARD SCREEN (app/travel-board): the wordmark and a menu button;
// the board this player chose in Settings, one peg per plate; the plates (tap
// one to score for it); one shared keypad; Undo, Redo and New Game; a message
// line; Back home. The rules are all lib/travelBoard.ts -- this only draws
// them and saves the game on this device after every change.
//
// THE HAND CALCULATOR ROUND TRIP: the cards key goes to
// /calculator?from=travel-board (the game is already saved). Its "Use this
// score" comes back as /travel-board?calc=N, which is ADDED to the entry --
// never straight onto the board: OK still has to be tapped. ?calc is read and
// removed from the address in the same step that loads the game, and the
// result saved there too, so a reload (or React's second dev-mode effect)
// can't add it twice.
export function TravelBoard({ userId }: { userId: string }) {
  const router = useRouter();
  const key = travelBoardKey(userId);
  // Read once, as the screen first draws. The page only draws this after the
  // sign-in check, which runs in the browser, so it is never server-rendered.
  const [state, setState] = useState<TravelBoardState | null>(() => loadBoard(key));

  useEffect(() => {
    if (state) writeSaved(key, state);
  }, [key, state]);

  const pattern = useBoardPattern();
  const ownSkin = useBoardSkin();
  const custom = useCustomBoard();
  const players = state?.players ?? 2;
  const laneSkin = useTableBoardSkin(players);

  const dialogRef = useRef<HTMLDialogElement>(null);
  const [menuView, setMenuView] = useState<"menu" | "names" | "help">("menu");
  const [drafts, setDrafts] = useState<string[]>(["", "", "", ""]);

  if (!state) {
    return (
      <div className="card-room" data-scheme="dark">
        <main className="mx-auto flex w-full max-w-md flex-1 flex-col items-center justify-center px-4">
          <p>Loading...</p>
        </main>
        <SiteFooter />
      </div>
    );
  }

  const plates = visiblePlates(state);
  const lanes = players === 4 ? 4 : 3;
  const live = keysLive(state);
  const banner = winnerLines(state);
  const colorOf = (p: number) => skinLane(laneSkin, p).color;
  const boardPlayers = plates.map((p) => ({
    userId: `plate-${p}`,
    name: plateName(state, p),
    lane: p,
    score: state.scores[p],
    lastPoints: state.last[p],
  }));
  // A board drawn from the plates (the Beer Board) gets them as well; every
  // other board ignores them.
  const scorePlates: ScorePlate[] = plates.map((p) => ({
    key: `plate-${p}`,
    members: [{ userId: `plate-${p}`, name: plateName(state, p), avatarUrl: null }],
    score: state.scores[p],
    isMine: false,
    hasDealer: false,
    lastPoints: state.last[p],
    lastReason: null,
    lastAwardedAt: null,
    laneColor: colorOf(p),
  }));
  const tallBoard = custom?.layout === "mugs";

  const openMenu = () => {
    setMenuView("menu");
    dialogRef.current?.showModal();
  };
  const openNames = () => {
    setDrafts(plates.map((p) => state.names[p]));
    setMenuView("names");
  };
  // Leaving the names view (Done, Escape or the backdrop) keeps what was typed.
  const commitNames = () => {
    if (menuView !== "names") return;
    setState((s) => (s ? plates.reduce((acc, p) => renamePlate(acc, p, drafts[p] ?? ""), s) : s));
  };
  const closeMenu = () => dialogRef.current?.close();

  const openCalculator = () => {
    if (!live) return;
    writeSaved(key, state);
    router.push("/calculator?from=travel-board");
  };

  const plateCols = players === 3 ? "grid-cols-3" : "grid-cols-2";

  return (
    <div className="card-room" data-scheme="dark">
      <main className="mx-auto flex w-full max-w-md flex-1 flex-col gap-3 px-4 pb-4 pt-4">
        <header className="flex items-center justify-between gap-3">
          <Link href="/" aria-label="Nobs! home" className="rounded-lg">
            <Wordmark size="small" />
          </Link>
          <button
            type="button"
            onClick={openMenu}
            className="tb-menu-btn"
            aria-label="Travel Board menu"
            aria-haspopup="dialog"
          >
            <svg viewBox="0 0 24 24" className="h-6 w-6" aria-hidden="true">
              <path d="M4 7h16M4 12h16M4 17h16" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" />
            </svg>
          </button>
        </header>

        <div className={tallBoard ? "tb-board tb-board--tall" : "tb-board"}>
          <CribbageBoard skin={ownSkin} pattern={pattern} lanes={lanes} players={boardPlayers} plates={scorePlates} />
        </div>

        {banner && (
          <div role="status" className="tb-banner">
            <p className="font-display text-2xl font-bold">{banner.title}</p>
            {banner.skunks.map((line) => (
              <p key={line} className="text-sm font-semibold">
                {line}
              </p>
            ))}
          </div>
        )}

        <div role="group" aria-label="Scoring plates" className={`grid gap-2 ${plateCols}`}>
          {plates.map((p) => (
            <button
              key={p}
              type="button"
              onClick={() => setState((s) => (s ? selectPlate(s, p) : s))}
              aria-pressed={state.selected === p}
              className={players === 3 ? "tb-plate tb-plate--three" : "tb-plate"}
            >
              <span className="flex min-w-0 items-start gap-1.5">
                <span className="tb-dot" style={{ background: colorOf(p) }} aria-hidden="true" />
                <span className="tb-plate-name">{breakAfterSlash(plateName(state, p))}</span>
              </span>
              <span className="tb-plate-score">{state.scores[p]}</span>
            </button>
          ))}
        </div>

        <section className="tb-keypad" aria-label="Keypad">
          <output className="tb-entry" aria-live="polite" aria-label="Points to add">
            {state.entry}
          </output>
          <div className="grid grid-cols-3 justify-items-center gap-3">
            {[1, 2, 5].map((n) => (
              <button
                key={n}
                type="button"
                className="tb-key"
                aria-disabled={!live}
                onClick={() => setState((s) => (s ? addToEntry(s, n) : s))}
              >
                +{n}
              </button>
            ))}
            <button
              type="button"
              className="tb-key tb-key--cards"
              aria-disabled={!live}
              aria-label="Hand Calculator: count a hand"
              onClick={openCalculator}
            >
              <span className="tb-cards-icon" aria-hidden="true">
                <span className="tb-cards-icon__back">
                  <PlayingCard card="5H" sizing="h-full w-full" />
                </span>
                <span className="tb-cards-icon__front">
                  <PlayingCard card="JS" sizing="h-full w-full" />
                </span>
              </span>
            </button>
            <button
              type="button"
              className="tb-key"
              aria-disabled={!live}
              aria-label="Clear the entry"
              onClick={() => setState((s) => (s ? clearEntry(s) : s))}
            >
              C
            </button>
            <button
              type="button"
              className="tb-key tb-key--ok"
              aria-disabled={!live}
              onClick={() => setState((s) => (s ? pressOk(s) : s))}
            >
              OK
            </button>
          </div>
        </section>

        <div className="grid grid-cols-3 gap-2">
          <button
            type="button"
            className="peg-btn peg-btn--ghost peg-btn--small peg-btn--pair"
            disabled={state.undo.length === 0}
            onClick={() => setState((s) => (s ? undo(s) : s))}
          >
            Undo
          </button>
          <button
            type="button"
            className="peg-btn peg-btn--ghost peg-btn--small peg-btn--pair"
            disabled={state.redo.length === 0}
            onClick={() => setState((s) => (s ? redo(s) : s))}
          >
            Redo
          </button>
          <button
            type="button"
            className="peg-btn peg-btn--ghost peg-btn--small peg-btn--pair whitespace-nowrap"
            onClick={() => setState((s) => (s ? newGame(s) : s))}
          >
            New Game
          </button>
        </div>

        <p role="status" className="tb-message">
          {travelMessage(state)}
        </p>

        <Link href="/" className="peg-btn peg-btn--ghost mt-auto w-full">
          Back home
        </Link>
      </main>
      <SiteFooter />

      <dialog
        ref={dialogRef}
        className="about-dialog tb-dialog"
        aria-labelledby="tb-menu-title"
        onClose={commitNames}
        onClick={(e) => {
          if (e.target === dialogRef.current) closeMenu();
        }}
      >
        {menuView === "menu" && (
          <div className="flex flex-col gap-4">
            <h2 id="tb-menu-title" className="font-display text-2xl font-bold italic">
              Menu
            </h2>
            <div className="flex flex-col gap-2">
              <span id="tb-players-label" className="font-semibold">
                Players
              </span>
              <div role="group" aria-labelledby="tb-players-label" className="grid grid-cols-3 gap-2">
                {([2, 3, 4] as const).map((n) => (
                  <button
                    key={n}
                    type="button"
                    className="tb-seg"
                    aria-pressed={state.players === n}
                    onClick={() => setState((s) => (s ? setPlayers(s, n) : s))}
                  >
                    {n}
                  </button>
                ))}
              </div>
            </div>
            <button type="button" className="peg-btn peg-btn--ghost peg-btn--small" onClick={openNames}>
              Plate names
            </button>
            <button type="button" className="peg-btn peg-btn--ghost peg-btn--small" onClick={() => setMenuView("help")}>
              How to use
            </button>
            <button type="button" className="peg-btn peg-btn--brass" onClick={closeMenu} autoFocus>
              Close
            </button>
          </div>
        )}

        {menuView === "names" && (
          <form
            className="flex flex-col gap-3"
            onSubmit={(e) => {
              e.preventDefault();
              closeMenu();
            }}
          >
            <h2 id="tb-menu-title" className="font-display text-2xl font-bold italic">
              Plate names
            </h2>
            {plates.map((p) => (
              <label key={p} className="flex flex-col gap-1">
                <span className="flex items-center gap-1.5 text-sm font-semibold">
                  <span className="tb-dot" style={{ background: colorOf(p) }} aria-hidden="true" />
                  Plate {p + 1}
                </span>
                <input
                  type="text"
                  className="felt-input"
                  value={drafts[p] ?? ""}
                  maxLength={TRAVEL_NAME_MAX}
                  placeholder={TRAVEL_DEFAULT_NAMES[p]}
                  autoComplete="off"
                  onChange={(e) => {
                    const value = e.target.value;
                    setDrafts((d) => d.map((v, i) => (i === p ? value : v)));
                  }}
                />
              </label>
            ))}
            <button type="submit" className="peg-btn peg-btn--brass mt-1">
              Done
            </button>
          </form>
        )}

        {menuView === "help" && (
          <div className="flex flex-col gap-3">
            <h2 id="tb-menu-title" className="font-display text-2xl font-bold italic">
              How to use
            </h2>
            <ol className="flex list-decimal flex-col gap-1.5 pl-5">
              <li>Tap a plate.</li>
              <li>Enter points with +1, +2, +5 or the Hand Calculator.</li>
              <li>Tap OK to move the peg.</li>
            </ol>
            <p>C clears the entry. Undo steps back.</p>
            <button type="button" className="peg-btn peg-btn--brass mt-1" onClick={closeMenu} autoFocus>
              Close
            </button>
          </div>
        )}
      </dialog>
    </div>
  );
}

// The saved game, plus the Hand Calculator's ?calc=N if it came back with one
// -- added to the entry, removed from the address and saved straight away, so
// running this twice (React's dev mode does) adds it once.
function loadBoard(key: string): TravelBoardState | null {
  if (typeof window === "undefined") return null;
  let saved: string | null = null;
  try {
    saved = window.localStorage.getItem(key);
  } catch {
    saved = null;
  }
  let loaded = parseTravelBoard(saved);
  const params = new URLSearchParams(window.location.search);
  if (params.has("calc")) {
    const total = parseCalcTotal(params.get("calc"));
    if (total !== null) loaded = addToEntry(loaded, total);
    window.history.replaceState(null, "", window.location.pathname);
    writeSaved(key, loaded);
  }
  return loaded;
}

function writeSaved(key: string, state: TravelBoardState) {
  try {
    window.localStorage.setItem(key, serializeTravelBoard(state));
  } catch {
    // Private mode or storage full: the board still works, just unsaved.
  }
}

// "Player/Team 1" may wrap after its slash on a narrow plate, never mid-word.
function breakAfterSlash(name: string) {
  const parts = name.split("/");
  return parts.map((part, i) => (
    <span key={i}>
      {part}
      {i < parts.length - 1 && (
        <>
          /<wbr />
        </>
      )}
    </span>
  ));
}
