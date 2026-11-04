// The nickname reads and the save, shared by the Profile page, the
// Pick-a-nickname step and the nickname gate. The rules themselves are in
// lib/nickname.ts (pure, tested).
import { supabase } from "@/lib/supabase";
import { needsNickname, nicknameProblem, nicknameSaveErrorMessage } from "@/lib/nickname";

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

// Saves the nickname (trimmed) on the player's profile row, creating the row
// if there isn't one. extra: other columns to write with it -- the Profile
// page sends its current picture, exactly as before; the nickname step sends
// nothing, so an existing picture is left as it is.
export async function saveNickname(
  userId: string,
  raw: string,
  extra: { avatar_url?: string | null } = {}
): Promise<{ ok: true; nickname: string } | { ok: false; message: string }> {
  const problem = nicknameProblem(raw);
  if (problem) return { ok: false, message: problem };

  const nickname = raw.trim();
  const { error } = await supabase.from("profiles").upsert({ id: userId, nickname, ...extra });
  if (error) return { ok: false, message: nicknameSaveErrorMessage(error) };
  return { ok: true, nickname };
}
