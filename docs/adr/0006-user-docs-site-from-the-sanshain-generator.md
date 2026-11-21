# 6. User docs on GitHub Pages, built with sanshain-service's generator

Date: 2026-11-21

## Status

Accepted.

## Context

pub.dev publishes the API reference of every version, but not guides. The owner wants detailed user documentation on GitHub Pages, done the way `paxel/sanshain-service` does it: HTML fragments in `site/` grouped into tracks, built by a zero-dependency Node script into `site-dist/` with navigation, tables of contents, a search index and every released version under `/vX.Y.Z/`, tested and linted, and deployed to GitHub Pages from `v*` tags.

## Decision

- The site copies sanshain-service's generator (`scripts/build-site.js`, `scripts/build-site-all.js`, `scripts/site/`), its tests (`tests/site/`), its lint step and `.github/workflows/pages.yml`, adapted to this package. The generated pages that exist only for Sanshain, the OpenAPI contract and arc42, are dropped.
- Three tracks:
  - **Start**: overview, getting started, concepts, glossary, what's new.
  - **Guide**, one task per page: schemas and attributes, values and unions, schema resolution, single-object encoding, container files, fingerprints and canonical form, untrusted input and limits, errors.
  - **Reference**: the value mapping tables, the `AvroLimits` defaults, the exception types, spec conformance with the interop results, and a link to the API reference on pub.dev.
- Material for contributors belongs in `AGENTS.md` and `docs/adr/`, not on the site.

## Considered options

- Rewriting the generator in Dart, so that the repository needs one toolchain: about 1,300 tested lines to redo before the first page.
- `dart doc` output plus a few guide pages: no tracks, no search over the guides, no versioned site.

## Consequences

- A Dart repository carries Node tooling, used only by the site job.
- The tag check of `pages.yml` reads the version from `pubspec.yaml` instead of `Cargo.toml`.
- The owner sets the Pages source to "GitHub Actions" once, and lets the `github-pages` environment deploy from `v*` tags.
