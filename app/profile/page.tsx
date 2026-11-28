"use client";

import { useEffect, useRef, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { supabase } from "@/lib/supabase";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { ProfileStats } from "@/components/ProfileStats";
import { BlockedPlayers } from "@/components/brand/BlockedPlayers";
import { passwordPairProblem, passwordUpdateErrorMessage } from "@/lib/passwordForm";
import { NICKNAME_MAX_LENGTH, nicknameProblem } from "@/lib/nickname";
import { saveNickname } from "@/lib/profileNickname";
import { avatarPath } from "@/lib/avatarPath";
import {
  AVATAR_MESSAGES,
  AVATAR_OUTPUT_TYPE,
  avatarUpdateSaved,
  convertedProblem,
  pickedFileProblem,
  type AvatarProblem,
} from "@/lib/avatarImage";
import { convertToAvatarJpeg } from "@/lib/avatarConvert";
import { WingsFrame } from "@/components/Wings";
import { getGodWins } from "@/lib/godWins";
import { displayTier, initSeenTier, isCreator, placementFor, progress, wingsSplashSub } from "@/lib/wings";

// Save Profile's line when the save threw (no connection, say).
const PROFILE_SAVE_FAILED = "Couldn't save your profile. Check your connection and try again.";

export default function ProfilePage() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [nickname, setNickname] = useState("");
  // The nickname as saved (null until read): an unchanged name is re-sent
  // exactly and never pre-checked, so an old name that breaks today's rules
  // still saves (lib/nickname.ts).
  const [savedNickname, setSavedNickname] = useState<string | null>(null);
  const [avatarUrl, setAvatarUrl] = useState<string | null>(null);
  // THE PICTURE (the iPhone upload fix): saved as soon as it is picked, apart
  // from Save Profile. avatarPreview: the picked picture, shown while it
  // saves; avatarState and its one line sit directly under the photo.
  const [avatarPreview, setAvatarPreview] = useState<string | null>(null);
  const [avatarState, setAvatarState] = useState<"idle" | "saving" | "saved" | "error">("idle");
  const [avatarMessage, setAvatarMessage] = useState<string | null>(null);
  const previewRef = useRef<string | null>(null);
  const [status, setStatus] = useState<"idle" | "saving" | "success" | "error">("idle");
  const [message, setMessage] = useState<string | null>(null);
  // Times this player has beaten God; null until read, or if it can't be.
  const [godWins, setGodWins] = useState<number | null>(null);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });
  }, []);

  useEffect(() => {
    if (!session) return;

    supabase
      .from("profiles")
      .select("id, nickname, avatar_url")
      .eq("id", session.user.id)
      .maybeSingle()
      .then(({ data, error }) => {
        if (error) {
          setStatus("error");
          setMessage(error.message);
          return;
        }
        if (data) {
          setNickname(data.nickname ?? "");
          setSavedNickname(data.nickname ?? "");
          setAvatarUrl(data.avatar_url);
        }
      });

    const userId = session.user.id;
    getGodWins([userId]).then((found) => {
      const mine = found.get(userId);
      if (!mine) return;
      initSeenTier(userId, mine.count);
      setGodWins(mine.count);
    });
  }, [session]);

  // The picked picture's preview, dropped (its object URL freed): the saved
  // picture, or the old one after a failure, shows again.
  function clearPreview() {
    if (previewRef.current) URL.revokeObjectURL(previewRef.current);
    previewRef.current = null;
    setAvatarPreview(null);
  }
  useEffect(() => () => {
    if (previewRef.current) URL.revokeObjectURL(previewRef.current);
  }, []);

  function avatarFailed(problem: AvatarProblem) {
    clearPreview();
    setAvatarState("error");
    setAvatarMessage(AVATAR_MESSAGES[problem]);
  }

  // PICKED = SAVED: made into a 512 px JPEG on the phone (lib/avatarImage.ts,
  // lib/avatarConvert.ts), uploaded as <uid>/avatar.jpg, then ONLY
  // profiles.avatar_url is updated -- never the nickname, so the 7-day
  // nickname lock can't refuse it. The picker is off while it saves.
  async function handleFileChange(e: React.ChangeEvent<HTMLInputElement>) {
    const input = e.target;
    const file = input.files?.[0] ?? null;
    // Cleared, so picking the same file again still fires a change.
    input.value = "";
    if (!file || !session || avatarState === "saving") return;
    const userId = session.user.id;

    const picked = pickedFileProblem(file.size);
    if (picked) {
      avatarFailed(picked);
      return;
    }

    clearPreview();
    const shown = URL.createObjectURL(file);
    previewRef.current = shown;
    setAvatarPreview(shown);
    setAvatarState("saving");
    setAvatarMessage(AVATAR_MESSAGES.saving);

    const jpeg = await convertToAvatarJpeg(file);
    const converted = convertedProblem(jpeg);
    if (converted || !jpeg) {
      avatarFailed(converted ?? "unreadable");
      return;
    }

    try {
      const path = avatarPath(userId, { type: AVATAR_OUTPUT_TYPE });
      if (!path) throw new Error("no avatar path");
      const upload = new File([jpeg], "avatar.jpg", { type: AVATAR_OUTPUT_TYPE });
      const { error: uploadError } = await supabase.storage
        .from("avatars")
        .upload(path, upload, { upsert: true, contentType: AVATAR_OUTPUT_TYPE });
      if (uploadError) throw uploadError;

      const { data: publicUrlData } = supabase.storage.from("avatars").getPublicUrl(path);
      // cache-bust so the new image shows immediately instead of a browser-cached old one
      const newAvatarUrl = `${publicUrlData.publicUrl}?t=${Date.now()}`;

      const { data: rows, error: updateError } = await supabase
        .from("profiles")
        .update({ avatar_url: newAvatarUrl })
        .eq("id", userId)
        .select("id");
      if (!avatarUpdateSaved(updateError, rows)) throw updateError ?? new Error("no profile row updated");

      setAvatarUrl(newAvatarUrl);
      clearPreview();
      setAvatarState("saved");
      setAvatarMessage(AVATAR_MESSAGES.saved);
    } catch {
      avatarFailed("save_failed");
    }
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!session) return;

    // Saved normalized (trimmed, single spaces). The simple rules are
    // pre-checked here only for a changed name; reserved words and
    // look-alikes are refused by the server. The rules and messages are
    // shared with the Pick-a-nickname step (lib/nickname.ts).
    const problem = nicknameProblem(nickname, savedNickname);
    if (problem) {
      setStatus("error");
      setMessage(problem);
      return;
    }

    setStatus("saving");
    setMessage(null);

    // The NICKNAME only: the picture saves itself when picked
    // (handleFileChange), so the row is never written with a stale picture.
    // A thrown error (no connection) shows a message; the button never stays
    // on "Saving...".
    try {
      const saved = await saveNickname(session.user.id, nickname, savedNickname);
      if (!saved.ok) {
        setStatus("error");
        setMessage(saved.message);
        return;
      }
      setNickname(saved.nickname);
      setSavedNickname(saved.nickname);
      setStatus("success");
      setMessage("Profile saved.");
    } catch {
      setStatus("error");
      setMessage(PROFILE_SAVE_FAILED);
    }
  }

  if (loading) {
    return (
      <CardRoomFrame backHome={false}>
        <p className="text-center">Loading...</p>
      </CardRoomFrame>
    );
  }

  if (!session) {
    return (
      <CardRoomFrame backHome={false}>
        <p>You need to be logged in to edit your profile.</p>
        <Link href="/login" className="peg-btn peg-btn--brass">
          Log in
        </Link>
      </CardRoomFrame>
    );
  }

  const displayedAvatar = avatarPreview ?? avatarUrl;
  // Mine, always: "Show wings" is about the table and the lists.
  const standing = godWins === null ? null : progress(godWins);
  // The creator's wings need no read; the line then says so, with any God wins.
  const creator = session ? isCreator(session.user.id) : false;
  const tier = displayTier(session?.user.id, standing?.tier);
  const standingText = creator
    ? godWins
      ? `Creator · ${wingsSplashSub(godWins)}`
      : "Creator"
    : (standing?.text ?? null);

  return (
    // The look and sound settings moved to their own page, /settings (PRD
    // item 35, slice S2). Under the profile card: the player's stats (S3),
    // which read on their own and never block the form.
    // Under the stats: the player's own Block List (moderation M1), its own
    // section and form, outside the profile form.
    <CardRoomFrame
      title="Your Profile"
      after={
        <>
          <ProfileStats userId={session.user.id} />
          <BlockedPlayers />
        </>
      }
    >
      <form onSubmit={handleSubmit} className="flex w-full flex-col gap-4">
        <div className={`flex flex-col items-center gap-3 ${tier ? "profile-winged" : ""}`}>
          <WingsFrame tier={tier} placement={placementFor("profile")} size={96}>
            {displayedAvatar ? (
              // eslint-disable-next-line @next/next/no-img-element
              <img
                src={displayedAvatar}
                alt="Profile picture"
                className="h-24 w-24 rounded-full border-2 border-[var(--brass)] object-cover"
              />
            ) : (
              <div className="flex h-24 w-24 items-center justify-center rounded-full border-2 border-[var(--brass)] bg-[#2a6a44] text-center text-xs">
                No photo
              </div>
            )}
          </WingsFrame>
          {/* The picture's one line, directly under the photo. */}
          <p
            role="status"
            aria-live="polite"
            data-avatar-message={avatarState}
            className={`min-h-5 text-center text-sm ${
              avatarState === "error"
                ? "text-[var(--error-on-felt)]"
                : avatarState === "saved"
                  ? "text-[var(--success-on-felt)]"
                  : ""
            }`}
          >
            {avatarMessage}
          </p>
          {standingText && <p className="text-sm">{standingText}</p>}
          <input
            type="file"
            accept="image/png,image/jpeg,image/webp"
            onChange={handleFileChange}
            disabled={avatarState === "saving"}
            aria-label="Choose a profile picture"
            className="felt-file disabled:opacity-60"
          />
        </div>

        <div className="flex flex-col gap-1">
          <label htmlFor="nickname" className="text-sm font-medium">
            Game nickname
          </label>
          <input
            id="nickname"
            type="text"
            required
            maxLength={NICKNAME_MAX_LENGTH}
            value={nickname}
            onChange={(e) => setNickname(e.target.value)}
            className="felt-input"
          />
        </div>

        <button
          type="submit"
          disabled={status === "saving"}
          className="peg-btn peg-btn--brass disabled:opacity-60"
        >
          {status === "saving" ? "Saving..." : "Save Profile"}
        </button>

        <ChangePassword />

        {message && (
          <p
            className={
              status === "error"
                ? "text-sm text-[var(--error-on-felt)]"
                : "text-sm text-[var(--success-on-felt)]"
            }
          >
            {message}
          </p>
        )}
      </form>
    </CardRoomFrame>
  );
}

