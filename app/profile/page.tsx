"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { supabase } from "@/lib/supabase";
import { AppearanceSettings } from "@/components/AppearanceSettings";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";
import { passwordPairProblem, passwordUpdateErrorMessage } from "@/lib/passwordForm";
import { NICKNAME_MAX_LENGTH, nicknameProblem } from "@/lib/nickname";
import { saveNickname } from "@/lib/profileNickname";
import { WingsFrame } from "@/components/Wings";
import { getGodWins } from "@/lib/godWins";
import { displayTier, initSeenTier, isCreator, placementFor, progress, wingsSplashSub } from "@/lib/wings";

const AVATAR_MAX_BYTES = 2 * 1024 * 1024; // must match the bucket's file_size_limit in Supabase

export default function ProfilePage() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [nickname, setNickname] = useState("");
  const [avatarUrl, setAvatarUrl] = useState<string | null>(null);
  const [avatarFile, setAvatarFile] = useState<File | null>(null);
  const [avatarPreview, setAvatarPreview] = useState<string | null>(null);
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

  function handleFileChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0] ?? null;
    if (!file) {
      setAvatarFile(null);
      setAvatarPreview(null);
      return;
    }
    if (file.size > AVATAR_MAX_BYTES) {
      setStatus("error");
      setMessage("Image must be smaller than 2MB.");
      return;
    }
    setAvatarFile(file);
    setAvatarPreview(URL.createObjectURL(file));
    setStatus("idle");
    setMessage(null);
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!session) return;

    // Saved trimmed. Nicknames are unique in the database (case-insensitive,
    // trimmed), so a taken one is refused there. The rules and messages are
    // shared with the Pick-a-nickname step (lib/nickname.ts).
    const problem = nicknameProblem(nickname);
    if (problem) {
      setStatus("error");
      setMessage(problem);
      return;
    }

    setStatus("saving");
    setMessage(null);

    // 1. The profile row first, with the CURRENT picture: a refused nickname
    // stops here, before anything is uploaded, so the picture never changes
    // and the chosen file and preview stay on the page.
    const saved = await saveNickname(session.user.id, nickname, { avatar_url: avatarUrl });

    if (!saved.ok) {
      setStatus("error");
      setMessage(saved.message);
      return;
    }
    setNickname(saved.nickname);

    // 2. Then a new picture, if one was chosen: upload it, then point the
    // (now existing) row at it. If either fails the nickname has still
    // saved; the error shows and the file stays chosen for another try.
    let newAvatarUrl = avatarUrl;

    if (avatarFile) {
      const ext = avatarFile.name.split(".").pop();
      const path = `${session.user.id}/avatar.${ext}`;

      const { error: uploadError } = await supabase.storage
        .from("avatars")
        .upload(path, avatarFile, { upsert: true, contentType: avatarFile.type });

      if (uploadError) {
        setStatus("error");
        setMessage(uploadError.message);
        return;
      }

      const { data: publicUrlData } = supabase.storage.from("avatars").getPublicUrl(path);
      // cache-bust so the new image shows immediately instead of a browser-cached old one
      newAvatarUrl = `${publicUrlData.publicUrl}?t=${Date.now()}`;

      const { error: avatarError } = await supabase
        .from("profiles")
        .update({ avatar_url: newAvatarUrl })
        .eq("id", session.user.id);

      if (avatarError) {
        setStatus("error");
        setMessage(avatarError.message);
        return;
      }
    }

    setAvatarUrl(newAvatarUrl);
    setAvatarFile(null);
    setAvatarPreview(null);
    setStatus("success");
    setMessage("Profile saved.");
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
    <CardRoomFrame
      title="Your Profile"
      after={
        // Card back and table surface: a section of its own, with its own
        // Save (components/AppearanceSettings.tsx).
        <section className="felt-panel w-full">
          <AppearanceSettings />
        </section>
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
          {standingText && <p className="text-sm">{standingText}</p>}
          <input
            type="file"
            accept="image/png,image/jpeg,image/webp"
            onChange={handleFileChange}
            className="felt-file"
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
