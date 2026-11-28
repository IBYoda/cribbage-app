// The nickname reads and the save, shared by the Profile page, the
// Pick-a-nickname step and the nickname gate. The rules themselves are in
// lib/nickname.ts (pure, tested).
import { supabase } from "@/lib/supabase";
import { NICKNAME_SAVE_FAILED, needsNickname, nicknameSaveErrorMessage, nicknameToSave } from "@/lib/nickname";

// Does this player still have to pick a nickname? null: the profile couldn't
// be read, and the callers then let the player through rather than block
// someone who may well have one (the gate is a nudge, not a guard).
export async function fetchNeedsNickname(userId: string): Promise<boolean | null> {
  try {
    const { data, error } = await supabase.from("profiles").select("nickname").eq("id", userId).maybeSingle();
    if (error) return null;
    return needsNickname(data);
  } catch {
    return null;
  }
}

// Saves the nickname on the player's profile row, creating the row if there
// isn't one. The typed value is normalized (trimmed, runs of spaces made one)
// and pre-checked (lib/nickname.ts); saved: the player's current nickname
// (the Profile page), so re-saving the same name sends it back exactly and
// is never refused. Only the nickname is written. A refusal comes back in
// the server's words, or one generic line; a throw (no connection) is that
// generic line too.
export async function saveNickname(
  userId: string,
  raw: string,
  saved?: string | null
): Promise<{ ok: true; nickname: string } | { ok: false; message: string }> {
  const checked = nicknameToSave(raw, saved);
  if (!checked.ok) return checked;

  const { nickname } = checked;
  try {
    const { error } = await supabase.from("profiles").upsert({ id: userId, nickname });
    if (error) return { ok: false, message: nicknameSaveErrorMessage(error) };
  } catch {
    return { ok: false, message: NICKNAME_SAVE_FAILED };
  }
  return { ok: true, nickname };
}
