# Vendored: chesskit-engine

This directory is a **flat-vendored** copy of [chesskit-app/chesskit-engine](https://github.com/chesskit-app/chesskit-engine).

- Upstream: <https://github.com/chesskit-app/chesskit-engine>
- Pinned version: **0.7.0** (commit `a2b4769`)
- Includes submodules (also flat-vendored):
  - Stockfish (`a2b4769` upstream, commit `23f320b` in submodule)
  - lc0 (`a78b208c`)
  - lczero-common (`55e1b382`)

## Why vendored

`xcodebuild -resolvePackageDependencies` fails to clone chesskit-engine's git
submodules in some sandboxed Bash environments (`fatal: Unable to read current
working directory`). Vendoring as flat source eliminates the SPM submodule step
and lets the build proceed reliably.

## How to upgrade

```sh
# in this LiveChess project root:
rm -rf Packages/chesskit-engine
git clone --recurse-submodules \
  https://github.com/chesskit-app/chesskit-engine.git \
  Packages/chesskit-engine
git -C Packages/chesskit-engine checkout <new-tag>
git -C Packages/chesskit-engine submodule update --init --recursive
# strip nested .git so the outer repo stays a single tree:
find Packages/chesskit-engine -name '.git' -exec rm -rf {} +
```
