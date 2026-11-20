// A ONE-TIME MESSAGE FOR THE LOBBY (PRD item 40): a page that sends the
// player home with something to say ("The host removed you from this
// table.") leaves it here; the home screen shows it once. sessionStorage, so
// it never outlives the tab; every access guarded (private windows, blocked
// storage), and losing it only loses the message.
const KEY = "nobs:lobby-notice";

export function setLobbyNotice(text: string) {
  try {
    sessionStorage.setItem(KEY, text);
  } catch {
    // Storage unavailable: the player simply lands home without the message.
  }
}

export function peekLobbyNotice(): string | null {
  try {
    return typeof sessionStorage === "undefined" ? null : sessionStorage.getItem(KEY);
  } catch {
    return null;
  }
}

export function clearLobbyNotice() {
  try {
    sessionStorage.removeItem(KEY);
  } catch {
    // Nothing to clear.
  }
}
