// BOARD FINGERPRINTS: proves a change left the boards byte-identical. The test
// script can't render TSX, so this runs in a browser, against the running dev
// server, and hashes each board's real SVG (with its useId prefix taken out,
// so only the drawing counts). Nothing here is imported by the app.
//
// How to use it (paste the whole file into the browser console, or run it with
// any tool that evaluates a script in the page; it returns the results):
//   1. Before your change, on a clean checkout, open each page below at the
//      size given, and keep the results.
//        /dev/appearance                         any size (previews are fixed)
//        /dev/table-mock?state=fb-run            1024x767
//        /dev/table-mock?players=3&state=pegging 1024x767
//        /dev/table-mock?players=4&state=pegging 1024x767
//        /dev/table-mock?players=4&solo=1&state=pegging 1024x767
//      On a table-mock page, run it twice: once as it is, and once after
//      localStorage.setItem("nobs:board-custom", "football") and a reload
//      (remove the key afterwards).
//   2. After your change, do the same, and compare key by key. Every key from
//      before must have the same value; a new board only adds keys.
//
// /dev/appearance clicks through the picker, then puts the saved pattern,
// colours and custom board back as they were.

(async () => {
  const hash = (text) => {
    let h = 0;
    for (let i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) | 0;
    return `${h.toString(36)}:${text.length}`;
  };
  // Every board's ids start with its own useId value: take that out.
  const normal = (svg) => {
    const id = svg.outerHTML.match(/id="([^"]+?)-(?:wood|peg0|track)"/);
    return id ? svg.outerHTML.split(id[1]).join("U") : svg.outerHTML;
  };
  const print = (svg) => (svg ? hash(normal(svg)) : "none");
  const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  await wait(2500); // the page's first measure and paint

  if (location.pathname.startsWith("/dev/table-mock")) {
    const custom = localStorage.getItem("nobs:board-custom") ?? "none";
    return {
      page: location.pathname + location.search,
      size: `${innerWidth}x${innerHeight}`,
      custom,
      viewBox: document.querySelector(".sq-board svg")?.getAttribute("viewBox") ?? null,
      board: print(document.querySelector(".sq-board svg")),
    };
  }

  const saved = ["nobs:board", "nobs:board-pattern", "nobs:board-custom"].map((key) => [key, localStorage.getItem(key)]);
  const radio = (name, value) => document.querySelector(`input[name=${name}][value=${value}]`);
  const snapshot = () => {
    const out = {};
    for (const input of document.querySelectorAll("input[name=board-pattern],input[name=board-skin],input[name=board-custom]")) {
      out[`${input.name}/${input.value}`] = print(input.closest("label").querySelector("svg"));
    }
    return out;
  };
  const results = {};
  for (const pattern of ["straight", "s", "snake"]) {
    radio("board-pattern", pattern).click();
    await wait(600);
    results[pattern] = snapshot();
  }
  radio("board-pattern", "custom").click();
  await wait(1000);
  results.custom = snapshot();
  for (const [key, value] of saved) {
    if (value === null) localStorage.removeItem(key);
    else localStorage.setItem(key, value);
  }
  window.dispatchEvent(new Event("nobs:board-change"));
  return results;
})();
