# Flowyr

![](logo-rounded.png)

Flowyr is a PlayStation Vita emulator for iPhone and iPad, running on iOS 26 and newer. It is built around a native SwiftUI interface on top of the Vita3K emulator core, and it is set up to work on 3 GB devices such as the iPhone SE (2nd generation).

This is a hobby project and it is experimental. Some games run well, some have graphical problems, and some do not run at all.

## Where it comes from

Flowyr is a fork of [Veeb](https://github.com/veebteam/Veeb), which is itself a fork of [Vita3K](https://vita3k.org/). Nearly all of the hard work, understanding and emulating the Vita's hardware and operating system, was done by the Vita3K developers and contributors. Veeb brought that core to iOS. Flowyr keeps that foundation and changes the app around it and a few things underneath. The credits at the bottom list the people and projects it depends on.

## What is different

On the app side:

- A rebuilt library with a game carousel, search, favorites and a floating action bar
- A library and menus you can navigate with a game controller
- A pause menu with per-game settings, available from inside a running game
- A trophy browser, plus unlock banners while you play
- On-screen controls you can move, resize and fade, saved separately for portrait and landscape, globally or per game
- Dynamic analog sticks that appear under your thumb in empty parts of the screen
- A performance overlay showing FPS, memory use, battery and device temperature
- Installing PKG files, `work.bin` and zRIF licenses, firmware and game archives from the in-app import menu
- Themes: Flowyr, Vita, Dark and Light
- English and Brazilian Portuguese

On the emulator side:

- A software page-table memory mode that lets the emulator start when iOS will not give it the usual 4 GiB address space reservation. This is what makes 3 GB phones usable. It is selected automatically, and can also be forced per game.
- GPU memory settings tuned for iOS limits, a half-resolution texture option, and a per-game 30 FPS cap to save memory and heat
- Logging that is capped in size, with memory use recorded while a game runs

## 3 GB devices

Flowyr is developed and tested on an iPhone SE (2nd generation), which has 3 GB of RAM and no room to spare. iOS ends an app that uses too much memory, so a heavy game can still be closed by the system after a while. Lowering the internal resolution, turning on half-resolution textures or capping the game at 30 FPS helps. Some games cannot be made to fit.

Newer phones with more memory have more headroom, but they have not had the same amount of testing.

## Known problems

- J-Stars Victory VS+: characters do not render on the iPhone SE (2nd generation). Some of its shaders write to memory, which needs a GPU feature that is switched off on iOS. People report the same problem on some Mali GPUs on Android.
- Compatibility depends heavily on the game. Check that a title works before assuming it will.

## Installing

The GitHub Actions workflow builds an unsigned IPA on every push. Download it from the workflow run's artifacts, then sign and install it with a sideloading tool of your choice. Flowyr uses its own bundle identifier, so it installs next to other builds and does not share their games or saves.

Building it yourself needs full Xcode and a Mac. See [building.md](building.md).

## JIT

Vita emulation needs JIT compilation to be fast enough. iOS does not allow JIT for normal apps, so Flowyr relies on StikDebug to attach a debugger at launch. Open Flowyr through StikDebug with the Universal script. The lightning bolt in the top bar glows green once JIT is connected. Setup and pairing are covered in the StikDebug documentation.

## Getting started

1. Open Flowyr through StikDebug and wait for the bolt to turn green.
2. Use the plus button to import the PlayStation Vita firmware you obtained from your own console.
3. Import your games from VPK, ZIP or PKG files, or folders. Games that need a license key can be added with `work.bin` or a zRIF string from the same menu.
4. Pick a game from the library. Per-game settings are in the pause menu while the game runs.

## Requirements

- iOS 26 or newer
- An arm64 iPhone or iPad
- JIT through StikDebug or an equivalent method

## Contributing

Bug reports with a log and the game's title ID are the most useful thing you can send. Pull requests are welcome.

Changes to shared emulator behavior should not fix one game at the cost of another. If a workaround only makes sense for one title, scope it to that title's ID and leave a comment saying which game needs it and why.

## Legal

Flowyr does not include PlayStation Vita firmware, system files, encryption keys, games or any other Sony software. You are responsible for getting those from hardware and software you own, in line with the laws where you live.

PlayStation and PlayStation Vita are trademarks of Sony Interactive Entertainment. Flowyr is not affiliated with or endorsed by Sony.

## Credits

- The [Vita3K](https://vita3k.org/) developers and contributors, for the emulator everything here is built on
- The [Veeb](https://github.com/veebteam/Veeb) team, for the iOS port Flowyr started from
- [Vita3K Plus](https://github.com/nckstwrt/Vita3K-Plus) and its contributors, for game-specific compatibility fixes
- The StikDebug developers, for the JIT workflow it depends on
- Everyone who tests games and reports bugs

## License

Flowyr is derived from Vita3K and is distributed under the same license, GPLv2. See `COPYING.txt` for the full text and the original copyright notices.
