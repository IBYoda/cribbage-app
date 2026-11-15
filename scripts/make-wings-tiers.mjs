// THE WINGS LADDER'S MADE TIERS: bronze, sapphire, ruby, diamond and prismatic
// (from silver), and the live silver, gold and emerald (polished silver and
// gold, crystal emerald), all generated from Walt's own originals in
// docs/art/sources/ (<size>-<silver|gold|emerald>-original.webp), which are
// read and never written, so regenerating never reworks an already reworked
// file. Plus the approval sheet. White, black and the ears are untouched.
//
//   node scripts/make-wings-tiers.mjs           the eight tiers' files and the sheet
//   node scripts/make-wings-tiers.mjs --check   the files only, and how far apart the tiers are
//
// The output is deterministic: no clock, no Math.random (a fixed-seed PRNG
// lays out the facets), so running it again writes the same bytes.
//
// TWO PROCESSES, both read only the source's luminance (Rec. 709) and its
// alpha; the alpha is copied byte for byte (full from full, mini from mini)
// and checked after encoding. Every image keeps the 1075 x 695 design canvas
// and the avatar centre at 50%, 68.35%: the sources' own geometry.
//
// POLISHED METAL (bronze, silver, gold): the luminance,
// normalised over the art's own range, gets local contrast at about a
// feather's scale (clarity: luminance minus its alpha-weighted blur, added
// back), an S-curve (deeper shadows, brighter peaks), and a specular lift
// where the clarity is bright, so every feather's edge catches a rim; then a
// multi-stop gradient map from a near-black shadow through the metal's colours
// to a near-white specular top.
//
// CRYSTAL (sapphire, ruby, diamond, prismatic, emerald): the same
// clarity, plus facets: a jittered grid of seeds (Voronoi cells about a third
// of a feather wide at full size, coarser at mini), each cell with its own
// brightness, tint and light direction (a light-to-dark ramp across the
// facet), thin bright lines where cells meet, an inner glow just inside the
// wing's silhouette, a gem gradient map with deep saturated darks and
// near-white tops, and star glints at the brightest points (small bright
// points at mini). Translucency is faked with colour only. Prismatic keeps its
// rainbow fan (by feather angle, spread by area) under the facets.
//
// sharp comes with Next (it is not a direct dependency).

import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const sharp = require("sharp");

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const WINGS = path.join(ROOT, "public", "wings");
// Walt's originals, read and never written: silver, gold and the green emerald
// as they were before pass 3 replaced the live ones.
const SOURCES = path.join(ROOT, "docs", "art", "sources");
const sourceFile = (source, size) => path.join(SOURCES, `${size}-${source}-original.webp`);
const SHEET = path.join(ROOT, "docs", "art", "wings-ladder-preview-v3.png");
const SIZES = { full: [860, 556], mini: [168, 109] };
// Per-size scale for anything measured in pixels at full size.
const SCALE = { full: 1, mini: 168 / 860 };
const CENTRE = { x: 0.5, y: 475 / 695 };
// WebP as the ears were made: quality 90, alpha lossless.
const WEBP = { quality: 90, alphaQuality: 100, effort: 6 };

// ---- the recipes -------------------------------------------------------------

const METAL = "metal";
const CRYSTAL = "crystal";

// The live made tiers (public/wings/<size>-<name>.webp).
const TIERS = {
  bronze: {
    kind: METAL,
    source: "silver",
    range: [35, 255],
    equalize: 0.8,
    clarity: { sigma: 7, amount: 0.4 },
    curve: 1.2,
    gamma: 1,
    specular: 0.35,
    ramp: [
      [0, "#0e0502"],
      [0.16, "#3a1708"],
      [0.34, "#7a3613"],
      [0.5, "#b4561d"],
      [0.66, "#d8732a"],
      [0.82, "#ee9a52"],
      [0.94, "#ffc690"],
      [1, "#fff1e2"],
    ],
  },
  // The coloured stones: a deep, saturated body (most of the wing sits in the
  // ramp's lower two thirds), facets with plenty of contrast between cells,
  // and white kept for the facet edges, the glints and the brightest peaks.
  sapphire: gem({
    tints: ["#3fb7ff", "#5a4bff", "#1f5cff"],
    ramp: [
      [0, "#00020c"],
      [0.25, "#04145a"],
      [0.48, "#0a33b8"],
      [0.68, "#2563f2"],
      [0.84, "#6aa2ff"],
      [0.95, "#d2e4ff"],
      [1, "#ffffff"],
    ],
  }),
  ruby: gem({
    tints: ["#ff3b6e", "#ff1f2e", "#c80a52"],
    ramp: [
      [0, "#0b0003"],
      [0.25, "#4c0010"],
      [0.48, "#a0041f"],
      [0.68, "#e01a39"],
      [0.84, "#ff6b80"],
      [0.95, "#ffd3da"],
      [1, "#ffffff"],
    ],
  }),
  // Clear ice: a cool blue-white with stronger refraction (bigger jumps
  // between facets, some cells dark), so it reads as cut glass, not as silver
  // metal or white feathers.
  diamond: gem({
    gamma: 1.2,
    facet: { light: 0.4, jitter: 0.26, edge: 0.8, edgeWidth: 1.5 },
    cell: 26,
    glow: 0.4,
    glints: { full: 36, mini: 8 },
    tints: ["#6fdcff", "#ffb0e2", "#bdb0ff", "#9cffe2"],
    tintAmount: 0.26,
    ramp: [
      [0, "#0b2440"],
      [0.25, "#3474b4"],
      [0.5, "#74b9f2"],
      [0.7, "#b8e2ff"],
      [0.86, "#e6f7ff"],
      [1, "#ffffff"],
    ],
  }),
  prismatic: gem({
    gamma: 1.2,
    rainbow: { saturation: 0.7, hues: 0.8, cellJitter: 0.035 },
    tints: null,
    ramp: [
      [0, "#2c2834"],
      [0.3, "#76708a"],
      [0.6, "#c4bdd0"],
      [0.85, "#efeaf4"],
      [1, "#ffffff"],
    ],
  }),
};

