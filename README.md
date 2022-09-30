# alt_std
The Zig languages is deliberately postponing serious development of the standard library until the language has stabilized.  As a result, the current standard library largely contains only the things needed for development of the core infrastructure.  This library is a parking place for useful functionality that will likely qualify for inclusion in a standard library.

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

## Known Issues
The stage2 compiler (used by default in all versions after 0.9.1) has [a bug](https://github.com/ziglang/zig/issues/12973) that prevents certain functions from compiling successfully.  You'll see errors like `current master/nightly compiler which will become v0.10 `.  It's recommended that you either use v0.9.1 or pass `-fstage1` during compilation.  This workaround will not be necessary once the underlying issue in the stage2 implementation is resolved.
