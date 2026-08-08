# Contributing to thad-os

## Hardware builds

Build the MacBook4,1 kernel through the checked-in wrapper:

```sh
ZIG=/path/to/zig ./tools/build-macbook41.sh
```

Do not deploy a plain `zig build` result to that machine. The
`macbook_early_fb` option currently selects the complete early hardware
profile, including the bootstrap AHCI ABAR mapping as well as framebuffer
markers.

TODO: Replace the misleading compile-time `macbook_early_fb` switch with
explicit named build artifacts for generic/QEMU and MacBook4,1 targets, then
validate the selected artifact automatically during deployment.

## Tracking future work in code

Use `TODO` comments as the project's lightweight, code-local backlog. When a
piece of code is deliberately incomplete, limited, or built as a first pass,
leave a focused `TODO` beside the relevant implementation.

A useful `TODO` explains both the current limitation and the improvement we
want. Prefer comments such as:

```zig
// TODO: Replace polling with interrupt-driven completion so storage I/O does
// not occupy a CPU while the controller is working.
```

Avoid vague comments such as `TODO: improve this`. In particular, call out:

- correctness and data-integrity limitations;
- temporary polling, busy-waiting, or synchronous designs;
- read-only implementations and missing write/flush support;
- hardware assumptions, unsupported devices, and fixed-size limits;
- missing timeout, recovery, diagnostics, and error-handling paths;
- performance, allocation, concurrency, and security improvements;
- test coverage needed for unusual or failure cases.

Keep TODOs close to the code they describe. They are welcome throughout the
codebase, but each one should represent actionable future work rather than a
general wish. Remove or update the comment when the limitation changes.

## Boot logging

The kernel keeps critical `[boot]` checkpoints in a 64 KiB RAM buffer and, once
AHCI is ready, writes that buffer to the ext2 diagnostic file extents supplied
by GRUB. Checkpoints and errors are always retained; normal scoped logs can be
tuned from the GRUB kernel command line:

```text
thad-log-level=info thad-log-scopes=boot,storage,filesystem
```

`thad-log-level` accepts `error`, `warn`, `info`, or `debug`. The scope list is
comma-separated and accepts `boot`, `storage`, `filesystem`, `memory`, `input`,
`console`, `interrupts`, `scheduler`, `userspace`, `arcade`, or `all`. An exact
Zig log scope such as `drivers_ahci` can also be used. With no logging arguments,
the kernel uses info level and its curated default scopes.

Prefer a subsystem-scoped `std.log` call for routine diagnostics and
`hardwareBootStatus` for a milestone whose loss would make a failed physical
boot impossible to locate. Do not put high-frequency loop or per-sector output
at info level; reserve it for debug and leave a TODO where interrupt-driven or
batched diagnostics should replace polling noise.