// A crystal recipe: the shared settings, then the stone's own.
function gem({ tints, tintAmount = 0.12, ...own }) {
  return {
    kind: CRYSTAL,
    source: "silver",
    range: [35, 255],
    equalize: 0.6,
    clarity: { sigma: 6, amount: 0.45 },
    curve: 1.3,
    gamma: 1.55,
    sheen: 0.35,
    cell: 30,
    facet: { light: 0.3, jitter: 0.17, edge: 0.6, edgeWidth: 1.5 },
    glow: 0.3,
    glints: { full: 28, mini: 6 },
    tints: tints ? { amount: tintAmount, colors: tints } : null,
    ...own,
  };
}

// Silver, gold and emerald, remade from their originals (docs/art/sources/):
// pass 2's candidates, approved by Walt and promoted to the live art in pass 3.
// emerald's facets keep the seed they had as the candidate "emerald-crystal",
// so the file is the same, byte for byte.
const PROMOTED = {
  silver: {
    kind: METAL,
    source: "silver",
    range: [35, 255],
    equalize: 0.55,
    clarity: { sigma: 7, amount: 0.7 },
    curve: 1.3,
    gamma: 1,
    specular: 0.45,
    ramp: [
      [0, "#0b0d10"],
      [0.2, "#3b4048"],
      [0.42, "#7d8590"],
      [0.62, "#b6bdc7"],
      [0.8, "#e1e6ec"],
      [0.92, "#f7f9fb"],
      [1, "#ffffff"],
    ],
  },
  gold: {
    kind: METAL,
    source: "gold",
    range: [35, 250],
    equalize: 0.3,
    clarity: { sigma: 7, amount: 0.6 },
    curve: 1.25,
    gamma: 0.95,
    specular: 0.45,
    ramp: [
      [0, "#120900"],
      [0.18, "#4a2c02"],
      [0.38, "#94600a"],
      [0.56, "#cf9a17"],
      [0.72, "#f0c63a"],
      [0.86, "#ffe788"],
      [1, "#fffbe6"],
    ],
  },
  emerald: gem({
    seed: "emerald-crystal",
    source: "emerald",
    range: [20, 250],
    gamma: 0.95,
    tints: ["#3dffb0", "#10b862", "#8cff5a"],
    ramp: [
      [0, "#000b05"],
      [0.25, "#023d1c"],
      [0.48, "#058a41"],
      [0.68, "#13c463"],
      [0.84, "#60eb9f"],
      [0.95, "#cffbe3"],
      [1, "#ffffff"],
    ],
  }),
};

// Every tier this script writes to public/wings.
const LIVE = { ...TIERS, ...PROMOTED };

// The first pass (plain gradient maps), kept only to draw the sheet's
// before/after strip. Not written anywhere.
const FIRST_PASS = {
  bronze: { ramp: [[0, "#120602"], [0.28, "#3f1d0b"], [0.52, "#7a3f1c"], [0.74, "#b2672f"], [0.9, "#dc9a5e"], [1, "#f8d4ac"]], gamma: 1.45 },
  sapphire: { ramp: [[0, "#020615"], [0.28, "#0a1d5c"], [0.52, "#1844b0"], [0.74, "#3f78e6"], [0.9, "#8db7ff"], [1, "#e8f1ff"]], gamma: 1.4 },
  ruby: { ramp: [[0, "#120108"], [0.28, "#460414"], [0.52, "#8e0c2c"], [0.74, "#cf2347"], [0.9, "#f27b90"], [1, "#ffe2e8"]], gamma: 1.4 },
  diamond: { ramp: [[0, "#2c5478"], [0.25, "#73a9d8"], [0.5, "#a9d6f5"], [0.72, "#d2edff"], [0.88, "#eef9ff"], [1, "#ffffff"]], gamma: 1 },
  prismatic: { ramp: [[0, "#4e4a57"], [0.35, "#9d97a8"], [0.65, "#d8d2de"], [0.88, "#f3eff6"], [1, "#ffffff"]], gamma: 0.95, rainbow: 0.5 },
};

