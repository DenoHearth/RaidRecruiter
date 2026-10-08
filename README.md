# Raid Recruiter

Raid leader's window for WoW: Forever. LFG feed: who is posting LFG, LFM and trade in your channels, with whisper and invite buttons. Recruiting: your LFM message to the channels you pick, and everyone who whispers you in a sortable list with item level and role. Roles, class check, loot rolls with hand-out by master loot or trade, and a pull timer. /rr

[![Latest release](https://img.shields.io/github/v/release/DenoHearth/RaidRecruiter?label=download&style=for-the-badge)](https://github.com/DenoHearth/RaidRecruiter/releases/latest)

A World of Warcraft: Forever addon (interface 16001).

## What it does

One window for building and running a raid or a dungeon group, written for World of
Warcraft: Forever and its addon rules. `/rr` opens it.

- **LFG feed:** everyone posting LFG, LFM, guild recruitment or trade in the channels you
  are in: who, which dungeon or raid (classic and Forever's own), which roles they ask for,
  the message. Filter by kind, by role (tank, healer, DPS) and by dungeons or raids; sort by
  newest or by dungeon; search. Boost and carry ads are hidden by default. Whisper, Who and
  Invite on every row; right-click hides a player for 30 minutes. Guild mates and friends are
  starred and listed first; people on your ignore list never show. It only reads chat.
- **Recruiting:** write your LFM message, tick the channels, set the interval. Everyone who
  whispers you lands in a sortable list with item level, level and role taken from what
  they wrote. Invite, whisper or remove from the row. Someone who joins and leaves comes
  off the list until they whisper again.
- **Roles:** who in the group is tank, healer or DPS (orange, green, red), set by hand or
  asked for with a class check in a raid warning. "Ask the missing" calls out the people
  who have not said.
- **Loot rolls:** put a drop up for roll in /rw, see who rolled what, hand it to the winner
  by master loot or by trade from your bags.
- **Pull timer:** counts the raid down in raid warnings.

## Posting on Forever

Forever does not let an addon post to public channels on a timer. So the first post goes
out when you press Start, and each later one waits: when it is due you get a "Post LFM now"
prompt and a sound. Click it, or press the key you bind under Key Bindings > Raid Recruiter.

## Install

- **CurseForge:** search for Raid Recruiter in the CurseForge app under WoW: Forever.
- **By hand:** download the zip from the
  [latest release](https://github.com/DenoHearth/RaidRecruiter/releases/latest) and extract
  the `RaidRecruiter` folder into `World of Warcraft\<Forever folder>\Interface\AddOns\`.
  Restart the game.

## Commands

- `/rr` opens the window. `/rr stop` ends posting. `/rr pull 10` starts a pull timer.

## Limits

- Roles come only from what players say; nothing is guessed from gear or spec.
- The LFG feed reads chat channels, not the game's own group listing tool.
- Built before the game's launch against the beta's interface files and an offline
  simulator. Loot hand-out, trade and channel posting have not been run in the live game yet.

## Ascension version

Versions up to 2.6 were written for the Project Ascension 3.3.5 client. That code is kept
on the [`ascension`](https://github.com/DenoHearth/RaidRecruiter/tree/ascension) branch.


## Compatibility

- World of Warcraft: Forever, interface version **16001**.
- Forever only. It uses that client's API and will not load on retail or the Classic clients.

## Changelog

What changed in each version: [CHANGELOG.md](CHANGELOG.md).

## License

MIT — see [LICENSE](LICENSE).  Current version: 3.1.0.
