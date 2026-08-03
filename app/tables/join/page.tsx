"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";

const CODE_PATTERN = /^[0-9]{4}$/;

export default function JoinTablePage() {
  const router = useRouter();
  const [code, setCode] = useState("");
  const [error, setError] = useState<string | null>(null);

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();

    if (!CODE_PATTERN.test(code)) {
      setError("Enter the 4-digit table code.");
      return;
    }

    // The actual "join" (inserting into table_members) happens on the table
    // page itself, so revisiting this URL later re-confirms membership
    // instead of erroring on a duplicate join.
    router.push(`/tables/${code}`);
  }

  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-6 p-8">
      <h1 className="text-2xl font-semibold">Join a Table</h1>

      <form onSubmit={handleSubmit} className="flex w-full max-w-sm flex-col gap-4">
        <div className="flex flex-col gap-1">
          <label htmlFor="code" className="text-sm font-medium">
            Table code
          </label>
          <input
            id="code"
            type="text"
            inputMode="numeric"
            pattern="[0-9]{4}"
            maxLength={4}
            required
            value={code}
            onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
            className="rounded border border-zinc-300 px-3 py-2 text-center text-2xl tracking-widest dark:border-zinc-700 dark:bg-zinc-900"
          />
        </div>

        <button
          type="submit"
          className="rounded bg-foreground px-4 py-2 text-background"
        >
          Join
        </button>

        {error && <p className="text-sm text-red-600">{error}</p>}
      </form>

      <Link href="/" className="text-sm underline">
        Back home
      </Link>
    </main>
  );
}