// The ten tiers in ladder order, for the sheet.
const LADDER = ["white", "bronze", "silver", "gold", "emerald", "sapphire", "ruby", "diamond", "prismatic", "black"];
// The badge dots as lib/wings.ts draws them (WINGS_BADGE): kept in step by hand
// for the sheet only.
const BADGE = {
  white: "#ffffff",
  bronze: "#b8733a",
  silver: "#cfe0ff",
  gold: "#ffd24a",
  emerald: "#0f9d58",
  sapphire: "#2f5fe8",
  ruby: "#d4143c",
  diamond: ["linear", "#ffffff", "#ffffff", "#8fe3ff", "#3fb4e6"],
  prismatic: ["conic", "#ff4d4d", "#ffb84d", "#f5e94d", "#4ddc6a", "#4dc3ff", "#6a5cff", "#d04dff"],
  black: "#ff5a14",
};

// ---- helpers -----------------------------------------------------------------

const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16));
const clamp01 = (v) => Math.min(1, Math.max(0, v));
const lerp = (a, b, t) => a + (b - a) * t;
const smoothstep = (a, b, x) => {
  const t = clamp01((x - a) / (b - a));
  return t * t * (3 - 2 * t);
};
// Deeper shadows and brighter peaks, the midpoint fixed.
const sCurve = (x, k) => (x < 0.5 ? 0.5 * Math.pow(2 * x, k) : 1 - 0.5 * Math.pow(2 * (1 - x), k));

// mulberry32: a small fixed-seed PRNG, so the facets never move.
function prng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const seedOf = (name, size) => [...`${name}:${size}`].reduce((h, c) => Math.imul(h ^ c.charCodeAt(0), 16777619) >>> 0, 2166136261);

function rampAt(ramp, t) {
  for (let i = 1; i < ramp.length; i++) {
    const [t1, c1] = ramp[i];
    const [t0, c0] = ramp[i - 1];
    if (t <= t1) {
      const k = (t - t0) / (t1 - t0 || 1);
      const a = hex(c0);
      const b = hex(c1);
      return [lerp(a[0], b[0], k), lerp(a[1], b[1], k), lerp(a[2], b[2], k)];
    }
  }
  return hex(ramp[ramp.length - 1][1]);
}

function rgbToHsl(r, g, b) {
  r /= 255;
  g /= 255;
  b /= 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;
  if (max === min) return [0, 0, l];
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  const h = max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4;
  return [h / 6, s, l];
}

function hslToRgb(h, s, l) {
  if (s === 0) return [l * 255, l * 255, l * 255];
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  const f = (t) => {
    t = ((t % 1) + 1) % 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 1 / 2) return q;
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  };
  return [f(h + 1 / 3) * 255, f(h) * 255, f(h - 1 / 3) * 255];
}

// A separable Gaussian-like blur: three box passes each way.
function blur(src, w, h, sigma) {
  if (sigma < 0.3) return Float32Array.from(src);
  const r = Math.max(1, Math.round(Math.sqrt((12 * sigma * sigma) / 3 + 1) / 2));
  let a = Float32Array.from(src);
  let b = new Float32Array(src.length);
  const pass = (from, to, horizontal) => {
    const n = horizontal ? w : h;
    const m = horizontal ? h : w;
    for (let j = 0; j < m; j++) {
      let sum = 0;
      const at = (i) => (horizontal ? j * w + Math.min(n - 1, Math.max(0, i)) : Math.min(n - 1, Math.max(0, i)) * w + j);
      for (let i = -r; i <= r; i++) sum += from[at(i)];
      for (let i = 0; i < n; i++) {
        to[horizontal ? j * w + i : i * w + j] = sum / (2 * r + 1);
        sum += from[at(i + r + 1)] - from[at(i - r)];
      }
    }
  };
  for (let k = 0; k < 3; k++) {
    pass(a, b, true);
    pass(b, a, false);
  }
  return a;
}

async function readRaw(file) {
  const { data, info } = await sharp(file).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  return { data, width: info.width, height: info.height };
}

// Each pixel's angle round the avatar's centre (mirrored, so both wings
// match), as a 0..1 rank among the opaque art's angles: equal area per hue.
function angleRanks(data, w, h) {
  const angleAt = (p) => {
    const x = (p % w) / w - CENTRE.x;
    const y = (Math.floor(p / w) / h - CENTRE.y) * (h / w);
    return Math.atan2(-y, Math.abs(x));
  };
  const angles = [];
  for (let p = 0; p < w * h; p++) if (data[p * 4 + 3] >= 128) angles.push(angleAt(p));
  angles.sort((a, b) => a - b);
  const out = new Float32Array(w * h);
  for (let p = 0; p < w * h; p++) {
    const a = angleAt(p);
    let lo = 0;
    let hi = angles.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (angles[mid] < a) lo = mid + 1;
      else hi = mid;
    }
    out[p] = lo / angles.length;
  }
  return out;
}

// ---- the processes -----------------------------------------------------------

