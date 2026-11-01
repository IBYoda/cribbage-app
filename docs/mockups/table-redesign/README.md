# Square table redesign: mockups

These are the design references for the square-table redesign (see the PRD item "Square table redesign (planned)"). They are screenshots of mock table states, cropped to the table area. They are **illustrative**: card values, hand sizes and scores are placeholders, not rules. Where a screenshot and the PRD text disagree on layout or rotation, the screenshot is the authority; where they disagree on game rules, the existing game logic is the authority.

Phone portrait, about 500 px wide. Players in every mockup: Yoda (you, bottom), Normie, and in the 4-player shots Shortbus (left) and God (right).

## Files

| File | Players | Dealer | What it shows |
|---|---|---|---|
| 01-2p-start-of-pegging-you-deal.png | 2 | You | Start of pegging. Count 10 with the "Your turn" pill in the center. Normie's played 10 of hearts sits in front of Normie. Your crib is bottom-left (left of your hand), the face-down deck bottom-right. |
| 02-2p-pegging-you-deal-starter-on-deck.png | 2 | You | Count 15, "Yoda +2 fifteen" pill. Your played 5 of hearts sits in front of you above your hand. The starter card (6 of clubs, "Starter" label) sits where the deck was, i.e. the starter is shown on top of the deck at your right. |
| 03-2p-pegging-opponent-deals.png | 2 | Normie (across) | Same moment as 02, but Normie deals. The crib is top-right (on your right, which is the across player's left) and the starter (king of diamonds) is top-left (the across player's right). |
| 04-4p-pegging-left-player-deals.png | 4 | Shortbus (left) | Normie top, Shortbus left, God right, you bottom. Count 15 in the center, each player's played card in front of them, side players' cards turned sideways to face them. Shortbus's crib is at the top of their side, the starter at the bottom of it. Side hands are vertical stacks of card backs. |
| 05-4p-pegging-right-player-deals.png | 4 | God (right) | Same state, but God deals: God's crib is at the bottom of their side and the starter at the top of it. |

## Layout rules these mockups follow

- Everyone faces the center of the table. From each player's own point of view the crib is on the left of their hand and the deck (which shows the starter once turned) is on the right. Only the dealer's seat shows the piles.
  - You (bottom): crib bottom-left, deck bottom-right.
  - Left player: crib top, deck bottom.
  - Across player: crib on your right, deck on your left.
  - Right player: crib bottom, deck top.
- Each player's played pegging cards sit in front of them, turned to face them (side players sideways, across player upside down). The running count and score pill sit in the center.
- A 3-player game is the 4-player layout with the across seat empty.
- The wooden cribbage board strip above the score plates is part of the design, not a placeholder: it stays, sized and placed as shown, with the plates beneath it.
- Other players' hands and played cards are intentionally drawn smaller than your own hand.

## Known gaps in these mockups (do not copy these as-is)

- The bottom score plates were not updated: they show only Yoda and Normie and still carry a "D" badge. The redesign removes the D token everywhere; 4 players get a single row of four plates (icon + score only), grouped by team in Teams mode.
- The orange "D" badge on the crib pile is also being removed. The crib's seat is the dealer indicator.
- Hand sizes (6 cards, side stacks of 6) are placeholders.
- Only one played card per player is shown. Late pegging needs overlapping cards in play order, newest on top (not mocked yet).
- Not mocked yet: the discard-to-crib screen, the counting phase (hands flip in place), the dealing animation.
- The round "N" in the bottom-left corner is the Next.js dev indicator, not part of the design.
