# Synthetic native Android captures

The staged release includes these **synthetic-only** captures:

- `reader-dark.png` — actual wide Android prepared playback with synthetic
  reading-room demo text and PDF-word highlighting.
- `reader-phone.png` — actual native Android phone capture following granted
  content-URI Open with/Share validation, demonstrating Fit page and phone voice.

The maintainer manually reviewed both captures: only fabricated reading-room
demo content, with no personal document, uploaded study material, account,
private address, or identifying settings. They are real app captures, not UI
mockups or captures from a personal reading session.

Only curated PNG files in this directory are allowed by the privacy guard.
PNG structure and text metadata are checked, including compressed text chunks.
Opaque compressed pixel bytes are not classified as plaintext personal data.
The scanner does not perform OCR and cannot certify that screenshot pixels
are safe.

For every future replacement, capture a clean emulator using fabricated content,
inspect every pixel and all metadata (status bars, notifications, settings,
filenames, account names, document text, previews), and strip unnecessary
metadata. A human must verify the new synthetic provenance before publication.