// The shared start: normalised luminance with clarity, and the clarity itself.
function toneOf(recipe, src, size) {
  const { data, width: w, height: h } = src;
  const n = w * h;
  const [lo, hi] = recipe.range;
  const t0 = new Float32Array(n);
  const a = new Float32Array(n);
  for (let p = 0; p < n; p++) {
    const i = p * 4;
    t0[p] = clamp01((0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2] - lo) / (hi - lo));
    a[p] = data[i + 3] / 255;
  }
  // Spread the tones: silver's are bunched near white (a tenth of its feathers
  // are clipped highlights), which a curve alone would send to the ramp's top.
  // Blend each tone toward its rank among the opaque art's (equalisation).
  if (recipe.equalize) {
    const bins = new Float64Array(257);
    let count = 0;
    for (let p = 0; p < n; p++) {
      if (a[p] < 0.5) continue;
      bins[Math.round(t0[p] * 256)]++;
      count++;
    }
    const cdf = new Float32Array(257);
    let run = 0;
    for (let k = 0; k <= 256; k++) {
      run += bins[k];
      cdf[k] = (run - bins[k] / 2) / count;
    }
    for (let p = 0; p < n; p++) t0[p] = lerp(t0[p], cdf[Math.round(t0[p] * 256)], recipe.equalize);
  }
  // Alpha-weighted, so the transparent surround never darkens an edge.
  const sigma = recipe.clarity.sigma * SCALE[size];
  const ta = t0.map((v, p) => v * a[p]);
  const bt = blur(ta, w, h, sigma);
  const ba = blur(a, w, h, sigma);
  const detail = new Float32Array(n);
  const tone = new Float32Array(n);
  for (let p = 0; p < n; p++) {
    detail[p] = ba[p] > 0.02 ? t0[p] - bt[p] / ba[p] : 0;
    tone[p] = clamp01(t0[p] + recipe.clarity.amount * detail[p]);
  }
  return { tone, detail, alpha: a, alphaBlur: blur(a, w, h, Math.max(0.8, 5 * SCALE[size])) };
}

function metal(recipe, src, size) {
  const { width: w, height: h } = src;
  const out = Buffer.from(src.data);
  const { tone, detail } = toneOf(recipe, src, size);
  for (let p = 0; p < w * h; p++) {
    let t = Math.pow(sCurve(tone[p], recipe.curve), recipe.gamma);
    // The specular rim: where a feather's edge is brighter than its
    // surroundings, push it toward the white top of the ramp.
    if (detail[p] > 0) t = clamp01(t + recipe.specular * detail[p] * (0.4 + t));
    const [r, g, b] = rampAt(recipe.ramp, t);
    out[p * 4] = Math.round(r);
    out[p * 4 + 1] = Math.round(g);
    out[p * 4 + 2] = Math.round(b);
  }
  return out;
}

// The facets: a jittered grid of seeds, each with its own brightness, tint,
// light direction and hue nudge. Per pixel: the nearest seed and how close the
// second nearest is (the facet's edge).
function facetsFor(recipe, name, size, w, h) {
  const cell = Math.max(5, recipe.cell * SCALE[size] * (size === "mini" ? 1.9 : 1));
  const rand = prng(seedOf(recipe.seed ?? name, size));
  const cols = Math.ceil(w / cell) + 2;
  const rows = Math.ceil(h / cell) + 2;
  const seeds = [];
  for (let gy = 0; gy < rows; gy++) {
    for (let gx = 0; gx < cols; gx++) {
      const angle = rand() * Math.PI * 2;
      seeds.push({
        x: (gx - 1 + 0.15 + rand() * 0.7) * cell,
        y: (gy - 1 + 0.15 + rand() * 0.7) * cell,
        bright: (rand() * 2 - 1) * recipe.facet.jitter,
        dx: Math.cos(angle),
        dy: Math.sin(angle),
        tint: rand(),
        tintPick: rand(),
        hue: rand() * 2 - 1,
      });
    }
  }
  return { cell, cols, rows, seeds };
}

