#!/bin/sh

zig build libzimalloc -Doptimize=ReleaseSafe -Dlog-level=debug -Dverbose-logging
zig build libzimalloc -Doptimize=ReleaseSafe -p zig-out-safe
zig build libzimalloc -Doptimize=ReleaseFast -p zig-out-fast
