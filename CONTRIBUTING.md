# Contributing

Phoros is a wire protocol with installed peers on both sides. A change here can break an app that a person installed a year ago. Read [docs/compatibility.md](docs/compatibility.md) before you propose one.

## Wire changes

Open an issue first. Include:

1. What an older peer sees when it receives the new message or field.
2. What a newer peer sees when it receives the old form.
3. Which capability flag gates the new behaviour.

A pull request for a wire change includes a fixture in `Tests/PhorosTests` that pins the new bytes or JSON. Every existing fixture must still pass unchanged.

## The Rust core

`PhorosCore` ships as a prebuilt XCFramework pinned by checksum, so a change to `Core/phoros-core` is not live for anyone until a release rebuilds and republishes it. Build it with `Core/build.sh`, test with `PHOROS_CORE_LOCAL=1 swift test` and `cargo test`, and say in the pull request that the artifact needs a rebuild.

`Core/phoros-core/vendor/str0m` is upstream str0m plus two named patches. Keep it that way: a change there should be a patch worth carrying and worth upstreaming, or it belongs in our own code.

## Session, network and media products

Changes to `PhorosSession`, `PhorosNetwork` and `PhorosMedia` do not touch the wire and follow the ordinary rules below. If a change encodes a lesson from an incident, say what the incident was in the doc comment. That is what the type is for.

## Everything else

Bug fixes, documentation and API improvements that do not change bytes on the wire are welcome as pull requests. Run `swift test` before you open one.

## Commit messages

Use Conventional Commits: `feat: add controller report parser`. Types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`. Commits from the maintainers carry a ticket reference in the scope, which is an internal convention and is not expected of anyone else.
