"use client";

import { useState } from "react";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { NICKNAME_MAX_LENGTH } from "@/lib/nickname";
import { saveNickname } from "@/lib/profileNickname";

type Save = (userId: string, raw: string) => ReturnType<typeof saveNickname>;

// PICK A NICKNAME: the one step before a player without a nickname can start
// or sit at a table -- on the home page in place of the menu, and at
// /nickname for the direct routes (Start a Table, single player, a table
// link or code), which come back afterwards. Only the nickname; the picture
// stays on the Profile page. The rules and the "That nickname is taken."
// message are the Profile page's own (lib/nickname.ts, lib/profileNickname.ts).
//
// save: the real save by default; the dev mock passes a fake one.
export function NicknameStep({
  userId,
  onSaved,
  onLogout,
  save = saveNickname,
}: {
  userId: string;
  onSaved: (nickname: string) => void;
  onLogout: () => void;
  save?: Save;
}) {
  const [nickname, setNickname] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (saving) return;
    setSaving(true);
    setError(null);
    const result = await save(userId, nickname);
    if (!result.ok) {
      setSaving(false);
      setError(result.message);
      return;
    }
    // Stays "Saving..." while the caller moves on.
    onSaved(result.nickname);
  }

  return (
    <CardRoomFrame title="Pick a nickname" backHome={false}>
      <p className="text-sm">
        It&apos;s the name other players see at the table and on the leaderboard. You can change it later on
        your Profile.
      </p>
      <form onSubmit={handleSubmit} className="flex w-full flex-col gap-4">
        <div className="flex flex-col gap-1">
          <label htmlFor="nickname" className="text-sm font-medium">
            Game nickname
          </label>
          <input
            id="nickname"
            type="text"
            required
            autoFocus
            autoComplete="nickname"
            maxLength={NICKNAME_MAX_LENGTH}
            value={nickname}
            onChange={(e) => setNickname(e.target.value)}
            aria-invalid={error ? true : undefined}
            aria-describedby={error ? "nickname-error" : undefined}
            className="felt-input"
          />
        </div>

        <button type="submit" disabled={saving} className="peg-btn peg-btn--brass disabled:opacity-60">
          {saving ? "Saving..." : "Continue"}
        </button>

        {error && (
          <p id="nickname-error" role="alert" className="text-sm text-[var(--error-on-felt)]">
            {error}
          </p>
        )}
      </form>
      <button type="button" onClick={onLogout} className="footer-link self-center text-sm">
        Log out
      </button>
    </CardRoomFrame>
  );
}
