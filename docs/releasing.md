# Releasing

A release is a tag `vX.Y.Z` on `summer` whose version is the `version:` of `pubspec.yaml`.
The tag starts `.github/workflows/release.yml`: the release gate of paxel/gates, the archive
of the tagged tree with its provenance, the GitHub release with the notes of the
`CHANGELOG.md` section, and then the package on pub.dev. The same tag deploys the docs site
(`.github/workflows/pages.yml`).

A version on pub.dev is permanent: it can be retracted for 7 days after publishing, but never
deleted or published again.

## By hand, once

These steps need the owner's Google account and the repository settings; no workflow can do
them.

1. Publish the first version from a clean checkout of its tag:
   `dart pub publish --dry-run`, then `dart pub publish`. pub.dev allows automated publishing
   only for a package that exists.
2. On https://pub.dev/packages/avro/admin, under **Automated publishing**, enable publishing
   from GitHub Actions for the repository `paxel/dart-avro` with the tag pattern
   `v{{version}}`.
3. On the same page, tick **Require GitHub Actions environment** and enter `pub.dev`.
4. In the repository's settings, create the environment `pub.dev` and allow deployments only
   from tags matching `v*`.
5. For the docs site: Settings, Pages, source "GitHub Actions"; the `github-pages` environment
   allows deployments from tags matching `v*`.

Every later version is published by its tag. The first version's tag still runs the release
workflow; its pub.dev job fails, because that version exists already, and nothing else is
affected.

Checked against https://dart.dev/tools/pub/automated-publishing on 2026-11-21.
