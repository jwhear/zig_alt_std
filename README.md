# alt_std
The Zig languages is deliberately postponing serious development of the standard library until the language has stabilized.  As a result, the current standard library largely contains only the things needed for development of the core infrastructure.  This library is a parking place for useful functionality that will likely qualify for inclusion in a standard library.

## Documentation
[Online docs](https://jwhear.github.io/zig_alt_std/index.html#root) are built automatically from the master branch.

## Usage
The modules in this library do not have any dependencies except the Zig standard library itself.  You can include this library in your project with zigmod by:
1. Run `zigmod init` in your project root
2. Add a dependency to `zigmod.yml`:
   ```yaml
   dependencies:
       - src: git https://github.com/jwhear/zig_alt_std
   ```
3. Run `zigmod fetch`
4. Add deps handling to your executable/library in `build.zig`:
   ```zig
   const deps = @import("./deps.zig");

   // Further down, before exe.install()
   deps.addAllTo(exe);
   ```
5. In your code, import with `@import("alt_std")`


## Modules
### alt_std.algorithm
Contains the functions expected in an algorithm module (ala C++ STL/D/etc).  All functions are constrained to operate on slices as the language has not settled on a standardized interface for iterators or ranges.  Note that the current `std.mem` module includes a number of things that would normally go in this module (e.g. `startsWith`, `count`, etc.) and no effort is made to replace/copy these.

### alt_std.allocators
Contains allocators that are either useful on their own or as building blocks of more sophisticated composite allocators.  These should complement and work with those already in `std.heap`.

### alt_std.levenshtein
Algorithms for computing the Levenshtein edit distance between two strings.  Most users should use `alt_std.levenshtein.distance` for the most flexible and general-purpose implementation.  If you don't need custom edit costs and can guarantee your strings will be 64 bytes or less in length (a reasonable limitation for human languages), the `alt_std.levenshtein.distance64` does not allocate, cannot fail, and is ~13x faster than most implementations.  To benchmark on your hardware, run:

```
zig build run-bench-levenshtein -Drelease-fast=true -Dtarget=native -Dcpu=native
```

Note that `alt_std.levenshtein.distance` automatically dispatches to the fast `distance64` implementation when possible.

## Contribution
### Bug Fixes
If you find a bug, please do report it.  While I will respond to issues on this project, the ideal way to report an issue is to make a merge request with a minimal, failing test case as part of the function's test suite.  If you also have a fix for the code in question, great!

### New Features
I consider new functionality with the following criteria:
1) Is the functionality commonly part of a language's standard library?  Do C, C++, D, Rust, or Go include it?
2) Does the functionality introduce dependencies?  If so, the bar for inclusion is very high.
3) Is the proposed code well documented and tested?  Would it look at home in Zig's standard library?
