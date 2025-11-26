#!/usr/bin/env bash

set -xeuo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
EXE="connector"

ln -s "$PWD/$EXE" "$PREFIX/bin/"
