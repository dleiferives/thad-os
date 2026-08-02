# Contributing to thad-os

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
