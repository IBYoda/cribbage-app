# Wings art (generated for Nobs!)

All images are WebP with transparency. Every image of a kind has the same aspect ratio (1075 x 695 design units).

- full-white/silver/gold/black.webp  860 x 556  Profile, milestone splash (avatar width = image width x 0.381)
- full-green.webp                    860 x 556  the creator's wings (metallic green), same anchors as the others
- full-black-ember.webp              overlay for black and the creator's green, pulse its opacity
- mini-*.webp                        168 x 109  table-size wings (draw at 2.0 x avatar diameter wide), green included
- mini-black-ember.webp              the same overlay at table size, for black and green
- black-flames.json                  flame shapes, gradients, embers for the black tier and the creator's (full size only)

Avatar centre inside every image: x = 50%, y = 475/695 = 68.35% from the top (extra headroom above is for flames).
Avatar diameter in the full image = 410/1075 = 38.1% of image width. Wings reach about 0.8 avatar-widths beyond each avatar edge.

The creator tier (lib/wings.ts, CREATOR_USER_IDS) uses the green art with the black tier's flames, embers and glow, so it has no flame or ember files of its own.
