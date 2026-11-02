# Public repository privacy contract

This repository is PUBLIC. These rules apply to every future commit, branch,
tag, screenshot, container, release asset, issue attachment, and push.

- Never copy user documents, uploaded or downloaded PDFs, EPUBs, DOCX files,
  synthesized audio, app databases, caches, histories, logs, backups, runtime
  data, or mounted server data into this repository or a public artifact.
- Never include personal names, account addresses, private hosts/domains,
  private IPs, API keys, access tokens, passwords, signing keys, keystores,
  `key.properties`, credential files, or real `.env` files. Use reserved
  `example.test` placeholders and `.env.example` with unset secrets.
- Never copy the live application directory wholesale. Export only reviewed
  source and required license notices; exclude generated and private material.
- Only deliberately fabricated, synthetic document text may appear in public
  screenshots. Images belong under `docs/screenshots/`. Never capture a user's
  documents, filenames, library, server settings, account, or notification tray.
  The scanner is NOT OCR and cannot establish that an image is safe.
- APKs, source ZIPs, and the pinned voice pack are release assets, never git
  objects. Containers may contain only the curated public installer assets,
  checksums, and download page. No documents, runtime data, signing material,
  or credentials may enter a Docker context or image layer.
- Before EVERY commit run `python3 tools/check_public_release.py --root .`.
  Before EVERY push/release also use `--history` and scan each final asset with
  `--artifact PATH`. Review the entire source export, asset archive contents,
  screenshot pixels/metadata, notices, build provenance, and matching source.
  Check real local private values separately without logging or committing them.
- Install the repository-local hooks with `sh tools/setup-dev.sh`. Do not bypass
  them. Hooks are defense in depth, not a substitute for human review.
- Do not add Actions workflows or publish/push/create releases without explicit
  authorization. Never turn planned or unverified features into verified claims.
- Preserve GPL-3.0-or-later licensing, upstream notices and the complete
  corresponding source for each APK. Keep private signing material outside the
  repository, source archive, build context, and container.