function crystal(recipe, name, src, size) {
  const { data, width: w, height: h } = src;
  const out = Buffer.from(data);
  const { tone, detail, alpha, alphaBlur } = toneOf(recipe, src, size);
  const facets = facetsFor(recipe, name, size, w, h);
  const ranks = recipe.rainbow ? angleRanks(data, w, h) : null;
  const edgeWidth = Math.max(0.6, recipe.facet.edgeWidth * (size === "mini" ? 0.7 : 1));
  const edgeAmount = recipe.facet.edge * (size === "mini" ? 0.45 : 1);
  const bright = new Float32Array(w * h);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const p = y * w + x;
      // Nearest and second nearest seed, from the 3 x 3 grid cells round this one.
      const gx = Math.floor(x / facets.cell) + 1;
      const gy = Math.floor(y / facets.cell) + 1;
      let d1 = Infinity;
      let d2 = Infinity;
      let s1 = null;
      for (let oy = -1; oy <= 1; oy++) {
        for (let ox = -1; ox <= 1; ox++) {
          const cx = gx + ox;
          const cy = gy + oy;
          if (cx < 0 || cy < 0 || cx >= facets.cols || cy >= facets.rows) continue;
          const s = facets.seeds[cy * facets.cols + cx];
          const d = Math.hypot(s.x - x, s.y - y);
          if (d < d1) {
            d2 = d1;
            d1 = d;
            s1 = s;
          } else if (d < d2) d2 = d;
        }
      }
      // Light to dark across the facet, toward its own light.
      const shade = ((x - s1.x) * s1.dx + (y - s1.y) * s1.dy) / facets.cell;
      const edge = 1 - smoothstep(0, edgeWidth, d2 - d1);
      // The inner glow: just inside the silhouette, where the blurred alpha
      // falls away from the alpha.
      const rim = clamp01((alpha[p] - alphaBlur[p]) * 3);
      let t = sCurve(tone[p], recipe.curve);
      t = t + s1.bright + recipe.facet.light * shade + recipe.glow * rim;
      t = Math.pow(clamp01(t), recipe.gamma);
      t = clamp01(t + edgeAmount * edge * (0.35 + t) + (detail[p] > 0 ? recipe.sheen * detail[p] : 0));
      bright[p] = t;
      let [r, g, b] = rampAt(recipe.ramp, t);
      if (recipe.tints) {
        const c = hex(recipe.tints.colors[Math.floor(s1.tintPick * recipe.tints.colors.length)]);
        const k = recipe.tints.amount * s1.tint * (1 - Math.pow(t, 4));
        r = lerp(r, c[0] * (0.35 + t), k);
        g = lerp(g, c[1] * (0.35 + t), k);
        b = lerp(b, c[2] * (0.35 + t), k);
      }
      if (ranks) {
        const hue = recipe.rainbow.hues * ranks[p] + recipe.rainbow.cellJitter * s1.hue;
        const [, , l] = rgbToHsl(r, g, b);
        const s = recipe.rainbow.saturation * (1 - Math.pow(t, 5));
        [r, g, b] = hslToRgb(hue, s, l);
      }
      out[p * 4] = Math.round(Math.min(255, Math.max(0, r)));
      out[p * 4 + 1] = Math.round(Math.min(255, Math.max(0, g)));
      out[p * 4 + 2] = Math.round(Math.min(255, Math.max(0, b)));
    }
  }
  addGlints(out, bright, w, h, recipe.glints[size], size);
  return out;
}

// Star glints at the brightest local peaks, spread out, only inside the opaque
// art. Full size: a four-pointed star with a fainter diagonal cross. Mini: a
// bright point with a small halo.
function addGlints(out, bright, w, h, count, size) {
  if (!count) return;
  // A glint shows where a bright point stands out from its surroundings, not
  // in a patch that is already white: score each bright peak by how much
  // brighter it is than its neighbourhood.
  const around = blur(bright, w, h, size === "mini" ? 1.5 : 6);
  const peaks = [];
  for (let y = 2; y < h - 2; y++) {
    for (let x = 2; x < w - 2; x++) {
      const p = y * w + x;
      if (out[p * 4 + 3] < 250 || bright[p] < 0.85) continue;
      if (bright[p] < bright[p - 1] || bright[p] < bright[p + 1] || bright[p] < bright[p - w] || bright[p] < bright[p + w]) continue;
      peaks.push([bright[p] - around[p], x, y]);
    }
  }
  peaks.sort((a, b) => b[0] - a[0] || a[2] - b[2] || a[1] - b[1]);
  const chosen = [];
  const gap = w / (size === "mini" ? 9 : 16);
  for (const [, x, y] of peaks) {
    if (chosen.every(([cx, cy]) => Math.hypot(cx - x, cy - y) > gap)) chosen.push([x, y]);
    if (chosen.length === count) break;
  }
  const paint = (x, y, k) => {
    if (x < 0 || y < 0 || x >= w || y >= h || k <= 0) return;
    const i = (y * w + x) * 4;
    if (out[i + 3] === 0) return;
    for (let c = 0; c < 3; c++) out[i + c] = Math.round(lerp(out[i + c], 255, Math.min(1, k)));
  };
  chosen.forEach(([x, y], n) => {
    paint(x, y, 1);
    if (size === "mini") {
      for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) paint(x + dx, y + dy, 0.55);
      return;
    }
    // Alternate long and short stars, so they don't look stamped.
    const arm = n % 3 === 0 ? 9 : 5;
    for (let d = 1; d <= arm; d++) {
      const k = Math.pow(1 - d / (arm + 1), 1.6);
      for (const [dx, dy] of [[d, 0], [-d, 0], [0, d], [0, -d]]) paint(x + dx, y + dy, k);
      if (d <= arm / 2.5) for (const [dx, dy] of [[d, d], [-d, d], [d, -d], [-d, -d]]) paint(x + dx, y + dy, k * 0.6);
    }
    for (const [dx, dy] of [[1, 1], [-1, 1], [1, -1], [-1, -1]]) paint(x + dx, y + dy, 0.7);
  });
}

// The first pass, for the before/after strip only.
function firstPass(name, src) {
  const recipe = FIRST_PASS[name];
  const { data, width: w, height: h } = src;
  const out = Buffer.from(data);
  const ranks = recipe.rainbow ? angleRanks(data, w, h) : null;
  for (let p = 0; p < w * h; p++) {
    const i = p * 4;
    const L = 0.2126 * data[i] + 0.7152 * data[i + 1] + 0.0722 * data[i + 2];
    const t = Math.pow(clamp01((L - 40) / 215), recipe.gamma);
    let [r, g, b] = rampAt(recipe.ramp, t);
    if (ranks) {
      const [, , l] = rgbToHsl(r, g, b);
      [r, g, b] = hslToRgb(0.8 * ranks[p], recipe.rainbow * (1 - Math.pow(t, 6)), l);
    }
    out[i] = Math.round(r);
    out[i + 1] = Math.round(g);
    out[i + 2] = Math.round(b);
  }
  return out;
}

