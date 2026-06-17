#!/usr/bin/env bash

set -xeuo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
EXE="connector"

mkdir -p "$PREFIX/bin"
ln -sf "$PWD/$EXE" "$PREFIX/bin/$EXE"
ln -sf "$PWD/$EXE" "$PREFIX/bin/con"   # short 'con' shortcut
