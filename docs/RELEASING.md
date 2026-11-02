# Manual release gate — v1.2.0

This checklist does not authorize or perform publication. There are deliberately
no Actions workflows. Do not push/create tags, releases, or packages until the
maintainer has completed every applicable gate.

## Curate, do not mirror

- [ ] Add final reviewed native source under `android_app/`; do not copy the live
      directory wholesale. Preserve the dependency lockfile, required build
      scripts, source, GPL license, third-party notices and bundled license texts.
- [ ] Remove all personal defaults; fresh server/email fields must be empty.
      Public build must not set a private `OPENREADER_DEFAULT_SERVER`.
- [ ] No user documents, uploads, downloads, histories, logs, caches, audio,
      databases, build outputs, real `.env`, private network/account identities,
      credentials, keys, keystores, or signing properties in source or git history.
- [ ] Use reviewed source-based app icons where practical: the repository guard
      permits PNG only under `docs/screenshots/`, not copied emulator captures
      or unchecked resource images. APK resource PNGs are allowed in the APK.
- [ ] Supply both synthetic screenshots, verify pixels and strip unnecessary
      metadata. Scanner passes are not OCR or provenance evidence.
- [ ] Include complete matching/corresponding source and legal notices, including
      resource provenance and modifications. Do not rely on a remote main branch
      or an unrelated source snapshot to meet GPL obligations.

## Device and build gate

- [ ] Use Flutter 3.47.9, Java 17 and Android SDK 36; confirm API 24 minimum.
- [ ] Confirm version/build number, supported ABIs and APK signing certificate.
- [ ] Run app analysis/unit tests and real emulator/device tests.
- [ ] Verify offline pack setup from the public-release path and host download
      path; offline imported/saved PDF and all 20 English voice selections.
- [ ] Verify full-PDF prepare/cancel/resume/per-voice persistence and storage
      behavior, queued continuous playback, paragraph taps, and source-specific
      speed/highlight state.
- [ ] Verify PDF Open with/Share, user-consented local-PDF upload for server
      narration, source switching, dark fullscreen and phone/foldable layouts.
- [ ] Verify existing settings survive upgrade while fresh server/email fields
      are blank. Verify offline use without a server after model/PDF are saved.
- [ ] Preserve the limits around approximate offline timing and preparation
      needing the open screen; do not claim guaranteed background processing.
- [ ] Update README release-candidate wording only after actual verification.

## Asset and privacy gate

Expected release assets:

1. `OpenReader-Native-v1.2.0.apk`
2. `OpenReader-Native-source.zip` — exact corresponding source plus notices and
   build instructions, using `android_app/` as the native source directory
3. `kokoro-english-v1.zip` — SHA-256
   `abaff9787f8b73c28dc2876c7610bcc162b0fc29cd6fa7556af72e20b8f9e8d7`
4. `SHA256SUMS` — exactly the three names above, SHA-256 followed by two spaces
5. `openreader_mobile-container-v1.2.0.tar.gz` — reviewed `docker save` image,
   retaining tag `ghcr.io/gil906/openreader_mobile:v1.2.0`
6. `CONTAINER-SHA256SUMS` — separate checksum manifest for the container archive

- [ ] Run `python3 -B tools/test_check_public_release.py`.
- [ ] Run the root/index/HEAD scanner and `--history` before each push.
- [ ] Scan final APK/source/voice artifacts with `--artifact`, including the
      exact archives to upload, not an earlier intermediate export.
- [ ] Check actual private local values separately without recording them.
- [ ] Inspect archive file lists and metadata manually; verify complete source,
      licenses, private-default absence, no documents or injected data.
- [ ] Verify APK identity and source correspondence independently. Ensure source
      covers the shipped binary and required component/resource modifications.
- [ ] Review all references and new allowlisted dependency domains individually.
      Never add a broad exception for credentials or private document names.

The pinned voice hash establishes the trusted model/dictionary byte identity.
Its safe filenames still get checked; dictionary words are not classified as
personal company names. Do not change the hash merely to bypass a finding.

## Container gate

- [ ] Prepare `dist/` from curated local artifacts before publication; do not
      stage it. Verify `SHA256SUMS` and the pinned voice hash.
- [ ] Build/test official nginx Alpine download container. Verify the pinned
      base-image manifest digest, review security updates, and record platform.
- [ ] Confirm only the expected public installer files, page and checksums are
      present; no credentials, build context leak, runtime data, or user mounts.
- [ ] Verify `3005:80` download page, checksums, APK/ZIP downloads and HTTP range
      support. Verify read-only root with the documented writable cache/run mounts.
- [ ] Validate Compose with locally supplied test-only placeholders, then test
      optional upstream server and embedded-worker audio routes. Kokoro remains
      internal-only; the worker's public URL must actually reach the phone.
- [ ] Export the reviewed tagged image as
      `openreader_mobile-container-v1.2.0.tar.gz` and provide separate
      `CONTAINER-SHA256SUMS` as the primary required public container delivery.
      Record its platform, inspect image history and all added layers, and
      verify public installer checksums. The APK/ZIP scanner does not inspect
      image archives. Never upload an unchecked image or registry credentials.
- [ ] Test checksum verification, `docker load`, and
      `docker compose -f compose.downloads.yaml up -d --pull never --no-build`
      without GHCR credentials, a server `.env`, or registry access. Confirm the
      loaded tag is `ghcr.io/gil906/openreader_mobile:v1.2.0`.
- [ ] Treat GHCR delivery as optional. Recommend a registry pull only after
      explicitly verifying anonymous package access; public repository status
      does not establish package visibility. Publication is a separate authorized
      operation and no Actions workflow is involved.

## Future pushes

These rules apply permanently, not only to the initial import. Enable local
hooks in every clone, repeat history/asset checks, and review synthetic
screenshot provenance for every update. If sensitive data is ever published,
stop distribution immediately, revoke exposed credentials, remove affected
assets/packages and coordinate full history cleanup. Deleting the latest file
alone does not remove a public leak.