function render(name, recipe, src, size) {
  return recipe.kind === METAL ? metal(recipe, src, size) : crystal(recipe, name, src, size);
}

async function writeChecked(pixels, src, file) {
  const { width: w, height: h } = src;
  await sharp(pixels, { raw: { width: w, height: h, channels: 4 } }).webp(WEBP).toFile(file);
  // The alpha, exactly as the source's.
  const back = await readRaw(file);
  for (let i = 3; i < src.data.length; i += 4) {
    if (back.data[i] !== src.data[i]) throw new Error(`${path.relative(ROOT, file)}: alpha differs at pixel ${(i - 3) / 4}`);
  }
}

async function makeAll(recipes, dir) {
  mkdirSync(dir, { recursive: true });
  for (const [name, recipe] of Object.entries(recipes)) {
    for (const [size, [w, h]] of Object.entries(SIZES)) {
      const src = await readRaw(sourceFile(recipe.source, size));
      if (src.width !== w || src.height !== h) throw new Error(`${path.relative(ROOT, sourceFile(recipe.source, size))} is ${src.width}x${src.height}`);
      await writeChecked(render(name, recipe, src, size), src, path.join(dir, `${size}-${name}.webp`));
    }
  }
}

// ---- how far apart -----------------------------------------------------------

// How far apart two tiers look at a plate: every tier has the same shape, so
// compare them pixel by pixel, as a 2-player plate draws them (56px wide), and
// average the CIELAB distance (CIE76) over the opaque art. A mean colour
// would hide prismatic's rainbow, which averages out to a near white. Roughly:
// under 10 is hard to tell apart at a glance; over 25 is plainly different.
function toLab([r, g, b]) {
  const lin = (c) => ((c /= 255) <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4));
  const [R, G, B] = [lin(r), lin(g), lin(b)];
  const X = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047;
  const Y = 0.2126 * R + 0.7152 * G + 0.0722 * B;
  const Z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883;
  const f = (t) => (t > 216 / 24389 ? Math.cbrt(t) : (841 / 108) * t + 4 / 29);
  return [116 * f(Y) - 16, 500 * (f(X) - f(Y)), 200 * (f(Y) - f(Z))];
}

async function plateLab(name) {
  const { data } = await sharp(path.join(WINGS, `mini-${name}.webp`))
    .resize(56, 36, { kernel: "lanczos3" })
    .ensureAlpha()
    .raw()
    .toBuffer({ resolveWithObject: true });
  const labs = [];
  for (let i = 0; i < data.length; i += 4) labs.push(data[i + 3] >= 200 ? toLab([data[i], data[i + 1], data[i + 2]]) : null);
  return labs;
}

async function distances() {
  const labs = Object.fromEntries(await Promise.all(LADDER.map(async (t) => [t, await plateLab(t)])));
  const pairs = [];
  for (let i = 0; i < LADDER.length; i++) {
    for (let j = i + 1; j < LADDER.length; j++) {
      const [a, b] = [labs[LADDER[i]], labs[LADDER[j]]];
      let sum = 0;
      let n = 0;
      for (let p = 0; p < a.length; p++) {
        if (!a[p] || !b[p]) continue;
        sum += Math.hypot(a[p][0] - b[p][0], a[p][1] - b[p][1], a[p][2] - b[p][2]);
        n++;
      }
      pairs.push([sum / n, LADDER[i], LADDER[j]]);
    }
  }
  return pairs.sort((x, y) => x[0] - y[0]);
}

// ---- the sheet ---------------------------------------------------------------

