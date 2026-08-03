"use client";

import { useEffect, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import Link from "next/link";
import { supabase } from "@/lib/supabase";

const UNIQUE_VIOLATION = "23505";
const MAX_CODE_ATTEMPTS = 5;

function generateCode() {
  return Math.floor(Math.random() * 10000)
    .toString()
    .padStart(4, "0");
}

export default function NewTablePage() {
  const [session, setSession] = useState<Session | null>(null);
  const [loading, setLoading] = useState(true);
  const [status, setStatus] = useState<"idle" | "creating" | "success" | "error">("idle");
  const [message, setMessage] = useState<string | null>(null);
  const [tableCode, setTableCode] = useState<string | null>(null);

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session);
      setLoading(false);
    });
  }, []);

  async function handleCreateTable() {
    if (!session) return;

    setStatus("creating");
    setMessage(null);

    for (let attempt = 0; attempt < MAX_CODE_ATTEMPTS; attempt++) {
      const code = generateCode();

      const { data, error } = await supabase
        .from("tables")
        .insert({ code, created_by: session.user.id })
        .select("code")
        .single();

      if (!error) {
        setTableCode(data.code);
        setStatus("success");
        return;
      }

      // Code collision -- try again with a fresh random code.
      if (error.code === UNIQUE_VIOLATION) {
        continue;
      }

      setStatus("error");
      setMessage(error.message);
      return;
    }

    setStatus("error");
    setMessage("Couldn't generate a unique table code, please try again.");
  }

  if (loading) {
    return (
      <main className="flex flex-1 items-center justify-center">
        <p>Loading...</p>
      </main>
    );
  }

  if (!session) {
    return (
      <main className="flex flex-1 flex-col items-center justify-center gap-4 p-8">
        <p>You need to be logged in to start a table.</p>
        <Link href="/login" className="underline">
          Log in
        </Link>
      </main>
    );
  }

  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-6 p-8">
      <h1 className="text-2xl font-semibold">Start a Table</h1>

      {tableCode ? (
        <div className="flex flex-col items-center gap-2">
          <p className="text-sm text-zinc-600 dark:text-zinc-400">Your table code is:</p>
          <p className="text-5xl font-bold tracking-widest">{tableCode}</p>
          <p className="text-sm text-zinc-600 dark:text-zinc-400">
            Share this code with the players joining you.
          </p>
        </div>
      ) : (
        <button
          onClick={handleCreateTable}
          disabled={status === "creating"}
          className="rounded bg-foreground px-4 py-2 text-background disabled:opacity-50"
        >
          {status === "creating" ? "Creating..." : "Start a Table"}
        </button>
      )}

      {status === "error" && message && <p className="text-sm text-red-600">{message}</p>}

      <Link href="/" className="text-sm underline">
        Back home
      </Link>
    </main>
  );
}
