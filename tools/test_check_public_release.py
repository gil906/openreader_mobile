#!/usr/bin/env python3
"""Synthetic-only tests. Fixtures live below this project and are removed."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
from types import SimpleNamespace
import unittest
from unittest import mock
import zipfile
import zlib

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("privacy_guard", Path(__file__).with_name("check_public_release.py"))
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)
PREP_SPEC = importlib.util.spec_from_file_location("asset_preparer", Path(__file__).with_name("prepare-downloads.py"))
prepare = importlib.util.module_from_spec(PREP_SPEC)
PREP_SPEC.loader.exec_module(prepare)
ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / ".privacy-test-fixtures"


def synthetic_png(metadata=(), pixels=b"\0\0\0"):
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))

    width = (len(pixels) + 2) // 3
    header = struct.pack(">IIBBBBB", width, 1, 8, 2, 0, 0, 0)
    scanline = b"\0" + pixels.ljust(width * 3, b"\0")
    return (
        guard.PNG_SIGNATURE + chunk(b"IHDR", header)
        + b"".join(chunk(kind, payload) for kind, payload in metadata)
        + chunk(b"IDAT", zlib.compress(scanline, level=0)) + chunk(b"IEND", b"")
    )


def synthetic_dex(strings):
    header = bytearray(112)
    header[:8] = b"dex\n035\0"
    struct.pack_into("<II", header, 56, len(strings), 112)
    offsets = []
    body = bytearray()
    for value in strings:
        offsets.append(112 + 4 * len(strings) + len(body))
        length = len(value)
        while length >= 128:
            body.append((length & 127) | 128)
            length >>= 7
        body.append(length)
        body.extend(value + b"\0")
    return bytes(header) + b"".join(struct.pack("<I", offset) for offset in offsets) + body


def synthetic_elf(rodata, instructions=b""):
    header = bytearray(64)
    header[:6] = b"\x7fELF\x02\x01"
    sections = 64 + len(rodata) + len(instructions)
    struct.pack_into("<Q", header, 40, sections)
    struct.pack_into("<HHH", header, 58, 64, 3, 0)
    section = lambda flags, offset, size: struct.pack("<IIQQQQIIQQ", 0, 1, flags, 0, offset, size, 0, 0, 1, 0)
    return (
        bytes(header) + rodata + instructions + b"\0" * 64
        + section(2, 64, len(rodata)) + section(6, 64 + len(rodata), len(instructions))
    )


class PrivacyTests(unittest.TestCase):
    def setUp(self):
        FIXTURES.mkdir(exist_ok=True)
        self.root = FIXTURES / self._testMethodName
        self.root.mkdir()

    def tearDown(self):
        shutil.rmtree(self.root)
        if FIXTURES.exists() and not any(FIXTURES.iterdir()):
            FIXTURES.rmdir()

    def write(self, name, data=b"synthetic"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def scan(self):
        scanner = guard.Scanner()
        scanner.tree(self.root)
        return scanner

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], stderr=subprocess.DEVNULL)

    def test_safe_tree_and_examples(self):
        self.write("README.md", b"https://reader.example.test http://localhost:3005 http://10.0.2.2:3003")
        self.write(".env.example", b"AUTH_SECRET=${AUTH_SECRET}\nBOOTSTRAP_ADMIN_PASSWORD=CHANGE_ME\n")
        self.write("docs/screenshots/reader-dark.png", synthetic_png())
        self.assertFalse(self.scan().errors)

    def test_forbidden_paths_and_formats(self):
        for name in (
            "book" + ".pdf", "book" + ".epub", "notes" + ".docx", "audio" + ".wav",
            ".env", ".env.production", "release" + ".apk", "source" + ".zip",
            "data/state.json", "android/key.properties", "uploads/anything.txt",
            "photo.png", "private" + ".pem",
        ):
            with self.subTest(name=name):
                path = self.write(name)
                self.assertTrue(self.scan().errors)
                path.unlink()
                for directory in sorted(self.root.rglob("*"), reverse=True):
                    if directory.is_dir() and not any(directory.iterdir()):
                        directory.rmdir()

    def test_private_hosts_and_secrets(self):
        unsafe = [
            "http://" + "192." + "168.50.20",
            "http://[" + "fd12:" + ":1234]",
            "synthetic-person" + "@" + "mail" + "." + "private",
            "https:" + "//synthetic-host" + ".internal",
            "synthetic-host" + ".com",
            "API_KEY" + '="this-is-not-a-placeholder"',
            "token" + '="this-is-not-a-placeholder"',
            "-----BEGIN " + "PRIVATE KEY-----",
            "ghp_" + "Z" * 36,
        ]
        for value in unsafe:
            with self.subTest(kind=unsafe.index(value)):
                self.write("source.txt", value.encode())
                self.assertTrue(self.scan().errors)

    def test_no_brand_word_matching(self):
        self.write("dictionary.txt", b"ordinary company and product brand words are not secrets")
        self.assertFalse(self.scan().errors)

    def test_dynamic_source_assignments_are_not_credentials(self):
        source = b"token" + b" = await storage.read();\n" + b"password" + b" = passwordController.text;\n"
        self.write("main.dart", source)
        self.assertFalse(self.scan().errors)
        self.write("main.dart", b"token" + b" = 'hardcoded-test-credential';")
        self.assertTrue(self.scan().errors)

    def test_code_identifiers_and_password_ui_are_not_private_literals(self):
        source = (
            b"final y = rect" + b".top; final x = this" + b".store; final h = widget.api.base"
            + b".host;\n" + b"subtitle: Text('${widget.api.base" + b".host} PDFs'),\n"
            + b"tooltip: obscure ? 'Show pass" + b"word' : 'Hide password',\n"
        )
        self.write("main.dart", source)
        self.assertFalse(self.scan().errors)
        for value in [
            "final host = 'synthetic-host" + ".internal';",
            "// synthetic-host" + ".internal",
            "final value = 'token" + "'; final token" + " = 'hardcoded-credential';",
            "final config = " + "'" + '{"to' + 'ken":"hardcoded-credential"}' + "';",
            "final numeric = " + "192." + "168.50.20;",
        ]:
            with self.subTest(kind=value[:12]):
                self.write("main.dart", value.encode())
                self.assertTrue(self.scan().errors)

    def test_synthetic_mock_hosts_are_scoped_to_reviewed_test_files(self):
        value = ("final origin = 'http://" + "reader" + ".local:3003';").encode()
        scanner = guard.Scanner()
        scanner.blob("android_app/test/offline_test.dart", value)
        self.assertFalse(scanner.errors)
        scanner.blob("android_app/lib/main.dart", value)
        self.assertTrue(scanner.errors)
        scanner = guard.Scanner()
        scanner.blob(
            "android_app/test/offline_test.dart",
            value + (" // http://" + "192." + "168.50.20").encode(),
        )
        self.assertTrue(scanner.errors)

    def test_reserved_example_subdomains_are_safe(self):
        self.write("README.md", b"https://reader.example.com synthetic@example.org")
        self.assertFalse(self.scan().errors)

    def test_png_pixel_bytes_are_not_text_or_ocr(self):
        pixels = b"synthetic@" + b"mail" + b".private"
        self.write("docs/screenshots/reader-phone.png", synthetic_png(pixels=pixels))
        self.assertFalse(self.scan().errors)

    def test_png_plain_and_compressed_metadata_is_scanned(self):
        secret = b"ghp_" + b"Z" * 36
        metadata = [
            (b"tEXt", b"Comment\0" + secret),
            (b"zTXt", b"Comment\0\0" + zlib.compress(secret)),
            (b"iTXt", b"Comment\0\1\0\0\0" + zlib.compress(secret)),
            (b"eXIf", b"unreviewed-metadata"),
        ]
        for item in metadata:
            with self.subTest(kind=item[0]):
                self.write("docs/screenshots/reader-phone.png", synthetic_png(metadata=[item]))
                self.assertTrue(self.scan().errors)

    def test_png_appended_payload_and_bad_crc_are_rejected(self):
        path = self.write("docs/screenshots/reader-phone.png", synthetic_png() + b"appended")
        self.assertTrue(self.scan().errors)
        payload = bytearray(synthetic_png())
        payload[-1] ^= 1
        path.write_bytes(payload)
        self.assertTrue(self.scan().errors)

    def test_android_ninepatch_is_apk_resource_only(self):
        patch = bytes([0, 2, 2, 1]) + b"\0" * 48
        image = synthetic_png(metadata=[(b"npTc", patch), (b"npLb", b"\0" * 16), (b"npOl", b"\0" * 24)])
        self.assertFalse(self.artifact("resource" + ".apk", [("res/demo.9.png", image)]).errors)
        self.assertTrue(self.artifact("asset" + ".apk", [("assets/demo.9.png", image)]).errors)
        self.write("docs/screenshots/reader-phone.png", image)
        self.assertTrue(self.scan().errors)
        malformed = synthetic_png(metadata=[(b"npTc", patch[:-1])])
        self.assertTrue(self.artifact("malformed" + ".apk", [("res/demo.9.png", malformed)]).errors)
        exif = synthetic_png(metadata=[(b"eXIf", b"unreviewed")])
        self.assertTrue(self.artifact("exif" + ".apk", [("res/demo.png", exif)]).errors)

    def test_sdk_metadata_exception_requires_exact_bytes_and_path(self):
        path = "lib/arm64-v8a/libflutter.so"
        fixture = b"Public notice upstream" + b"@" + b"vendor" + b".org"
        with mock.patch.dict(guard.APK_SDK_METADATA_SHA256, {path: hashlib.sha256(fixture).hexdigest()}):
            self.assertFalse(self.artifact("sdk" + ".apk", [(path, fixture)]).errors)
            self.assertTrue(self.artifact("changed" + ".apk", [(path, fixture + b"changed")]).errors)
            self.assertTrue(self.artifact("moved" + ".apk", [("assets/notice.txt", fixture)]).errors)
            scanner = guard.Scanner()
            scanner.blob(path, fixture)
            self.assertTrue(scanner.errors)

    def test_sdk_approval_never_hides_raw_security_findings(self):
        path = "lib/arm64-v8a/libflutter.so"
        fixtures = [
            b"ghp_" + b"Z" * 36,
            ("http://" + "192." + "168.50.20").encode(),
            ("https://" + "private-host" + ".internal").encode(),
            b"%PDF-" + b"synthetic",
        ]
        for value in fixtures:
            with self.subTest(kind=fixtures.index(value)), mock.patch.dict(
                guard.APK_SDK_METADATA_SHA256, {path: hashlib.sha256(value).hexdigest()}
            ):
                self.assertTrue(self.artifact("unsafe" + ".apk", [(path, value)]).errors)
        value = b"synthetic-local-deny-value"
        with mock.patch.dict(guard.APK_SDK_METADATA_SHA256, {path: hashlib.sha256(value).hexdigest()}):
            scanner = guard.Scanner([value])
            scanner.blob(path, value, apk=True)
            self.assertTrue(scanner.errors)

    def test_dex_diagnostics_do_not_waive_private_literals(self):
        diagnostic = b"Dispatchers" + b".IO"
        self.assertFalse(self.artifact("safe" + ".apk", [("classes.dex", synthetic_dex([diagnostic]))]).errors)
        unsafe = b"owner" + b"@" + b"non-example" + b".com"
        self.assertTrue(self.artifact("unsafe" + ".apk", [("classes.dex", synthetic_dex([diagnostic, unsafe]))]).errors)
        self.assertTrue(self.artifact("bad" + ".apk", [("classes.dex", b"dex\n035\0")]).errors)

    def test_app_elf_is_strict_except_exact_dart_sdk_symbols(self):
        path = "lib/arm64-v8a/libapp.so"
        symbol = b"_Uri" + b"@" + b"0150898" + b".file"
        self.assertFalse(self.artifact("safe" + ".apk", [(path, synthetic_elf(symbol))]).errors)
        unsafe = b"owner" + b"@" + b"non-example" + b".com"
        self.assertTrue(self.artifact("unsafe" + ".apk", [(path, synthetic_elf(symbol + b"\0" + unsafe))]).errors)
        self.assertTrue(self.artifact("raw-email" + ".apk", [(path, synthetic_elf(symbol, unsafe))]).errors)
        private_ip = ("http://" + "192." + "168.50.20").encode()
        self.assertTrue(self.artifact("raw" + ".apk", [(path, synthetic_elf(symbol, private_ip))]).errors)
        self.assertTrue(self.artifact("token" + ".apk", [(path, synthetic_elf(b"ghp_" + b"Z" * 36))]).errors)
        self.assertTrue(self.artifact("broken" + ".apk", [(path, b"\x7fELF\x02\x01")]).errors)

    def test_android_build_metadata_path_is_narrow(self):
        data = b"appMetadataVersion=1.1\nandroidGradlePluginVersion=9.1.0\n"
        path = guard.APK_BUILD_METADATA
        self.assertFalse(self.artifact("safe" + ".apk", [(path, data)]).errors)
        self.assertTrue(self.artifact("unsafe" + ".apk", [(path, data + b"unexpected=field\n")]).errors)
        self.assertTrue(self.artifact("elsewhere" + ".apk", [("META-INF/build/other.properties", data)]).errors)
        self.assertTrue(self.artifact("source" + ".zip", [(path, data)]).errors)

    def test_symlinks_and_disguised_document(self):
        target = self.write("safe.txt")
        link = self.root / "link"
        link.symlink_to(target)
        self.assertTrue(self.scan().errors)
        link.unlink()
        target.write_bytes(b"%PDF-" + b"synthetic")
        self.assertTrue(self.scan().errors)

    def test_staged_blob_cannot_hide_behind_safe_worktree(self):
        self.git("init", "--quiet")
        path = self.write("settings.txt", ("http://" + "192." + "168.50.20").encode())
        self.git("add", "settings.txt")
        path.write_text("http://localhost")
        scanner = guard.Scanner()
        scanner.git_tree(self.root, False)
        self.assertTrue(scanner.errors)

    def test_history_catches_deleted_unsafe_document(self):
        self.git("init", "--quiet")
        self.write("old" + ".pdf")
        self.git("add", ".")
        commit = ["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.test", "commit", "--quiet", "-m"]
        self.git(*commit, "synthetic fixture")
        self.git("rm", "--quiet", "old" + ".pdf")
        self.git(*commit, "remove fixture")
        scanner = guard.Scanner()
        scanner.git_tree(self.root, True)
        self.assertTrue(scanner.errors)

    def artifact(self, name, members):
        path = self.root / name
        with zipfile.ZipFile(path, "w") as archive:
            for entry, content in members:
                archive.writestr(entry, content)
        scanner = guard.Scanner()
        scanner.artifact(path)
        return scanner

    def test_safe_source_archive_and_apk_resources(self):
        self.assertFalse(self.artifact("source" + ".zip", [("source/README.md", "http://localhost")]).errors)
        self.assertFalse(self.artifact("app" + ".apk", [("res/drawable/icon.png", b"synthetic")]).errors)

    def test_unsafe_archives_and_utf16_secrets(self):
        cases = [
            [("assets/private" + ".pdf", b"synthetic")],
            [("../escape.txt", b"synthetic")],
            [("source/.env", b"synthetic")],
            [("source/data/item.json", b"synthetic")],
            [("assets/settings.bin", ("http://" + "192." + "168.50.20").encode("utf-16-le"))],
            [("assets/settings.bin", ("ghp_" + "Z" * 36).encode())],
            [("assets/payload.txt", b"%PDF-" + b"synthetic")],
        ]
        for members in cases:
            with self.subTest(kind=cases.index(members)):
                self.assertTrue(self.artifact("unsafe" + ".apk", members).errors)

    def test_voice_pack_requires_exact_hash(self):
        self.assertTrue(self.artifact(guard.VOICE_NAME, [("model.onnx", "synthetic")]).errors)
        self.assertEqual(len(guard.VOICE_SHA256), hashlib.sha256().digest_size * 2)

    def test_approved_wrapper_requires_exact_hash_and_path(self):
        name = "android_app/android/gradle/wrapper/gradle-wrapper.jar"
        fixture = b"PK\x03\x04synthetic-build-tool-fixture"
        with mock.patch.dict(guard.APPROVED_SOURCE_BINARIES, {name: hashlib.sha256(fixture).hexdigest()}):
            scanner = guard.Scanner()
            scanner.blob(name, fixture)
            self.assertFalse(scanner.errors)
            scanner.blob("elsewhere/gradle-wrapper.jar", fixture)
            self.assertTrue(scanner.errors)
            scanner = guard.Scanner()
            scanner.blob(name, fixture + b"changed")
            self.assertTrue(scanner.errors)

    def test_approved_wrapper_in_source_zip_only(self):
        name = "android_app/android/gradle/wrapper/gradle-wrapper.jar"
        fixture = b"PK\x03\x04synthetic-build-tool-fixture"
        with mock.patch.dict(guard.APPROVED_SOURCE_BINARIES, {name: hashlib.sha256(fixture).hexdigest()}):
            self.assertFalse(self.artifact("source" + ".zip", [(name, fixture)]).errors)
            self.assertFalse(self.artifact("wrapped" + ".zip", [("project/" + name, fixture)]).errors)
            self.assertTrue(self.artifact("misplaced" + ".zip", [("elsewhere/gradle-wrapper.jar", fixture)]).errors)
            self.assertTrue(self.artifact("app" + ".apk", [(name, fixture)]).errors)

    def test_asset_preparation_cleans_partial_output_on_failure(self):
        project = self.root / "project"
        tools = project / "tools"
        tools.mkdir(parents=True)
        shutil.copyfile(Path(__file__).with_name("check_public_release.py"), tools / "check_public_release.py")
        source = self.root / "input"
        source.mkdir()
        for name in prepare.ASSETS:
            with zipfile.ZipFile(source / name, "w") as archive:
                archive.writestr("synthetic.txt", "safe synthetic fixture")
        output = io.StringIO()
        with mock.patch.object(prepare, "ROOT", project), mock.patch.object(
            sys, "argv", ["prepare-downloads.py", "--from-dir", str(source)]
        ), contextlib.redirect_stderr(output):
            self.assertEqual(prepare.main(), 1)
        self.assertFalse((project / "dist").exists())
        self.assertIn("incomplete dist removed", output.getvalue())

    def test_checksum_manifest_accepts_only_known_optional_container(self):
        manifest = self.write(
            "SHA256SUMS",
            "".join("0" * 64 + "  " + name + "\n" for name in prepare.ASSETS).encode(),
        )
        self.assertEqual(set(prepare.checksums(manifest)), set(prepare.ASSETS))
        manifest.write_text(manifest.read_text() + "0" * 64 + "  " + prepare.CONTAINER_ASSET + "\n")
        self.assertEqual(set(prepare.checksums(manifest)), set(prepare.ASSETS) | {prepare.CONTAINER_ASSET})

    def test_checksum_manifest_rejects_extra_duplicate_and_missing_names(self):
        required = "".join("0" * 64 + "  " + name + "\n" for name in prepare.ASSETS)
        container = "0" * 64 + "  " + prepare.CONTAINER_ASSET + "\n"
        invalid = [
            required + "0" * 64 + "  unexpected.zip\n",
            required + "0" * 64 + "  openreader_mobile-container-v1.2.1.tar.gz\n",
            required + "0" * 64 + "  ../escape\n",
            required + container + container,
            required + "0" * 64 + "  " + prepare.ASSETS[0] + "\n",
            "0" * 64 + "  " + prepare.ASSETS[0] + "\n" + container,
        ]
        for value in invalid:
            with self.subTest(kind=invalid.index(value)):
                manifest = self.write("SHA256SUMS", value.encode())
                with self.assertRaises(ValueError):
                    prepare.checksums(manifest)

    def test_preparation_omits_container_and_writes_three_entry_manifest(self):
        payloads = {name: ("synthetic " + name).encode() for name in prepare.ASSETS}
        payloads[prepare.CONTAINER_ASSET] = b"must not copy or download this archive"
        manifest = "".join(
            hashlib.sha256(value).hexdigest() + "  " + name + "\n"
            for name, value in payloads.items()
        ).encode()
        source = self.root / "input"
        source.mkdir()
        for name, value in payloads.items():
            (source / name).write_bytes(value)
        (source / "SHA256SUMS").write_bytes(manifest)

        for mode in ("local", "download"):
            with self.subTest(mode=mode):
                project = self.root / mode
                (project / "container").mkdir(parents=True)
                (project / "container/index.html").write_text("<p>Synthetic installer fixture</p>")
                scanned, fetched = [], []
                scanner = SimpleNamespace(errors=set(), artifact=lambda path: scanned.append(path.name))

                def fetch(name, destination):
                    self.assertNotEqual(name, prepare.CONTAINER_ASSET)
                    fetched.append(name)
                    destination.write_bytes(manifest if name == "SHA256SUMS" else payloads[name])

                args = ["prepare-downloads.py"]
                if mode == "local":
                    args += ["--from-dir", str(source), "--checksums", str(source / "SHA256SUMS")]
                with mock.patch.object(prepare, "ROOT", project), mock.patch.object(
                    prepare, "load_guard", return_value=SimpleNamespace(Scanner=lambda: scanner)
                ), mock.patch.object(prepare, "fetch", side_effect=fetch), mock.patch.object(
                    sys, "argv", args
                ), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(prepare.main(), 0)
                dist = project / "dist"
                self.assertEqual({path.name for path in dist.iterdir()}, set(prepare.ASSETS) | {"SHA256SUMS", "index.html"})
                self.assertEqual(set(prepare.checksums(dist / "SHA256SUMS")), set(prepare.ASSETS))
                self.assertEqual(set(scanned), set(prepare.ASSETS))
                self.assertEqual(set(fetched), set() if mode == "local" else set(prepare.ASSETS) | {"SHA256SUMS"})

    def container_fixture(self, changes=None, history=None, deny=None, wrong_layer=False):
        def zip_bytes(entries):
            output = io.BytesIO()
            with zipfile.ZipFile(output, "w") as archive:
                for name, value in entries:
                    archive.writestr(name, value)
            return output.getvalue()

        payloads = {
            prepare.ASSETS[0]: zip_bytes([("AndroidManifest.xml", b"synthetic")]),
            prepare.ASSETS[1]: zip_bytes([("android_app/README.md", b"synthetic")]),
            prepare.ASSETS[2]: zip_bytes([("dictionary.txt", b"public ordinary brand words")]),
        }
        voice_hash = hashlib.sha256(payloads[prepare.ASSETS[2]]).hexdigest()
        web = "usr/share/nginx/html/"
        files = {web + name: value for name, value in payloads.items()}
        files.update({web + "index.html": b"<p>Synthetic installer</p>", "etc/nginx/conf.d/default.conf": b"server {}"})
        files.update(changes or {})
        files[web + "SHA256SUMS"] = "".join(
            hashlib.sha256(files[web + name]).hexdigest() + "  " + name + "\n"
            for name in prepare.ASSETS
        ).encode()
        layer_data = io.BytesIO()
        with tarfile.open(fileobj=layer_data, mode="w") as layer:
            for name, value in files.items():
                member = tarfile.TarInfo(name)
                if value is None:
                    member.type, member.linkname = tarfile.SYMTYPE, "/outside"
                    layer.addfile(member)
                else:
                    member.size = len(value)
                    layer.addfile(member, io.BytesIO(value))
        layer = layer_data.getvalue()
        config = {
            "os": "linux", "architecture": "amd64",
            "rootfs": {"diff_ids": ["sha256:" + ("0" * 64 if wrong_layer else hashlib.sha256(layer).hexdigest())]},
            "config": {"Env": [], "Labels": {}, "Entrypoint": ["nginx"], "Cmd": ["-g", "daemon off;"]},
            "history": [{"created_by": value} for value in (history or [])],
        }
        manifest = [{"RepoTags": [guard.CONTAINER_TAG], "Config": "config.json", "Layers": ["layer.tar"]}]
        path = self.root / guard.CONTAINER_NAME
        with tarfile.open(path, "w:gz") as archive:
            for name, value in {
                "config.json": json.dumps(config).encode(), "manifest.json": json.dumps(manifest).encode(),
                "layer.tar": layer,
            }.items():
                member = tarfile.TarInfo(name)
                member.size = len(value)
                archive.addfile(member, io.BytesIO(value))
        canonical = lambda value: hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        with mock.patch.multiple(
            guard, CONTAINER_SHA256=hashlib.sha256(path.read_bytes()).hexdigest(),
            CONTAINER_BASE_DIFF_IDS=(), CONTAINER_ENV_SHA256=canonical([]),
            CONTAINER_LABELS_SHA256=canonical({}), VOICE_SHA256=voice_hash,
        ):
            scanner = guard.Scanner(deny)
            scanner.artifact(path)
        return scanner, path

    def test_pinned_container_payloads_and_no_blanket_tar_allowance(self):
        scanner, path = self.container_fixture()
        self.assertFalse(scanner.errors)
        scanner = guard.Scanner()
        scanner.artifact(path)
        self.assertTrue(scanner.errors)  # Production archive hash was not overridden.
        renamed = path.with_name("unreviewed.tar.gz")
        path.rename(renamed)
        scanner = guard.Scanner()
        scanner.artifact(renamed)
        self.assertTrue(scanner.errors)

    def test_container_rejects_docs_traversal_links_and_bad_layer_digest(self):
        for name, value in [
            ("usr/share/nginx/html/private" + ".pdf", b"synthetic"),
            ("../escape", b"synthetic"),
            ("data/state.json", b"synthetic"),
            ("usr/share/nginx/html/link", None),
        ]:
            with self.subTest(name=name):
                scanner, _ = self.container_fixture({name: value})
                self.assertTrue(scanner.errors)
        scanner, _ = self.container_fixture(wrong_layer=True)
        self.assertTrue(scanner.errors)

    def test_container_checks_raw_secrets_private_values_and_history(self):
        path = "usr/share/nginx/html/index.html"
        for value in [
            b"ghp_" + b"Z" * 36,
            ("http://" + "192." + "168.50.20").encode(),
            b"-----BEGIN " + b"PRIVATE KEY-----",
        ]:
            with self.subTest(kind=value[:5]):
                scanner, _ = self.container_fixture({path: value})
                self.assertTrue(scanner.errors)
        value = b"synthetic-local-deny-value"
        scanner, _ = self.container_fixture({path: value}, deny=[value])
        self.assertTrue(scanner.errors)
        scanner, _ = self.container_fixture(history=["RUN API_" + "KEY=opaque-private-value"])
        self.assertTrue(scanner.errors)

    def test_container_validates_nested_installer_and_pinned_voice(self):
        bad_apk = io.BytesIO()
        with zipfile.ZipFile(bad_apk, "w") as archive:
            archive.writestr("assets/private" + ".pdf", b"synthetic")
        scanner, _ = self.container_fixture({"usr/share/nginx/html/" + prepare.ASSETS[0]: bad_apk.getvalue()})
        self.assertTrue(scanner.errors)
        scanner, _ = self.container_fixture({"usr/share/nginx/html/" + prepare.ASSETS[2]: b"not the pinned voice"})
        self.assertTrue(scanner.errors)

    def test_public_base_metadata_never_waives_explicit_owner_values(self):
        value = b"r" + b".internal"
        scanner = guard.Scanner()
        scanner.text(value, "public-base", critical_only=True, public_base=True)
        self.assertFalse(scanner.errors)
        scanner = guard.Scanner([value])
        scanner.text(value, "public-base", critical_only=True, public_base=True)
        self.assertTrue(scanner.errors)
        scanner = guard.Scanner()
        scanner.text(value, "added-file", critical_only=True)
        self.assertTrue(scanner.errors)
        scanner = guard.Scanner()
        scanner.text(("192." + "168.50.20").encode(), "public-base", critical_only=True, public_base=True)
        self.assertTrue(scanner.errors)

    def test_denylist_and_redacted_diagnostics(self):
        value = b"synthetic-private-value"
        scanner = guard.Scanner([value])
        scanner.blob("private-filename.txt", value)
        self.assertTrue(scanner.errors)
        self.assertNotIn("private-filename", repr(scanner.errors))
        scanner = guard.Scanner([value])
        scanner.text(value.decode().encode("utf-16-le"), "synthetic.bin")
        self.assertTrue(scanner.errors)
        path = self.write("private" + ".pdf")
        stream = io.StringIO()
        with contextlib.redirect_stderr(stream):
            self.assertEqual(guard.main(["--root", str(self.root)]), 1)
        self.assertNotIn(path.name, stream.getvalue())


if __name__ == "__main__":
    unittest.main()
