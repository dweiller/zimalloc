# zimalloc

zimalloc is general purpose allocator for Zig, inspired by [mimalloc](https://github.com/microsoft/mimalloc).

## WIP

This project is under development and should currently be considered experimental/exploratory; there is no documentation and it is not well tested. There are likely a variety of issues—contributions of any kind (PRs, suggestions for improvements, resources or ideas related to benchmarking or testing) are welcome.

## Usage

To use the allocator in your own project you can use the Zig package manager by putting this in your `build.zig`
```zig
pub fn build(b: *std.Build) void {
    // -- snip --
    const mesh = b.dependency("zimalloc").module("zimalloc"); // get the zimalloc module
    // -- snip --
    exe.addModule(mesh); // add the zimalloc module as a depenency of exe
    // -- snip --
}
```
and this to the dependencies section of your `build.zig.zon`.
```zig
    .zimalloc = .{
        .url = "https://github.com/dweiller/zimalloc/archive/[[COMMIT_SHA]].tar.gz"
    },
```
where `[[COMMIT_SHA]]` should be replaced with full SHA of the desired revision. You can then import and
initialise an instance of the allocator as follows:
```zig
const zimalloc = @import("zimalloc");
pub fn main() !void {
    var gpa = try zimalloc.Allocator.init(.{});
    defer gpa.deinit();

    const allocator = gpa.allocator();
    // -- snip --
}
```

## Notes

  - the current implementation works on Linux, with other systems untested
  - little consideration has been given to multi-threaded use so far and there are likely races present
