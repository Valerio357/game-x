#!/usr/bin/env bash
# Wrapper: lo script canonico vive dentro il target GameXCore, così viene
# incluso nel bundle dell'app (e `gx runtime build-gptk` lo trova via Bundle.module).
exec /bin/bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/../Sources/GameXCore/Resources" && pwd)/build-runtime-gptk.sh" "$@"
