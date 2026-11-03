"use client";

// ONE OPEN TABLE on the admin page (app/admin/page.tsx; also drawn by the dev
// mock app/dev/admin-mock): its code (and computer tag), Force-End Table,
// how full it is and its mode, who sits there, and its live game with
// Force-End Game.

export type AdminTable = {
  id: string;
  code: string;
  created_at: string;
  // A computer table's level ('easy' / 'medium' / 'hard'), null otherwise.
  // Shown as a tag; computer tables are listed and force-endable like any.
  computerLevel: string | null;
  // "1/4 seated · Solo · Self-Scoring" (adminTableLabel), and who sits there,
  // in seat order (seatedNames) -- so old test tables can be told apart.
  label: string;
  names: string[];
  activeGame: { id: string; created_at: string; status: string } | null;
};

export function AdminTableRow({
  table: t,
  actionInFlight,
  onForceEndTable,
  onForceEndGame,
}: {
  table: AdminTable;
  // The id (table or game) whose Force-End is in flight, if any.
  actionInFlight: string | null;
  onForceEndTable: () => void;
  onForceEndGame: (gameId: string) => void;
}) {
  return (
    <li className="flex flex-col gap-2 rounded-xl border border-[rgb(226_193_125/0.4)] bg-black/25 p-4">
      <div className="flex items-center justify-between gap-3">
        <span className="flex min-w-0 flex-wrap items-center gap-2">
          <span className="text-xl font-bold tracking-widest">{t.code}</span>
          {t.computerLevel && <span className="muggins-tag">Computer ({t.computerLevel})</span>}
        </span>
        <button onClick={onForceEndTable} disabled={actionInFlight === t.id} className="danger-btn shrink-0">
          {actionInFlight === t.id ? "Ending..." : "Force-End Table"}
        </button>
      </div>
      <p className="text-sm">
        {t.label} · created {new Date(t.created_at).toLocaleString()}
      </p>
      {/* Who sits there, in seat order. Long names wrap (a name with no
          spaces breaks anywhere), so the row never widens. */}
      <p className="text-sm text-[var(--brass-light)] [overflow-wrap:anywhere]">
        {t.names.length > 0 ? t.names.join(", ") : "Nobody seated"}
      </p>
      {t.activeGame && (
        <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg bg-black/30 px-3 py-2">
          {/* A cutting game has no cards dealt yet -- worth distinguishing,
              since "abandoned mid-cut" is a likely reason to be killing one
              from here. */}
          <span
            className={
              t.activeGame.status === "cutting"
                ? "text-sm text-[var(--brass-light)]"
                : "text-sm text-[var(--success-on-felt)]"
            }
          >
            {t.activeGame.status === "cutting" ? "Cutting for deal (nothing dealt) since " : "Game in progress since "}
            {new Date(t.activeGame.created_at).toLocaleTimeString()}
          </span>
          <button
            onClick={() => onForceEndGame(t.activeGame!.id)}
            disabled={actionInFlight === t.activeGame.id}
            className="danger-btn"
          >
            {actionInFlight === t.activeGame.id ? "Ending..." : "Force-End Game"}
          </button>
        </div>
      )}
    </li>
  );
}
