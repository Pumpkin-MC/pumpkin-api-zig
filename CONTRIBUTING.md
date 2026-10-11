# Contributing

Thanks for helping out. This guide covers how to set up the repository, how it is laid out, and what a pull request needs.

## Setup

You need [Zig](https://ziglang.org/download/) 0.16.0 and [`wasm-tools`](https://github.com/bytecodealliance/wasm-tools) 1.259.0 in your `PATH`. The Pumpkin bindings are generated from the `wit` submodule, so clone with it:

```sh
git clone --recurse-submodules https://github.com/Pumpkin-MC/pumpkin-api-zig
```

```sh
zig build        # builds the examples into zig-out/
zig build test   # unit tests for the ABI layer, the helpers and the generator
zig build check  # compiles every generated binding
zig build gen    # regenerates src/bindings/
```

To try a change, copy the plugins from `zig-out/` into the `plugins` folder of a Pumpkin server and start it.

## Layout

- `src/pumpkin.zig` is the package root and holds `register`, which exports a plugin.
- `src/api/` holds the hand-written helpers: `cmd`, `msg`, `menu`, `item`, `http`, `net`, `config`, `store` and `tasks`.
- `src/runtime/` holds the canonical ABI layer and the `std.Io` behind `pumpkin.io()`.
- `src/bindings/` holds the generated bindings. Don't edit them by hand: change `tools/gen.zig` or the WIT and run `zig build gen`.
- `examples/` has one plugin per topic. `examples/nettest.zig` runs every networking path against a real server with `/nettest`.

The README's [Working on the bindings](README.md#working-on-the-bindings) section explains where the WIT and WASI definitions come from.

## Plugin API versions

The bindings target the v0.1 plugin API, which is frozen: Pumpkin won't change it, and bugs in it stay until v0.2. When the server misbehaves, check the host code in Pumpkin's `pumpkin-wasm-host-v0_1` crate before assuming the bindings are wrong. If a helper can work around the bug, do that and say so in a comment. If it can't, document the limitation.

## Code style

- Run `zig fmt` before committing. CI checks it.
- Write the code the way the code around it is written.
- Keep comments few and short. They are for people who read the code without knowing how it came about: explain what isn't obvious from the code, in full sentences. Public declarations get a doc comment if their name doesn't say enough.
- New helpers come with an example in `examples/` and a row in the README's examples table.

## Commits and pull requests

Commit messages and pull request titles follow [Conventional Commits](https://www.conventionalcommits.org/), with a scope and a subject line only:

```
feat(item): add item cooldowns
fix(net): stop blocking on slow peers
docs(readme): explain plugin permissions
```

The types are `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore` and `revert`. The scope usually names the module, such as `cmd`, `item` or `gen`. Keep the subject short and in lowercase imperative, and put the details in the pull request description.

One bug or one feature per pull request. In the description, say what changed and why, and what you tried on a server, since CI can't run plugins.

A pull request runs the same checks as CI: formatting, tests, generated bindings being up to date, every binding compiling, and the examples building into valid components. A spell check runs [typos](https://github.com/crate-ci/typos) over everything except the generated bindings.

### AI-generated contributions

You can use AI tools, but you are the author of everything you submit. Before you open a pull request, you should have read every line, run the change yourself, and be able to answer questions about it without asking a model. Say in the description if AI wrote a meaningful part of the code or the description. If you work with an agent, have it read [AGENTS.md](AGENTS.md) first.