// v3: one card per tier (two columns): the label, the full art at its own
// size over felt with a stand-in avatar, the mini file on dark and light, the
// mini art as a 2-player plate draws it (56px round a 28px avatar), and the
// badge dot (11px and 4x). Then the before/after strip (the first pass against
// this one) for bronze and the gems, and the promoted silver, gold and emerald
// beside the originals they replaced.
async function makeSheet() {
  const CARD_W = 1200;
  const CARD_H = 700;
  const COLS = 2;
  const PAIR_H = 420;
  const W = CARD_W * COLS;
  const ladderH = CARD_H * Math.ceil(LADDER.length / COLS);
  const compare = [
    ...Object.keys(FIRST_PASS).map((t) => ({ label: `${t.toUpperCase()}: first pass / this pass`, tier: t, kind: "before" })),
    ...Object.keys(PROMOTED).map((t) => ({ label: `${t.toUpperCase()}: original / live since pass 3`, tier: t, kind: "promoted" })),
  ];
  const compareH = 80 + PAIR_H * Math.ceil(compare.length / COLS);
  const H = 90 + ladderH + compareH;
  const DARK = "#16120e";
  const FELT = "#1f4d33";
  const LIGHT = "#f1e9d8";
  const layers = [];
  const svg = (w, h, body) => Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}">${body}</svg>`);
  const text = (x, y, s, size, fill, weight = 700) =>
    `<text x="${x}" y="${y}" font-family="Arial, Helvetica, sans-serif" font-size="${size}" font-weight="${weight}" fill="${fill}">${s}</text>`;
  const avatar = (d) => svg(d, d, `<circle cx="${d / 2}" cy="${d / 2}" r="${d / 2 - 1}" fill="#7a6a55" stroke="#c9a96b" stroke-width="${Math.max(1, d / 40)}"/>`);
  const box = (w, h, fill) => svg(w, h, `<rect width="${w}" height="${h}" rx="10" fill="${fill}"/>`);
  const dot = (tier, d) => {
    const b = BADGE[tier];
    let defs = "";
    let fill = b;
    let wedges = "";
    if (Array.isArray(b) && b[0] === "linear") {
      defs = `<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${b[1]}"/><stop offset="0.3" stop-color="${b[2]}"/><stop offset="0.65" stop-color="${b[3]}"/><stop offset="1" stop-color="${b[4]}"/></linearGradient></defs>`;
      fill = "url(#g)";
    } else if (Array.isArray(b) && b[0] === "conic") {
      // SVG has no conic gradient: thin wedges round the centre, colour blended.
      const stops = [...b.slice(1), b[1]].map(hex);
      const r = d / 2;
      for (let k = 0; k < 72; k++) {
        const a0 = (k / 72) * 2 * Math.PI - Math.PI / 2;
        const a1 = ((k + 1.2) / 72) * 2 * Math.PI - Math.PI / 2;
        const pos = (k / 72) * (stops.length - 1);
        const i = Math.floor(pos);
        const c = stops[i].map((v, n) => Math.round(lerp(v, stops[i + 1][n], pos - i)));
        wedges += `<path d="M${r},${r} L${r + r * Math.cos(a0)},${r + r * Math.sin(a0)} A${r},${r} 0 0 1 ${r + r * Math.cos(a1)},${r + r * Math.sin(a1)} Z" fill="rgb(${c.join(",")})"/>`;
      }
      fill = "none";
    }
    const edge = (1.5 * d) / 11;
    return svg(
      d,
      d,
      `${defs}<clipPath id="c"><circle cx="${d / 2}" cy="${d / 2}" r="${d / 2}"/></clipPath><g clip-path="url(#c)">${wedges}</g><circle cx="${d / 2}" cy="${d / 2}" r="${d / 2 - edge / 2}" fill="${fill}" stroke="#1a1410" stroke-width="${edge}"/>`
    );
  };
  // Any art (a file, or raw pixels) drawn as the app does: `scale` x the
  // avatar, centred, the avatar's centre at 68.35% of the art's height.
  const asPng = async (art) =>
    typeof art === "string" ? sharp(art).png().toBuffer() : sharp(art.pixels, { raw: { width: art.w, height: art.h, channels: 4 } }).png().toBuffer();
  const place = async (art, d, scale, x, y) => {
    const width = Math.round(d * scale);
    const height = Math.round((width * 695) / 1075);
    const img = await sharp(await asPng(art)).resize(width, height, { kernel: "lanczos3" }).png().toBuffer();
    layers.push(
      { input: img, left: x + Math.round((d - width) / 2), top: y + Math.round(d / 2 - height * CENTRE.y) },
      { input: avatar(d), left: x, top: y }
    );
  };
  const fullAvatar = (w) => Math.round(w * (410 / 1075));

  layers.push({ input: svg(W, 90, text(40, 58, "Nobs! wings ladder v3: the live art (preview, not shipped)", 34, "#f1e9d8")), left: 0, top: 0 });
  for (const [n, tier] of LADDER.entries()) {
    const x0 = (n % COLS) * CARD_W;
    const y0 = 90 + Math.floor(n / COLS) * CARD_H;
    const recipe = LIVE[tier];
    const label = `${(n + 1) * 10} wins: ${tier.toUpperCase()}`;
    const note = recipe ? `${recipe.kind === METAL ? "polished metal" : "crystal"}, made from the ${recipe.source} original` : "original art";
    layers.push({ input: box(CARD_W - 20, CARD_H - 20, "#0f0c09"), left: x0 + 10, top: y0 + 10 });
    layers.push({ input: svg(CARD_W - 40, 60, text(0, 36, label, 34, "#f1e9d8") + text(420, 36, note, 22, "#b9ad96", 400)), left: x0 + 30, top: y0 + 20 });
    layers.push({ input: box(860, 556, FELT), left: x0 + 30, top: y0 + 90 });
    layers.push({ input: path.join(WINGS, `full-${tier}.webp`), left: x0 + 30, top: y0 + 90 });
    const fd = fullAvatar(860);
    layers.push({ input: avatar(fd), left: x0 + 30 + Math.round((860 - fd) / 2), top: y0 + 90 + Math.round(556 * CENTRE.y - fd / 2) });
    const mx = x0 + 910;
    const mini = path.join(WINGS, `mini-${tier}.webp`);
    layers.push({ input: svg(260, 30, text(0, 22, "mini, own size", 20, "#b9ad96", 400)), left: mx, top: y0 + 90 });
    layers.push({ input: box(260, 140, DARK), left: mx, top: y0 + 120 });
    layers.push({ input: mini, left: mx + 46, top: y0 + 135 });
    layers.push({ input: box(260, 140, LIGHT), left: mx, top: y0 + 270 });
    layers.push({ input: mini, left: mx + 46, top: y0 + 285 });
    layers.push({ input: svg(260, 30, text(0, 22, "at a plate (28px avatar)", 20, "#b9ad96", 400)), left: mx, top: y0 + 425 });
    layers.push({ input: box(125, 80, DARK), left: mx, top: y0 + 455 });
    layers.push({ input: box(125, 80, LIGHT), left: mx + 135, top: y0 + 455 });
    await place(mini, 28, 2, mx + 48, y0 + 480);
    await place(mini, 28, 2, mx + 135 + 48, y0 + 480);
    layers.push({ input: svg(260, 30, text(0, 22, "badge dot, 11px / 4x", 20, "#b9ad96", 400)), left: mx, top: y0 + 555 });
    layers.push({ input: box(260, 70, DARK), left: mx, top: y0 + 590 });
    layers.push({ input: avatar(28), left: mx + 20, top: y0 + 611 });
    layers.push({ input: dot(tier, 11), left: mx + 20 + 17, top: y0 + 611 + 17 });
    layers.push({ input: dot(tier, 44), left: mx + 90, top: y0 + 603 });
  }

  // The comparisons: each pair at half size (430 x 278) over felt, and at a
  // plate on dark.
  const cy0 = 90 + ladderH;
  layers.push({ input: svg(W, 80, text(40, 54, "Before / after (first pass, pass 2) and the promoted silver, gold and emerald beside their originals", 30, "#f1e9d8")), left: 0, top: cy0 });
  const srcFull = await readRaw(sourceFile("silver", "full"));
  const srcMini = await readRaw(sourceFile("silver", "mini"));
  for (const [n, item] of compare.entries()) {
    const x0 = (n % COLS) * CARD_W;
    const y0 = cy0 + 80 + Math.floor(n / COLS) * PAIR_H;
    let left;
    let right;
    let leftMini;
    let rightMini;
    if (item.kind === "before") {
      left = { pixels: firstPass(item.tier, srcFull), w: srcFull.width, h: srcFull.height };
      leftMini = { pixels: firstPass(item.tier, srcMini), w: srcMini.width, h: srcMini.height };
    } else {
      left = sourceFile(item.tier, "full");
      leftMini = sourceFile(item.tier, "mini");
    }
    right = path.join(WINGS, `full-${item.tier}.webp`);
    rightMini = path.join(WINGS, `mini-${item.tier}.webp`);
    layers.push({ input: box(CARD_W - 20, PAIR_H - 20, "#0f0c09"), left: x0 + 10, top: y0 + 10 });
    layers.push({ input: svg(CARD_W - 40, 50, text(0, 32, item.label, 26, "#f1e9d8")), left: x0 + 30, top: y0 + 18 });
    for (const [k, art] of [left, right].entries()) {
      const bx = x0 + 30 + k * 450;
      layers.push({ input: box(430, 278, FELT), left: bx, top: y0 + 70 });
      const img = await sharp(await asPng(art)).resize(430, 278, { kernel: "lanczos3" }).png().toBuffer();
      layers.push({ input: img, left: bx, top: y0 + 70 });
      const fd = fullAvatar(430);
      layers.push({ input: avatar(fd), left: bx + Math.round((430 - fd) / 2), top: y0 + 70 + Math.round(278 * CENTRE.y - fd / 2) });
    }
    for (const [k, art] of [leftMini, rightMini].entries()) {
      layers.push({ input: box(110, 120, DARK), left: x0 + 950, top: y0 + 70 + k * 140 });
      await place(art, 28, 2, x0 + 950 + 41, y0 + 70 + k * 140 + 46);
    }
    layers.push({ input: svg(220, 40, text(0, 26, "at a plate", 18, "#b9ad96", 400)), left: x0 + 1070, top: y0 + 120 });
  }
  mkdirSync(path.dirname(SHEET), { recursive: true });
  await sharp({ create: { width: W, height: H, channels: 4, background: DARK } })
    .composite(layers)
    .png({ compressionLevel: 9 })
    .toFile(SHEET);
}

// ---- run ---------------------------------------------------------------------

const check = process.argv.includes("--check");
await makeAll(LIVE, WINGS);
console.log(`made ${Object.keys(LIVE).length * 2} files in public/wings (alpha checked against docs/art/sources)`);
if (!check) {
  await makeSheet();
  console.log(`approval sheet: ${path.relative(ROOT, SHEET)}`);
}
console.log("closest tiers at a plate (56px wide; mean per-pixel CIELAB distance):");
const all = await distances();
for (const [d, a, b] of all.slice(0, 8)) console.log(`  ${a} / ${b}: ${d.toFixed(1)}`);
for (const [a, b] of [["silver", "diamond"], ["white", "silver"], ["white", "diamond"], ["bronze", "gold"], ["bronze", "ruby"], ["emerald", "sapphire"]]) {
  const hit = all.find(([, x, y]) => (x === a && y === b) || (x === b && y === a));
  console.log(`  watched: ${a} / ${b}: ${hit[0].toFixed(1)}`);
}
