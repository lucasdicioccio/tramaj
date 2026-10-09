# Releasing the packages — human checklist

Four packages are ready to publish to a real registry but aren't yet:
`tramaj-rs` and `tramaj-cli-rs` (crates.io), `tramaj-js` and `tramaj-react`
(npm). The PureScript packages (`tramaj-purs`, `tramaj-halogen`, `tramaj-cli`)
and `tramaj-hs` are consumed via git dependency today (see README.md's
*Consuming from your own project* / *Publishing* sections) — the PureScript
registry and Hackage are explicitly deferred there, so they're listed below
as optional, not blocking.

This is a one-time setup list. Nothing here is scriptable — it's account
creation and judgment calls only a human can make. Once it's done, a
release script (separate follow-up) can handle version bumps and the
actual `cargo publish`/`npm publish` calls.

## 1. Reserve names first

Do this before anything else — a name can be squatted between now and when
you're ready to publish.

- [ ] Check `tramaj-rs` and `tramaj-cli-rs` aren't taken on
      [crates.io](https://crates.io/search).
- [ ] Check `tramaj-js` and `tramaj-react` aren't taken on
      [npmjs.com](https://www.npmjs.com/search).
- [ ] Decide unscoped (`tramaj-js`) vs. scoped (`@lucasdicioccio/tramaj-js`)
      npm names now — scoped is free to claim even if the unscoped name is
      gone, but it changes the install command in every doc/README that
      references it, so pick before publishing rather than after.

## 2. crates.io account

- [ ] Sign in at [crates.io](https://crates.io) via GitHub OAuth (uses your
      `lucasdicioccio` GitHub account).
- [ ] Verify the account email.
- [ ] Enable 2FA on the GitHub account crates.io logs in through, if not
      already on (crates.io itself has no separate password to secure).
- [ ] Generate an API token: crates.io → Account Settings → API Tokens →
      New Token. Scope it to `publish-new` + `publish-update` rather than
      full access if given the choice.
- [ ] `cargo login <token>` locally, or store the token as `CARGO_REGISTRY_TOKEN`
      if you end up publishing from CI instead of your machine.

## 3. npm account

- [ ] Create an account at [npmjs.com](https://www.npmjs.com/signup).
- [ ] Verify the account email.
- [ ] Enable 2FA (npm requires it for publishing as of their current
      policy) — authenticator app, not just SMS.
- [ ] `npm login` locally, or generate a
      [granular access token](https://docs.npmjs.com/creating-and-viewing-access-tokens)
      scoped to just `tramaj-js`/`tramaj-react` (and the scope/org if you
      went scoped) if publishing from CI.

## 4. Fix package metadata before the first publish

Both are currently marked `"private": true` in `package.json`, which
`npm publish` refuses outright — that's a deliberate guard against
publishing by accident, not an oversight, so flip it consciously per
package right before its first release:

- [ ] `tramaj-js/package.json` and `tramaj-react/package.json`: remove (or
      set `false`) `"private": true`.
- [ ] Add `"repository"`, `"homepage"`, and `"author"` fields to both —
      `tramaj-cli-rs/Cargo.toml` already has the Cargo equivalents
      (`repository`, `authors`) as a model to match.
- [ ] `tramaj-react`'s dependency on `tramaj-js` is currently
      `"file:../tramaj-js"` (a local path), which does not resolve for
      anyone installing off npm. Before publishing `tramaj-react`, this
      must become a real semver range (e.g. `"^0.1.0"`) pointing at the
      already-published `tramaj-js` — meaning **`tramaj-js` must be
      published first, `tramaj-react` second, every release**, not in
      parallel.
- [ ] Decide the starting published version. `Cargo.toml`/`package.json`
      all currently say `0.1.0`; the repo's own git tags are already past
      that (`v0.2.1`) from unrelated releases, so decide whether registry
      versions track those repo-wide tags or run their own independent
      SemVer — they don't have to match, but pick one policy before the
      first publish so it doesn't drift by accident.

## 5. Decide the release scope/cadence

- [ ] All four packages in lockstep on every release, or each versioned
      and released independently as it changes? (`tramaj-rs`/`tramaj-cli-rs`
      have the same same-order dependency constraint as the npm pair —
      publish the library before the CLI that depends on it.)
- [ ] Where do release notes/changelogs live — a `CHANGELOG.md` per
      package, GitHub Releases against the existing `vX.Y.Z` tags, or
      nothing formal yet?

## 6. Optional, lower priority: PureScript registry + Hackage

README.md's *Publishing* section already flags what's missing for these
and says it's "deliberately deferred until the API has settled":

- [x] PureScript registry: `tramaj-purs` and `tramaj-halogen` `0.4.0`
      published from generated copy repos (the registry rejects `subdir`);
      see `scripts/sync-purs-registry-repos.sh`.
- [x] Hackage: an account at [hackage.haskell.org](https://hackage.haskell.org),
      and `cabal upload` for `tramaj-hs` (`0.4.0.0` published).

Not blocking the crates.io/npm work above — separate ecosystem, separate
timeline.

## Next step

Once 1–5 above are done, the actual release automation — a script that
bumps versions, runs each package's tests, publishes in the right order,
and tags the commit — is a separate, scriptable follow-up. Ask for it
when you're ready; it depends on the cadence/scope decisions in §5.
