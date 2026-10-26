"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { supabase } from "@/lib/supabase";
import { AppearanceSettings } from "@/components/AppearanceSettings";
import { CardRoomFrame } from "@/components/brand/CardRoomFrame";

const NICKNAME_MAX_LENGTH = 30;
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
    // trimmed), so a taken one is refused there (23505, below).
    const trimmedNickname = nickname.trim();
    if (!trimmedNickname) {
      setStatus("error");
      setMessage("Please enter a nickname.");
      return;
    }

    setStatus("saving");
    setMessage(null);

    // 1. The profile row first, with the CURRENT picture: a refused nickname
    // stops here, before anything is uploaded, so the picture never changes
    // and the chosen file and preview stay on the page.
    const { error: upsertError } = await supabase
      .from("profiles")
      .upsert({ id: session.user.id, nickname: trimmedNickname, avatar_url: avatarUrl });

    if (upsertError) {
      setStatus("error");
      setMessage(upsertError.code === "23505" ? "That nickname is taken." : upsertError.message);
      return;
    }
    setNickname(trimmedNickname);

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
      <CardRoomFrame backHome={false} followDeviceScheme>
        <p className="text-center">Loading...</p>
      </CardRoomFrame>
    );
  }

  if (!session) {
    return (
      <CardRoomFrame backHome={false} followDeviceScheme>
        <p>You need to be logged in to edit your profile.</p>
        <Link href="/login" className="peg-btn peg-btn--brass">
          Log in
        </Link>
      </CardRoomFrame>
    );
  }

  const displayedAvatar = avatarPreview ?? avatarUrl;

  return (
    // followDeviceScheme: the Appearance preview and swatches below must look
    // exactly as on a plain page (see CardRoomFrame).
    <CardRoomFrame
      title="Your Profile"
      followDeviceScheme
      after={
        // Card back and table surface: a section of its own, with its own
        // Save (components/AppearanceSettings.tsx).
        <section className="felt-panel w-full">
          <AppearanceSettings />
        </section>
      }
    >
      <form onSubmit={handleSubmit} className="flex w-full flex-col gap-4">
        <div className="flex flex-col items-center gap-3">
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
