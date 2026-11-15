# Wings art (generated for Nobs!)

All images are WebP with transparency. Every image of a kind has the same aspect ratio (1075 x 695 design units).

- full-white/silver/gold/emerald/black.webp  860 x 556  Profile, milestone splash (avatar width = image width x 0.381)
- full-ears.webp                     860 x 556  the creator's ears (in place of wings), same anchors as the others
- full-black-ember.webp              overlay for black, pulse its opacity
- mini-*.webp                        168 x 109  table-size wings (draw at 2.0 x avatar diameter wide), the ears included
- mini-black-ember.webp              the same overlay at table size, for black
- black-flames.json                  flame shapes, gradients, embers for the black tier (full size only)

Avatar centre inside every image: x = 50%, y = 475/695 = 68.35% from the top (extra headroom above is for flames).
Avatar diameter in the full image = 410/1075 = 38.1% of image width. Wings reach about 0.8 avatar-widths beyond each avatar edge.

The creator tier (lib/wings.ts, CREATOR_USER_IDS) shows a pair of green ears instead of wings: no flames, no embers, no glow (hasFlames is black only, and WINGS_HALO.creator is null). It keeps its bright green badge dot (#2ee07a; the emerald tier's dot is a deeper #0f9d58).

## The ten tiers (branch wings-ladder)

One tier every 10 God wins: white, bronze, silver, gold, emerald, sapphire, ruby, diamond, prismatic, black. Each tier's art is full-<file>.webp and mini-<file>.webp, with <file> from WINGS_ART in lib/wings.ts. Flames stay the black tier's only.

- Untouched originals, served as they are: white, black (with its ember overlays and flames) and the creator's ears.
- The sources, docs/art/sources/ (never served, never written by the script): Walt's originals of silver, gold and emerald, moved there from public/wings in art pass 3, before the live files were replaced: full-|mini-silver-original.webp, full-|mini-gold-original.webp, and full-|mini-emerald-original.webp, the old creator's metallic green wings, restored unchanged from bc1ee3b^:public/wings/full-green.webp and mini-green.webp (69,964 and 7,188 bytes; a recolour of the silver art, always plain images: their flames were drawn by code).
- Made, by `node scripts/make-wings-tiers.mjs` (sharp, which comes with Next), always from the sources, so a rerun never reworks an already reworked file:

  | Tier | Source | Process |
  |---|---|---|
  | bronze | silver original | polished metal |
  | silver | silver original | polished metal, subtler (promoted in pass 3) |
  | gold | gold original | polished metal, subtler (promoted in pass 3) |
  | emerald | emerald (green) original | crystal (promoted in pass 3; facets seeded as "emerald-crystal") |
  | sapphire, ruby, diamond, prismatic | silver original | crystal |

  Only the source's luminance and alpha are read; the alpha is copied byte for byte and checked after encoding (scripts/test-phase3.ts checks it again against the sources); WebP quality 90, alpha lossless. Deterministic: a fixed-seed PRNG, no clock, so a rerun writes identical bytes. Silver's tones are bunched near white, so both processes first spread them (blended toward histogram equalisation).
  - Polished metal: local contrast at about a feather's scale (luminance minus its alpha-weighted blur, added back), a gentle S-curve, a specular lift where that contrast is bright (each feather's edge catches a rim), then a multi-stop map from a near-black shadow through the metal's colours to a pale top; bronze runs through copper and orange to peach, white only at the very top.
  - Crystal: the same local contrast, plus Voronoi facets (a seeded jittered grid, about 30px cells at full size, coarser at mini), each facet with its own brightness, tint and light-to-dark ramp, thin bright lines where facets meet, an inner glow just inside the silhouette, a gem map with deep saturated bodies and near-white tops, and star glints where a bright point stands out from its surroundings (small bright points at mini). Diamond is a cool blue-white with bigger jumps between facets and faint dispersion tints; prismatic keeps the rainbow fan by feather angle, under the facets. At a plate (56px) the facets mostly blur away; what reads there is the bright, broken highlights.
  - The recipes (ramps, curves, facet sizes) are at the top of the script; rerun it after changing one.
- The pass-2 candidates (docs/art/candidates/) were removed in pass 3: Walt approved them, the script now writes them as the live silver, gold and emerald (byte-identical to the candidates), and their originals are kept in docs/art/sources.
- The approval sheets (not served): docs/art/wings-ladder-preview-v1.png, the first pass (plain gradient maps); -v2.png, pass 2 with the candidates; -v3.png, written by the script now: all ten live tiers at full size, the mini file on dark and light, as a 2-player plate draws it (56px round a 28px avatar), the 11px badge dot, a before/after strip (first pass against pass 2) for bronze and each gem, and the promoted silver, gold and emerald beside their originals. `--check` remakes the files without the sheet; both print the closest pairs at a plate (mean per-pixel CIELAB distance at 56px).
- Caching: the file names never change, and needn't: Vercel serves public/ with `Cache-Control: public, max-age=0, must-revalidate` and an ETag of the file's hash, so browsers re-check each image and get a changed one on the next load (see the comment on wingsUrl in lib/wings.ts).
- The milestone splash's full art also shows on the Home screen now (its catch-up for the new milestones, 20 to 90), so each new tier's full-<tier>.webp is seen there as well as on Profile and at a table.

## The creator's ears

The ears art was made by Walt. Source: docs/art/ears-source.png (2150 x 1390, transparent PNG, the wings' 1075 x 695 canvas at twice the size, avatar centre at 1075, 950); it is kept outside public/ so it is not served. full-ears.webp and mini-ears.webp were made from it with sharp (Lanczos downscale; WebP quality 90, alpha quality 100). The art includes a thin green ring round the avatar: at full size (Profile) it shows as a rim just outside the avatar; at the mini sizes (avatar 45-71% of the art's width) the avatar covers it and only the ears show, and on 3-player plates (1.4 x) only the ear tips. Replaced the earlier metallic green wings (full-green.webp, mini-green.webp, removed; back since as the emerald tier's art).
