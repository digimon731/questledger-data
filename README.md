# Quest Ledger data

Shared quest data for the WoW Forever addon **Quest Ledger**: the exact XP, money and rewards of quests, as recorded by players in game.

The addon cannot reach the internet, so data is shared by copy and paste. Approved submissions are merged here and bundled with the next Quest Ledger release, so every player sees complete rewards without visiting the quest giver first.

## Share your data
1. In game, click **Share data** in the Quest Ledger window, or type `/ql export`.
2. The text is already selected: press **Ctrl+C**.
3. Open a [new data submission](../../issues/new?template=share-data.yml), paste with **Ctrl+V** and submit.

The submission is checked automatically within a minute and gets a reply. If something is wrong, edit the issue and paste the text again: it is checked again.

## Privacy
- **What the export contains:** quest IDs, quest level, suggested group size, XP with the player level it was seen at, money (and the money paid at max level), the player level of the last turn-in with the XP and money it paid, reward item IDs and counts, and which faction (A/H) saw the quest. The header line has the addon version, the game client version and the client language.
- **What it does not contain:** character, realm, guild or account names, quest names, or anything about your character apart from its level when the XP was seen.
- **What is stored:** only the numbers above, combined with every other submission in [data/observations.txt](data/observations.txt). Header details and everything else in the issue are not stored.
- **GitHub issues are public** and show the GitHub username of whoever opens them. If you pasted something private by mistake, edit the issue to remove it and ask for the issue to be deleted.
- The automatic reply never repeats the text of an issue.

## How submissions are merged
1. The [Data submission](.github/workflows/submission.yml) workflow checks every issue that contains an export: the header, the check line (so cut-off or edited text is rejected), and that every value is a plausible number.
2. A maintainer reviews the submission and adds the **approved** label.
3. The workflow adds every record as one report in `data/observations.txt`, rebuilds `data/SharedData.lua`, commits it, and closes the issue.

When reports disagree, the value reported most often wins. For XP, the report from the lowest player level wins, because quests give less XP once you out-level them.

## Files
- `data/observations.txt`: every reported value with the number of times it was reported.
- `data/SharedData.lua`: generated from the observations; copied into Quest Ledger at release time. Do not edit it by hand.
- `scripts/submission.ps1`: validation and merging (PowerShell 7 or Windows PowerShell 5.1).
  `./scripts/submission.ps1 -Mode validate -BodyFile issue.txt` checks a text file,
  `-Mode build` rebuilds `SharedData.lua`.

## Terms
By submitting data you agree that it may be published in this repository and included in Quest Ledger. Quest Ledger itself is not open source; see its own license.
