# About
This is a Zig implementation of a CPU raytracer, based primarily on Peter Shirley's fantastic [Ray Tracing in One Weekend](https://raytracing.github.io) series.

## Notable Features
- Multithreaded raycasting.
- Fast image writes (multithreading + file memory mapping).
- BVH acceleration.
- Quasi monte carlo sampling of rays via Sobol sequences.
- Importance sampling of light emitting surfaces.

# Usage
This repository is self-contained i.e. no external dependencies should be needed to run the binary.

Basic usage help can be seen by passing the `--help` (or simply `-h`) flag to the binary. This will also show you a list of scenes that are available to render.

The output is a PPM image, which is very space inefficient. However, the file writing should be quite fast thanks to multithreaded pixel writes and memory mapping of the output file.

## Zig Version 
Zig compiler version: `0.14.0-dev.1511+54b668f8a`

**Disclaimer**: I developed this on a MacBook Pro M1, macOS 13.6.3 (22G436).

## Building & Running
**This code will only work on POSIX compliant systems because Windows compatible memory mapping logic has not been implemented yet.**

In the root of this repository, run
```bash
> zig build --release=fast
```

You can create a render by doing something like this
```bash
> ./zig-out/bin/weekend-raytracer --image_width=400 --image_height=400 --ray_bounce_max_depth=10 --thread_pool_size=512 --samples_per_pixel=128
```

## Tests
Simply run `zig build test`.

# References
- [Ray Tracing in One Weekend](https://raytracing.github.io)
- [PBRT-4e](https://pbrt.org)
