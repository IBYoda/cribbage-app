# Wings art (generated for Nobs!)

All images are WebP with transparency. Every image of a kind has the same aspect ratio (1075 x 695 design units).

- full-white/silver/gold/black.webp  860 x 556  Profile, milestone splash (avatar width = image width x 0.381)
- full-ears.webp                     860 x 556  the creator's ears (in place of wings), same anchors as the others
- full-black-ember.webp              overlay for black, pulse its opacity
- mini-*.webp                        168 x 109  table-size wings (draw at 2.0 x avatar diameter wide), the ears included
- mini-black-ember.webp              the same overlay at table size, for black
- black-flames.json                  flame shapes, gradients, embers for the black tier (full size only)

Avatar centre inside every image: x = 50%, y = 475/695 = 68.35% from the top (extra headroom above is for flames).
Avatar diameter in the full image = 410/1075 = 38.1% of image width. Wings reach about 0.8 avatar-widths beyond each avatar edge.

The creator tier (lib/wings.ts, CREATOR_USER_IDS) shows a pair of green ears instead of wings: no flames, no embers, no glow (hasFlames is black only, and WINGS_HALO.creator is null). It keeps its emerald badge dot.

## The creator's ears

The ears art was made by Walt. Source: docs/art/ears-source.png (2150 x 1390, transparent PNG, the wings' 1075 x 695 canvas at twice the size, avatar centre at 1075, 950); it is kept outside public/ so it is not served. full-ears.webp and mini-ears.webp were made from it with sharp (Lanczos downscale; WebP quality 90, alpha quality 100). The art includes a thin green ring round the avatar: at full size (Profile) it shows as a rim just outside the avatar; at the mini sizes (avatar 45-71% of the art's width) the avatar covers it and only the ears show, and on 3-player plates (1.4 x) only the ear tips. Replaced the earlier metallic green wings (full-green.webp, mini-green.webp, removed).
