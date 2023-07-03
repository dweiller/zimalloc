# zimalloc

zimalloc is general purpose allocator for Zig, inspired by [mimalloc](https://github.com/microsoft/mimalloc).

## Status

This project is under development and should currently be considered experimental/exploratory; there
is no documentation and it has not been battle-tested. In particular there may be issues with
multi-threaded workloads. Contributions of any kind (PRs, suggestions for improvements, resources or
ideas related to benchmarking or testing) are welcome.

The allocator is significantly faster than `std.heap.GeneralPurposeAllocator(.{})` but should not
(yet) be expected to be competitive with other established general purpose allocators.

## Usage

To use the allocator in your own project you can use the Zig package manager by putting this in your
`build.zig`
```zig
pub fn build(b: *std.Build) void {
    // -- snip --
    const zimalloc = b.dependency("zimalloc").module("zimalloc"); // get the zimalloc module
    // -- snip --
    exe.addModule(zimalloc); // add the zimalloc module as a depenency of exe
    // -- snip --
}
```
and this to the dependencies section of your `build.zig.zon`
```zig
    .zimalloc = .{
        .url = "https://github.com/dweiller/zimalloc/archive/[[COMMIT_SHA]].tar.gz"
    },
```
where `[[COMMIT_SHA]]` should be replaced with full SHA of the desired revision. You can then import
and initialise an instance of the allocator as follows:
```zig
const zimalloc = @import("zimalloc");
pub fn main() !void {
    var gpa = try zimalloc.Allocator(.{}){};
    defer gpa.deinit();

    const allocator = gpa.allocator();
    // -- snip --
}
```

### Shared library

There is a shared library that can be used for overriding standard libc allocation functions.
It can be accessed from your `build.zig` like so:
```zig
pub fn build(b: *std.Build) void {
    // -- snip --
    const libzimalloc = b.dependency("zimalloc").artifact("zimalloc"); // get the zimalloc shared library
    // -- snip --
    exe.linkLibrary(zimalloc); // link to libzimalloc
    // -- snip --
}
```

If you just want to build the shared library and use it outside the Zig build system, you can build
it with the `libzimalloc` or `install` steps, for example:
```sh
zig build libzimalloc -Doptimize=ReleaseSafe
```

## Notes

  - The current implementation works on Linux, with other systems untested.
  - There are likely still data races present in multi-threaded workloads.
  - The main suite of tests currently used is `https://github.com/daanx/mimalloc-bench`
    which are run using `LD_PRELOAD`. Tests that have been observed to fail are `redis`, `lua`,
  `rptest`, `rbstress`—some only fail intermitently.
  - No attempt has been made to make the allocator signal-safe.