// CHANGE PASSWORD, for the signed-in player, under Save Profile: one button
// that opens the two fields ("Change Password"), then saves them ("Save
// Password"); Cancel closes them. supabase.auth.updateUser on the account
// itself -- the profile row is never read or written here. If Supabase wants
// a recent login first, the message says how to get one.
//
// It sits INSIDE the profile form, so nothing here may submit it: every
// button is type="button", Enter in a field saves the password instead, and
// the fields have no required/minLength (the browser would then block Save
// Profile) -- the rules are checked in code (lib/passwordForm.ts).
function ChangePassword() {
  const [open, setOpen] = useState(false);
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [status, setStatus] = useState<"idle" | "saving" | "success" | "error">("idle");
  const [message, setMessage] = useState<string | null>(null);

  function close() {
    setOpen(false);
    setPassword("");
    setConfirm("");
  }

  function handleButton() {
    if (!open) {
      setOpen(true);
      setStatus("idle");
      setMessage(null);
      return;
    }
    savePassword();
  }

  function handleCancel() {
    close();
    setStatus("idle");
    setMessage(null);
  }

  function saveOnEnter(e: React.KeyboardEvent<HTMLInputElement>) {
    if (e.key !== "Enter") return;
    e.preventDefault(); // never the profile form's submit
    savePassword();
  }

  async function savePassword() {
    if (status === "saving") return;
    const problem = passwordPairProblem(password, confirm);
    if (problem) {
      setStatus("error");
      setMessage(problem);
      return;
    }

    setStatus("saving");
    setMessage(null);
    const { error } = await supabase.auth.updateUser({ password });

    if (error) {
      setStatus("error");
      setMessage(passwordUpdateErrorMessage(error));
      return;
    }

    close();
    setStatus("success");
    setMessage("Password updated.");
  }

  return (
    <>
      <button
        type="button"
        onClick={handleButton}
        disabled={status === "saving"}
        aria-expanded={open}
        aria-controls="change-password-fields"
        className="peg-btn peg-btn--ghost disabled:opacity-60"
      >
        {status === "saving" ? "Saving..." : open ? "Save Password" : "Change Password"}
      </button>

      {open && (
        <div id="change-password-fields" className="flex flex-col gap-4">
          <div className="flex flex-col gap-1">
            <label htmlFor="new-password" className="text-sm font-medium">
              New password
            </label>
            <input
              id="new-password"
              type="password"
              autoComplete="new-password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              onKeyDown={saveOnEnter}
              className="felt-input"
            />
          </div>

          <div className="flex flex-col gap-1">
            <label htmlFor="confirm-password" className="text-sm font-medium">
              Confirm new password
            </label>
            <input
              id="confirm-password"
              type="password"
              autoComplete="new-password"
              value={confirm}
              onChange={(e) => setConfirm(e.target.value)}
              onKeyDown={saveOnEnter}
              className="felt-input"
            />
          </div>

          <button type="button" onClick={handleCancel} className="footer-link self-center text-sm">
            Cancel
          </button>
        </div>
      )}

      {message && (
        <p
          role={status === "error" ? "alert" : "status"}
          className={
            status === "error"
              ? "text-sm text-[var(--error-on-felt)]"
              : "text-sm text-[var(--success-on-felt)]"
          }
        >
          {message}
        </p>
      )}
    </>
  );
}
