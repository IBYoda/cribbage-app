"use client";

import { useEffect, useState } from "react";
import { NICKNAME_MAX_LENGTH } from "@/lib/nickname";
import {
  BLOCK_EMPTY_TEXT,
  BLOCK_ENTER_NAME_TEXT,
  BLOCK_LIST_FAILED_TEXT,
  blockMessage,
  readMyBlocks,
  unblockMessage,
  writeBlock,
  writeUnblock,
  type BlockedPlayer,
} from "@/lib/blocks";

// BLOCKED PLAYERS (moderation M1), on the Profile page under the stats: the
// signed-in player's own Block List, newest first, each with Unblock, and a
// box to add someone by their EXACT nickname. Everything goes through
// lib/blocks.ts (block_player, unblock_player, get_my_blocks); the answer
// after Block says only whether it worked, never anything about the person.
// Its own form, outside the profile form, so nothing here submits that one.
export function BlockedPlayers() {
  const [list, setList] = useState<BlockedPlayer[] | null>(null);
  const [listFailed, setListFailed] = useState(false);
  const [name, setName] = useState("");
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<{ ok: boolean; text: string } | null>(null);

  async function reload() {
    const read = await readMyBlocks();
    if (read.ok) {
      setList(read.data);
      setListFailed(false);
    } else {
      setListFailed(true);
    }
  }

  useEffect(() => {
    let cancelled = false;
    readMyBlocks().then((read) => {
      if (cancelled) return;
      if (read.ok) setList(read.data);
      else setListFailed(true);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  async function handleBlock(e: React.FormEvent) {
    e.preventDefault();
    if (busy) return;
    const typed = name.trim();
    if (!typed) {
      setNote({ ok: false, text: BLOCK_ENTER_NAME_TEXT });
      return;
    }
    setBusy(true);
    setNote(null);
    const outcome = await writeBlock(typed);
    const shown = blockMessage(outcome);
    setNote(shown);
    if (outcome === "blocked") {
      setName("");
      await reload();
    }
    setBusy(false);
  }

  async function handleUnblock(player: BlockedPlayer) {
    if (busy) return;
    setBusy(true);
    setNote(null);
    const outcome = await writeUnblock(player.userId);
    setNote(unblockMessage(outcome));
    if (outcome === "unblocked" || outcome === "not_blocked") await reload();
    setBusy(false);
  }

  return (
    <section className="felt-panel flex w-full flex-col gap-3" aria-labelledby="blocked-players">
      <h2 id="blocked-players" className="font-display text-2xl font-bold italic">
        Blocked players
      </h2>
      <p className="text-sm">People you block can&apos;t join or watch the tables you start.</p>

      {list === null ? (
        <p role="status" className="text-sm">
          {listFailed ? BLOCK_LIST_FAILED_TEXT : "Loading your Block List..."}
        </p>
      ) : list.length === 0 ? (
        <p className="text-sm">{BLOCK_EMPTY_TEXT}</p>
      ) : (
        <ul className="flex flex-col gap-2" aria-label="Your Block List">
          {list.map((player) => (
            <li key={player.userId} className="leaderboard-card">
              <div className="flex min-w-0 items-center gap-3">
                <span className="block min-w-0 flex-1 truncate font-bold">{player.nickname}</span>
                <button
                  type="button"
                  onClick={() => handleUnblock(player)}
                  disabled={busy}
                  className="peg-btn peg-btn--brass peg-btn--small shrink-0 disabled:opacity-60"
                  aria-label={`Unblock ${player.nickname}`}
                >
                  Unblock
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}

      <form onSubmit={handleBlock} className="flex flex-col gap-2">
        <label htmlFor="block-nickname" className="text-sm font-medium">
          Add by exact nickname
        </label>
        <div className="flex gap-2">
          <input
            id="block-nickname"
            type="text"
            autoComplete="off"
            maxLength={NICKNAME_MAX_LENGTH}
            value={name}
            onChange={(e) => setName(e.target.value)}
            className="felt-input min-w-0 flex-1"
          />
          <button type="submit" disabled={busy} className="peg-btn peg-btn--brass peg-btn--small shrink-0 disabled:opacity-60">
            {busy ? "..." : "Block"}
          </button>
        </div>
      </form>

      {note && (
        <p
          role={note.ok ? "status" : "alert"}
          className={note.ok ? "text-sm text-[var(--success-on-felt)]" : "text-sm text-[var(--error-on-felt)]"}
        >
          {note.text}
        </p>
      )}
    </section>
  );
}
