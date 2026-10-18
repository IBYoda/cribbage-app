// PHASE 3 TABLES (3 and 4 players). The server plays them already (engine
// steps E1 to E4), but the table screen can't yet -- the waiting room, the
// layout and the counting flow are app stages A2 to A4. So this is OFF
// unless the build sets NEXT_PUBLIC_PHASE3_TABLES=true, and with it off:
//   * Start a Table offers 2 players only, as before;
//   * Open Tables lists 2-player tables only. Local dev and the live site
//     share one Supabase project, so a 3- or 4-player table made on a build
//     with the flag on must never be offered to players on a build without
//     it.
// Read at BUILD time: Next inlines NEXT_PUBLIC_ values into the browser
// bundle, so changing it needs a rebuild.
//
// REMOVE this flag, and every check of it, when 3- and 4-player tables go
// live (stage A4).
export const PHASE3_TABLES = process.env.NEXT_PUBLIC_PHASE3_TABLES === "true";
