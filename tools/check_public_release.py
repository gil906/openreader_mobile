#!/usr/bin/env python3
"""Fail-closed local guard for curated git trees and public APK/source assets.

No network access, third-party packages, OCR, or printing of matched values.
With git: inspect worktree, index, HEAD; --history adds every reachable commit.
Without git: inspect the directory, including ignored files. Symlinks are refused.
"""
from __future__ import annotations

import argparse
import hashlib
import gzip
import io
import ipaddress
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import subprocess
import sys
import tarfile
import zipfile
import zlib

VOICE_NAME = "kokoro-english-v1.zip"
VOICE_SHA256 = "abaff9787f8b73c28dc2876c7610bcc162b0fc29cd6fa7556af72e20b8f9e8d7"
CONTAINER_NAME = "openreader_mobile-container-v1.3.1.tar.gz"
CONTAINER_SHA256 = "6e0d1579b9a7b06e5de9fc3e56995ea0adf402cafe2712aa9f3f6e8bb3f5d910"
CONTAINER_TAG = "ghcr.io/gil906/openreader_mobile:v1.3.1"
CONTAINER_BASE_DIFF_IDS = (
    "sha256:989e799e634906e94dc9a5ee2ee26fc92ad260522990f26e707861a5f52bf64e",
    "sha256:a2738b08d7114c9d5581dd5482d3b5cc297fcf73b8d330c3ba38d24c43939119",
    "sha256:47a53288c3ef0ee51df84ef47d217f18c1762412532fded9af1fd88ecee14294",
    "sha256:9e707aa6db4786355904a1b794c80f378b690f8f0384af56117708a23a91f1da",
    "sha256:a3446cc6c821fa11b704a45811ab554675f0327307af71b3f4ff5a70c7a4eec8",
    "sha256:42608b42cb5e68548abf1c71aa851acfd65816d0ceaff6ee85849c7c478463f0",
    "sha256:53c769b49ca0a2f0f6cf5e4a807af8933cec6cde9302d56d91a78bc38ea407a8",
    "sha256:f76f397f2ce6b266573b70eb60ef1335e9984a1941eedd2a3505af4870c3afa0",
)
CONTAINER_ENV_SHA256 = "2aa77e5524a862a6e823e4399b76801e1a6891b71ac564fa25c3bcb7cf0bd9ad"
CONTAINER_LABELS_SHA256 = "37e2b0645fe73117143c9c818877d23fc27feac1d181e29593a4a9308a655c47"
# Reviewed broadcast/link-local constants, an upstream config example, and a
# nginx JS property, only in immutable public base layers. Deny inputs still win.
PUBLIC_BASE_NETWORK_METADATA_SHA256 = {
    "f45462bf3cd12ea2b347f32f6c4d0a0d36e01694de332b307af90d42951c5bd6",
    "da51cf1afeda313d3202229979d5e0f29437e72637ecc26b4203fe4224ae797c",
    "c5eb5a4cc76a5cdb16e79864b9ccd26c3553f0c396d0a21bafb7be71c1efcd8c",
    "9b7842af4ef67bdf99fb8d1e53fe8896efdf89849875dcfa055c50910ac6c581",
}
CONTAINER_INSTALLERS = ("OpenReader-Native-v1.3.1.apk", "OpenReader-Native-source.zip", VOICE_NAME)
APPROVED_SOURCE_BINARIES = {
    "android_app/android/gradle/wrapper/gradle-wrapper.jar":
        "16caeaf66d57a0d1d2087fef6a97efa62de8da69afa5b908f40db35afc4342da",
}
MAX_FILE = 64 * 1024 * 1024
MAX_ARCHIVE = 1024 * 1024 * 1024
MAX_MEMBERS = 30000
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
MAX_PNG_TEXT = 1024 * 1024
APK_BUILD_METADATA = "META-INF/com/android/build/gradle/app-metadata.properties"
# Exact reviewed SDK bytes; this exception only affects noisy binary metadata.
# Raw deny literals, strong token formats and private-network checks still run.
APK_SDK_METADATA_SHA256 = {
    "lib/arm64-v8a/libdartjni.so": "d9cbec0a0203d2e3ac8574eebb965e7819c9a6eec36d3c2da9a6c32d281b71cd",
    "lib/arm64-v8a/libdatastore_shared_counter.so": "178f89a2c6c9234ddf980dd4cd1f3616186a46b2b932aafa6707abd04c5fd76a",
    "lib/arm64-v8a/libflutter.so": "86b660128f3a3b6220c32d4d637f8198b2083f60c36c55ff025d3dba1a64d0f8",
    "lib/arm64-v8a/libonnxruntime.so": "7a2fb92eb67037837c3f0e428bd732fd0d05ced0546d9e740090c07573d8249a",
    "lib/arm64-v8a/libpdfium.so": "de19db1c0fb33579bca6ace903af7ccb9d03ad1d3f6c5202970d8d79d7538303",
    "lib/arm64-v8a/libpdfrx_pdfium_gate.so": "2116bdff14a34c7b76288ae5c7c944455b84631739bf077b62268b9c59f7aa0c",
    "lib/arm64-v8a/libsherpa-onnx-c-api.so": "8523d8044fb7336b945c8662821165f782103e4200a660b0ef097f6a41230e32",
    "kotlin/kotlin.kotlin_builtins": "8f37cbb253a76650c4e313f98f70d081d2ae66d05174abf6a5824cbf7926616b",
}
# Reviewed complete DEX diagnostic/tag strings, not whole app bytecode.
APK_DEX_METADATA_SHA256 = {
    "5c07f67ded8645f4282c4f90502b401adc8e747dbe81736e0722500fb7c0b0f6",
    "e25a851e584c034a37dc50a12907e8c307fe6541b22c8792e15d01a0ee65b858",
    "8cfe636be121a2ab19d0b2ae1fd111da85a402fefd42ee2a60ca2a90607525f2",
    "bba61efaee4b7c4f0940953e5ad0984024d44627d3ec8c60ff77f567029aaed6",
    "0a24ffb696dab00dadb6a922c745450f24a73a3dbd515c9cae319b192e124f95",
    "b5c9635823b8ac48e0553ea26150b6a091ad84e04572898b1fb24484252d7525",
    "b64524913cc018329e91d2e7577230edeaf8f46c3d52d4037026bf866d425cc3",
    "b8ae8741cb0bebfcfab77cd4293e1f92c6d84a9015ed197e16cf91f0041751ee",
    "dc7e4884c2cd141bab6d71e9527702ea36be518a6c438c77a0b8935fbff44ed4",
    "1f799b0c66b87dbcc1c25aa4b3cc448daf5deb2d7ee30e689faf8b4af51f1792",
    "4ff5bc57c04d110057525aca9c06392da36af5b51aa30ef1e99b72f8a4d17d2b",
    "4e7b6894626ac6811abe66b0fd7657f2246dd5d5ff65b341e0e87cffccd98579",
}
# These exact email-shaped strings are Dart SDK private constructor symbols.
# No rule exempts arbitrary numeric-domain emails or all libapp.so metadata.
DART_CONSTRUCTOR_METADATA_SHA256 = {
    "2db0189778c282c9d987b9fb3e5c2d7dbc340b5f4d3c2fafc1d7cfbe30b3eab4",
    "77882a0448182de8af29a26b7905db3bb22f3f679daf0ceb34025a1ace1ca740",
    "770a6be5d2b4ae52714fe709c5a041e31420cac6e0db01463222bf70f41fb52a",
    "0318c5e8d2fa9ca4ebd4a9b7986ba0caf4a9800bac25b3d97b5ace8dfa1e0dff",
    "45cc0365291dc6d14c97f8b16750f95e97f2f753e537433f170eeeb1c91175ce",
    "de1bd190e5f5717b7e098ef2e37405a3a40f55799a5afa786c18527e3e9ffda2",
    "718594a1f2476a9d7e79bf13560cde22a086ba6451a8e9d6e52156a56be5a37e",
    "2af6e43f72eac398609fbf8edfd5dae8f2003f34e769e90271e79269a5b26539",
    "238159d9b9c09110ee56ff6f591a3ce4817d1563baa9c485d37d85d919c49743",
    "c9e61dc9b265ed7f842e5263a81b04c6a741a09d3453c3a6e8498b37653690ca",
    "5f209d04c7a74a563249c7644771bfbcda4e05acbb62bf91d0eb30a3eae46746",
    "ed6a86e8a36e3bae8fa42884dfe375f4a359cdb4811c21bfdfdb3d84db080722",
    "7679361f667fc7068ec25e8addcee5696ddb0c83da8d74405fcc260e142c9996",
    "01ee14f75e28af28e61cff3b6dcfda063469b6b880ee9e94c006c56b547141c3",
    "c42c7f2591a818a6f780240151f827b3d112eb9257fe6049490a4689781b8e9f",
    "09e412b188fc3822c86ea3488584681e36877b9d003706a8762a15c14b0301ea",
    "d865505ea46da0f377a9cc58c37311537c6055dc3e57da4d8e262a28d33595c1",
    "97321aec7b18e4c9a1469df9ad507843fe3c6b115f1e46843ac8507ce52f7691",
    "35d9160191a005131634395d7908454b7f44e6f92d44adfafccd3f8cf1d38763",
    "56557a9cce35578932545a7695ee556763ad392f5eba154f8b296a0aa70f9e85",
    "43877f0cf4a45ea39331248792f6628d93b709c27009cbff4f6be9fd08e2c3d3",
    "1bdeaef334a55580ca857261a2d29de18ec50adb17c34772405b7320bd795255",
    "b7fe08a76f79bbcade6ca1028add63b624889b45db2a19260d35728b89e60d76",
    "3bdc7b277faeb08660e69d1e242dd92a56617479124146f84c1b60379c8ef604",
    "42c65e5e10a328b939b09bbe8b8cb348b035390cd52c275d2ce97b82ee78f60c",
    "7fcd5a194caf650c2a9040fa4df4ef3d549f9f521878e51d88c579ca0a5fed28",
    "353cbdd1734160177051143b9d20c5e6f8201e9e7fb431176b4d5712bc2cd25a",
    "49b039c41249699284f2120064b59d3842009be953431ab7b9711bff04f5b307",
    "256124e736b8db63f07864247d6b42c8c5ff9d4758a1e5a8113f5dba19775068",
    "34f558461663ca382975b2af162a893b8e81d0323baac7a09516a148a816715d",
    "c7581e82bb5758e09bff07cb16a8ecf14e1c0067faa46be4e62a26ad62055b66",
    "836e34351b7c48920afed20e1b2df726d20a88b9833682fba5ef39bd68f19c77",
    "8a8a0cc6a12402289dec7cb0957eb9f13807a87d45764dbbd7a02ebbf39817d5",
    "ad05792c70f2b1d8c6c28b9b1fccda026beb7c7a0cd128aa76562403cba4bb25",
    "f198d60b7cc9fdcd674e99d0925184e97f19b316c949fdcfcfd930e60ac9e285",
    "0469f59fd0e63e050fa82baeea69e155e7fa6bf21d17ceed7f5f3a687e41682b",
    "85d26e260955507f543ec0ecf5e29965939eeba13eddf84827561679222d5004",
    "59d9ff7e4cf6f80b374f3d89f724c0bd3bb5c7b721a3f47637289dead0055ef7",
    "952925f9b2333ff1387a4f26e809a00bd613134b88c5f78f9ee172b086a92015",
    "bed6b549980685a5bc80d394a992dcff27deae3a338e0f2c3112c7843eada555",
    "9be673d843ac9cde7b35f7d11bb3097294f510123964ea05052f547886c30e35",
    "ea6600c7ee78909e40fba2305b29775333cccab4c70ced268828b19befd297d9",
    "39c178a2bd6f0d6c7290690366d63c17a9b259ea0e853b7e59353ca2faaac544",
    "ac1cb511c98935c5c29c87b1c4be2f7b16dc6129fa35f27a7b03e91ab510ce9b",
    "2410c27c7e80d3299a6dbae63a329f5f97e9d0a663aaf21ad6699f3a74c58441",
    "ad835373e3e80f1f2dff0b4e1d8088df875eb5ecffbec9671dff9d12aa16bbd1",
    "6276a30bde4ff65324cd404c73aed65f9c0a592248e6d05ad81055c2b872115b",
    "65f950cdfbffd5d40e96e3b40ac1bce6cb682623aba6b5aee18c674e82076f19",
    "891de80c7b782362c1aa44f92db6362acfc259da96b71cbe9972a14d56a9418d",
    "e40fa1e9413800deffa20eb84ee50a2388d7e4891f30ce75c7636fd84a88134e",
    "fce8d4cf3551078a18e1f65c9f4f5765baac851b001d0bf49d6a16131d4c7894",
}
CODE_EXTS = {
    ".py", ".dart", ".kt", ".kts", ".java", ".js", ".ts", ".tsx", ".jsx",
    ".c", ".cpp", ".h", ".m", ".mm", ".rs", ".go", ".swift", ".sh",
}
BLOCKED_DIRS = {
    "data", "downloads", "uploads", "documents", "docstore", "runtime", "logs",
    "backups", ".signing", ".ssh", ".aws", ".azure", ".kube", ".gnupg",
    ".secrets", "secrets", "build", "dist", ".dart_tool", ".gradle",
    "node_modules", "__pycache__", ".idea", ".privacy-test-fixtures",
}
BLOCKED_EXTS = {
    ".pdf", ".epub", ".doc", ".docx", ".odt", ".pptx", ".wav", ".mp3",
    ".m4a", ".m4b", ".aac", ".opus", ".ogg", ".flac", ".mp4", ".webm",
    ".apk", ".aab", ".zip", ".tar", ".gz", ".bz2", ".7z", ".rar",
    ".jks", ".keystore", ".p12", ".pfx", ".pem", ".key", ".sqlite", ".sqlite3",
    ".db", ".log", ".pyc",
}
PUBLIC_HOSTS = {
    "github.com", "raw.githubusercontent.com", "objects.githubusercontent.com",
    "release-assets.githubusercontent.com", "ghcr.io", "hub.docker.com",
    "registry-1.docker.io", "auth.docker.io", "nginx.org", "www.nginx.org",
    "flutter.dev", "docs.flutter.dev", "storage.googleapis.com", "dart.dev",
    "pub.dev", "developer.android.com", "dl.google.com", "maven.google.com",
    "repo.maven.apache.org", "services.gradle.org", "plugins.gradle.org",
    "downloads.gradle.org", "www.gnu.org", "gnu.org", "fsf.org", "www.fsf.org",
    "apache.org", "www.apache.org", "opensource.org", "huggingface.co",
    "www.w3.org", "schemas.android.com", "localhost",
    "api.flutter.dev", "plugins.flutter.io", "aomedia.org", "dashif.org",
    "developer.apple.com", "g.co", "issuetracker.google.com", "ns.adobe.com",
    "youtrack.jetbrains.com",
}
EMAIL = re.compile(r"(?<![\w.+-])[\w.+-]+@([a-z0-9.-]+\.[a-z]{2,})(?![\w.-])", re.I)
DOMAIN = re.compile(
    r"(?<![\w/@.-])(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+"
    r"(?:com|org|net|io|dev|app|ai|cloud|me|co|uk|edu|gov|info|biz|xyz|"
    r"online|site|internal|local|lan|home|private|test|invalid|example|"
    r"fr|de|es|ca|us|au|nl|it|be|ch|se|no|fi|dk|pl|in|jp|cn|ru|br|mx|nz|za|"
    r"tv|cc|gg|ly|tech|network|digital|services|email|website|space|pro|live|"
    r"world|host|pw|top|work|company|academy|solutions|family|zone|city|support|"
    r"shop|store|link|today)(?![\w.-])", re.I
)
URL_HOST = re.compile(
    r"(?:https?|wss?)://(?:[a-z0-9._~!$&'()*+,;=:%-]+@)?"
    r"(\[[0-9a-f:.%]+\]|[a-z0-9_.-]+)", re.I
)
PRIVATE_HOST = re.compile(
    r"(?<![\w.-])(?:[a-z0-9-]+\.)+(?:local|lan|internal|home|private)(?![\w.-])", re.I
)
IPV4 = re.compile(r"(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])")
IPV6 = re.compile(r"(?<![\w:])(?:[a-f0-9]{0,4}:){2,}[a-f0-9:]{0,39}(?![\w:])", re.I)
SECRET_PATTERNS = [
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----"),
    re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bAIza[0-9A-Za-z_-]{30,}\b"),
    re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{15,}\b"),
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"),
    re.compile(r"(?:https?|wss?)://[^/\s:@]+:[^/\s@]+@", re.I),
    re.compile(r"\bAuthorization\s*[:=]\s*[\"']?(?:Bearer|Basic)\s+[A-Za-z0-9+/_.=-]{12,}", re.I),
]
RAW_SECRET_PATTERNS = [re.compile(pattern.pattern.encode("ascii"), pattern.flags & ~re.UNICODE) for pattern in SECRET_PATTERNS]
RAW_IP_PATTERNS = [re.compile(pattern.pattern.encode("ascii"), pattern.flags & ~re.UNICODE) for pattern in (IPV4, IPV6)]
RAW_PRIVATE_HOST = re.compile(PRIVATE_HOST.pattern.encode("ascii"), re.I)
RAW_WIDE_TEXT = (
    re.compile(rb"(?:[\x20-\x7e]\x00){6,}"),
    re.compile(rb"(?:\x00[\x20-\x7e]){6,}"),
)
ASSIGNMENT = re.compile(
    r"""(?im)(?:^|[{"'\s,])(?P<key>[A-Z_]*?(?:PASSWORD|PASSWD|SECRET|API_KEY|"""
    r"""ACCESS_TOKEN|AUTH_TOKEN|PRIVATE_KEY|CLIENT_SECRET|SIGNING_KEY|STORE_PASSWORD|"""
    r"""KEY_PASSWORD|SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID|TOKEN|SESSION_KEY|CREDENTIAL))"""
    r"""[\"']?[ \t]*[:=][ \t]*"""
    r"""(?:[\"'](?P<quoted>[^\"'\r\n]*)[\"']|(?P<plain>[^\s,;#}\r\n]+))"""
)
CODE_TOKEN = re.compile(
    r"(?P<comment>//[^\r\n]*|/\*[\s\S]*?\*/|\#[^\r\n]*)"
    r'|(?P<literal>"""[\s\S]*?"""|'
    r"'''[\s\S]*?'''|"
    r'"(?:\\.|[^"\\\r\n])*"|'
    r"'(?:\\.|[^'\\\r\n])*'|"
    r"`(?:\\.|[^`\\])*`)"
)
SYNTHETIC_TEST_HOSTS = {
    "android_app/test/offline_test.dart": {"reader" + ".local"},
    "android_app/test/reader_test.dart": {"reader" + ".local", "other" + "-server"},
}


def literal_body(value: str) -> str:
    width = 3 if value.startswith(("'''", '"""')) else 1
    return value[width:-width]


def synthetic_test_hosts(name: str) -> set[str]:
    path = PurePosixPath(name).as_posix()
    return set().union(*(
        hosts for fixture, hosts in SYNTHETIC_TEST_HOSTS.items()
        if path == fixture or path.endswith("/" + fixture)
    ))


def example_host(host: str) -> bool:
    host = host.lower().strip("[]").rstrip(".")
    return host == "localhost" or any(
        host.endswith("." + suffix) or host == suffix
        for suffix in ("test", "invalid", "example", "localhost", "example.com", "example.org", "example.net")
    )


def allowed_ip(value: str) -> bool:
    try:
        address = ipaddress.ip_address(value.strip("[]"))
    except ValueError:
        return True
    if address.is_global or address.is_loopback or address.is_unspecified:
        return True
    examples = (
        ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24")
        if address.version == 4 else ("2001:db8::/32",)
    )
    return str(address) == "10.0.2.2" or any(
        address in ipaddress.ip_network(network) for network in examples
    )


def placeholder(value: str) -> bool:
    value = value.strip()
    return (
        not value or value in {"null", "None", "none"}
        or value.startswith(("${", "$", "<", "os.environ", "process.env"))
        or value.upper().startswith(("CHANGE_ME", "REPLACE_ME", "EXAMPLE_", "YOUR_"))
    )


def path_problem(name: str, artifact: bool = False, apk: bool = False) -> str | None:
    path = PurePosixPath(name.replace("\\", "/"))
    parts = [part.lower() for part in path.parts]
    if path.is_absolute() or ".." in parts or not parts:
        return "unsafe path"
    if ".git" in parts:
        return "git internals in export"
    if any(part in BLOCKED_DIRS for part in parts[:-1]) and not (
        apk and path.as_posix() == APK_BUILD_METADATA
    ):
        return "runtime/build/private directory"
    base = parts[-1]
    if base == ".env" or (base.startswith(".env.") and base != ".env.example"):
        return "environment file"
    if base in {"key.properties", "local.properties", ".npmrc", ".netrc", ".git-credentials"}:
        return "local credentials/configuration"
    if re.search(r"(?:credential|service[-_]account|id_rsa|id_ed25519)", base):
        return "credential filename"
    suffix = path.suffix.lower()
    if suffix in BLOCKED_EXTS and not (artifact and suffix in {".zip", ".apk"}):
        return "document/audio/key/database/release binary"
    if suffix in {".png", ".jpg", ".jpeg", ".webp", ".gif", ".heic"}:
        if not apk and not (suffix == ".png" and len(parts) >= 3 and parts[-3:-1] == ["docs", "screenshots"]):
            return "image outside curated screenshots"
    return None


class Scanner:
    def __init__(self, deny: list[bytes] | None = None):
        self.errors: set[tuple[str, str]] = set()
        self.checked: set[str] = set()
        self.deny = deny or []
        self.deny_text = [value.decode("utf-8", errors="ignore") for value in self.deny]
        self.deny_wide = [
            value.encode(encoding) for value in self.deny_text if value
            for encoding in ("utf-16-le", "utf-16-be")
        ]

    def fail(self, label: str, reason: str) -> None:
        # Do not echo filenames: even a forbidden document name can be personal.
        identifier = hashlib.sha256(label.encode("utf-8", "surrogateescape")).hexdigest()[:12]
        self.errors.add((identifier, reason))

    def text(self, data: bytes, label: str, code: bool = False, fixture_hosts: set[str] | None = None,
             critical_only: bool = False, metadata_kind: str | None = None,
             public_base: bool = False) -> None:
        if any(value in data for value in self.deny):
            self.fail(label, "local private-value denylist")
        # Android resources and DEX may contain UTF-16 as well as UTF-8 strings.
        texts = [data.decode("utf-8", errors="replace")]
        if b"\x00" in data:
            texts.extend(data[offset:].decode("utf-16-le", errors="replace") for offset in (0, 1))
        for text in texts:
            tokens = list(CODE_TOKEN.finditer(text)) if code else []
            if any(value and value in text for value in self.deny_text):
                self.fail(label, "local private-value denylist")
            # Pinned public OS crypto parsers contain PEM header constants, not
            # owner signing keys. Every other strong pattern and deny literal runs.
            if any(pattern.search(text) for pattern in SECRET_PATTERNS[1 if public_base else 0:]):
                self.fail(label, "secret/credential pattern")
            for pattern in (IPV4, IPV6):
                for match in pattern.finditer(text):
                    if not allowed_ip(match.group(0)):
                        if public_base and hashlib.sha256(match[0].encode()).hexdigest() in PUBLIC_BASE_NETWORK_METADATA_SHA256:
                            continue
                        self.fail(label, "non-example private IP")
            if critical_only:
                for match in PRIVATE_HOST.finditer(text):
                    if not public_base or hashlib.sha256(match[0].encode()).hexdigest() not in PUBLIC_BASE_NETWORK_METADATA_SHA256:
                        self.fail(label, "private network hostname in raw artifact")
                continue
            for match in ASSIGNMENT.finditer(text):
                value = match.group("quoted") if match.group("quoted") is not None else match.group("plain")
                if code and (match.group("quoted") is None or re.search(r"\$\{?[A-Za-z_]", value)):
                    continue
                if code:
                    containing = next((
                        token for token in tokens
                        if token.group("literal") and token.start() <= match.start("key") < token.end()
                    ), None)
                    if (
                        containing
                        and literal_body(containing.group("literal")).lower() != match.group("key").lower()
                        and match.start("quoted") >= containing.end()
                    ):
                        continue
                if not placeholder(value):
                    self.fail(label, "literal credential assignment")
            if metadata_kind == "public_base_history":
                continue
            for match in EMAIL.finditer(text):
                if not example_host(match.group(1)):
                    if metadata_kind == "dart" and hashlib.sha256(
                        match.group(0).encode("utf-8")
                    ).hexdigest() in DART_CONSTRUCTOR_METADATA_SHA256:
                        continue
                    self.fail(label, "non-example email")
            # Dotted code identifiers are not domains. Strings/comments still get
            # hostname checks; explicit URLs, IPs, email and secrets are raw-scanned.
            host_texts = [token.group(0) for token in tokens] if code else [text]
            hosts = []
            for host_text in host_texts:
                if code:
                    host_text = re.sub(
                        r"\$\{[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*\}", "", host_text
                    )
                hosts.extend(
                    m.group(0) for m in DOMAIN.finditer(host_text)
                    if not (m.group(0).lower() == "user" + ".email" and host_text[m.end():].startswith("="))
                    and not (metadata_kind == "dart" and m.group(0) == "dart" + ".io")
                )
            hosts.extend(m.group(1) for m in URL_HOST.finditer(text))
            for host in hosts:
                host = host.lower().rstrip(".").strip("[]")
                try:
                    ipaddress.ip_address(host)
                except ValueError:
                    if host not in PUBLIC_HOSTS and host not in (fixture_hosts or set()) and not example_host(host):
                        # Compose service names are not private network identities.
                        if "." in host or host not in {"kokoro", "openreader", "downloads"}:
                            self.fail(label, "unapproved host/domain")
                else:
                    if not allowed_ip(host):
                        self.fail(label, "non-example private IP")
    def png(self, data: bytes, label: str, android_resource: bool = False) -> None:
        def inflate(payload: bytes) -> bytes:
            decoder = zlib.decompressobj()
            result = decoder.decompress(payload, MAX_PNG_TEXT + 1)
            if len(result) > MAX_PNG_TEXT or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
                raise ValueError("invalid or oversized PNG text")
            return result

        offset = len(PNG_SIGNATURE)
        seen_header = seen_pixels = False
        image_chunks = {b"PLTE", b"tRNS", b"cHRM", b"gAMA", b"sRGB", b"pHYs", b"sBIT", b"bKGD", b"hIST"}
        try:
            while offset + 12 <= len(data):
                length = struct.unpack_from(">I", data, offset)[0]
                kind = data[offset + 4:offset + 8]
                end = offset + 12 + length
                if end > len(data):
                    raise ValueError("truncated PNG chunk")
                payload = data[offset + 8:end - 4]
                expected_crc = struct.unpack_from(">I", data, end - 4)[0]
                if zlib.crc32(kind + payload) != expected_crc:
                    raise ValueError("PNG CRC mismatch")
                if not seen_header and kind != b"IHDR":
                    raise ValueError("PNG header missing")
                if kind == b"IHDR":
                    if seen_header or len(payload) != 13:
                        raise ValueError("invalid PNG header")
                    width, height = struct.unpack_from(">II", payload)
                    if not width or not height or width * height > 100_000_000:
                        raise ValueError("invalid PNG dimensions")
                    seen_header = True
                elif kind == b"IDAT":
                    # Compressed pixel bytes are not text; their random byte
                    # patterns must not be interpreted as email or credentials.
                    seen_pixels = True
                elif android_resource and kind in {b"npTc", b"npLb", b"npOl"}:
                    if kind == b"npTc":
                        if (
                            length < 32 or payload[0] not in {0, 1}
                            or not payload[1] or payload[1] % 2
                            or not payload[2] or payload[2] % 2 or not payload[3]
                            or length != 32 + 4 * sum(payload[1:4])
                        ):
                            raise ValueError("invalid Android nine-patch data")
                    elif length != (16 if kind == b"npLb" else 24):
                        raise ValueError("invalid Android nine-patch outline/insets")
                elif kind == b"IEND":
                    if length or not seen_pixels or end != len(data):
                        raise ValueError("invalid PNG ending or appended payload")
                    return
                elif kind in {b"tEXt", b"zTXt", b"iTXt"}:
                    if length > MAX_PNG_TEXT:
                        raise ValueError("oversized PNG metadata")
                    keyword, remainder = payload.split(b"\0", 1)
                    if kind == b"tEXt":
                        text = keyword + b"\n" + remainder
                    elif kind == b"zTXt":
                        if not remainder or remainder[0] != 0:
                            raise ValueError("invalid PNG compression method")
                        text = keyword + b"\n" + inflate(remainder[1:])
                    else:
                        if len(remainder) < 2 or remainder[0] not in {0, 1} or remainder[1] != 0:
                            raise ValueError("invalid PNG international text")
                        language, translated, body = remainder[2:].split(b"\0", 2)
                        if remainder[0]:
                            body = inflate(body)
                        text = b"\n".join((keyword, language, translated, body))
                    self.text(text, label)
                elif kind not in image_chunks:
                    self.fail(label, "unreviewed PNG metadata/chunk; strip nonessential metadata")
                offset = end
            raise ValueError("PNG ending missing")
        except (ValueError, struct.error, zlib.error):
            self.fail(label, "invalid PNG structure/metadata")

    def elf_metadata(self, data: bytes, label: str, dart: bool) -> None:
        try:
            if len(data) < 52 or data[:4] != b"\x7fELF" or data[5] != 1:
                raise ValueError("unsupported ELF")
            if data[4] == 2:
                start = struct.unpack_from("<Q", data, 40)[0]
                width, count, strings_index = struct.unpack_from("<HHH", data, 58)
                layout = "<IIQQQQIIQQ"
            elif data[4] == 1:
                start = struct.unpack_from("<I", data, 32)[0]
                width, count, strings_index = struct.unpack_from("<HHH", data, 46)
                layout = "<IIIIIIIIII"
            else:
                raise ValueError("unsupported ELF class")
            if not 0 < count <= 4096 or width < struct.calcsize(layout) or start + width * count > len(data):
                raise ValueError("invalid ELF section table")
            if strings_index >= count:
                raise ValueError("invalid ELF strings table")
            sections = [struct.unpack_from(layout, data, start + i * width) for i in range(count)]
            for section in sections:
                _, kind, flags, _, offset, size, *_ = section
                if kind == 8:  # NOBITS has no stored bytes.
                    continue
                if offset + size > len(data):
                    raise ValueError("invalid ELF section bounds")
                if kind in {1, 3} and not flags & 4 and size and not dart:
                    self.text(data[offset:offset + size], label)
            if dart:
                # App-authored code never gets a whole-binary metadata waiver.
                self.text(data, label, metadata_kind="dart")
        except (ValueError, struct.error):
            self.fail(label, "unreadable ELF metadata; manual binary review required")

    def dex_metadata(self, data: bytes, label: str) -> None:
        try:
            if len(data) < 112 or not data.startswith(b"dex\n"):
                raise ValueError("unsupported DEX")
            count, table = struct.unpack_from("<II", data, 56)
            if count > 1_000_000 or table + count * 4 > len(data):
                raise ValueError("invalid DEX string table")
            for index in range(count):
                cursor = struct.unpack_from("<I", data, table + index * 4)[0]
                for _ in range(5):  # Bounded ULEB128 UTF-16 length prefix.
                    if cursor >= len(data):
                        raise ValueError("invalid DEX string offset")
                    byte = data[cursor]
                    cursor += 1
                    if not byte & 128:
                        break
                else:
                    raise ValueError("invalid DEX string length")
                end = data.index(b"\0", cursor)
                literal = data[cursor:end]
                if hashlib.sha256(literal).hexdigest() not in APK_DEX_METADATA_SHA256:
                    self.text(literal, label)
        except (ValueError, struct.error):
            self.fail(label, "unreadable DEX metadata; manual bytecode review required")

    def blob(self, name: str, data: bytes, label: str | None = None, apk: bool = False) -> None:
        label = label or name
        problem = path_problem(name, apk=apk)
        if problem:
            self.fail(label, problem)
            return
        if len(data) > MAX_FILE:
            self.fail(label, "file exceeds review limit")
            return
        if data.startswith((b"%PDF-", b"RIFF")):
            self.fail(label, "document/audio signature")
            return
        if apk:
            # Always scan complete raw entry bytes before any metadata exception.
            self.text(name.encode("utf-8", errors="surrogateescape"), label)
            self.text(data, label, critical_only=True)
            sdk_hash = APK_SDK_METADATA_SHA256.get(name)
            if sdk_hash:
                if hashlib.sha256(data).hexdigest() != sdk_hash:
                    self.fail(label, "reviewed SDK metadata SHA256 mismatch")
                return
            if data.startswith(b"\x7fELF"):
                self.elf_metadata(data, label, dart=bool(re.fullmatch(r"lib/[^/]+/libapp\.so", name)))
                return
            if data.startswith(b"dex\n"):
                self.dex_metadata(data, label)
                return
            if name == APK_BUILD_METADATA:
                lines = data.decode("ascii", errors="replace").splitlines()
                if len(lines) != 2 or {
                    line.split("=", 1)[0] for line in lines
                } != {"appMetadataVersion", "androidGradlePluginVersion"} or any(
                    not re.fullmatch(r"[A-Za-z]+=[0-9]+(?:\.[0-9]+){1,3}", line) for line in lines
                ):
                    self.fail(label, "unreviewed Android build metadata fields")
        approved_hash = APPROVED_SOURCE_BINARIES.get(PurePosixPath(name).as_posix()) if not apk else None
        if approved_hash:
            if hashlib.sha256(data).hexdigest() != approved_hash:
                self.fail(label, "approved source binary SHA256 mismatch")
            return
        if data.startswith(PNG_SIGNATURE):
            self.text(name.encode("utf-8", errors="surrogateescape"), label)
            self.png(data, label, android_resource=apk and name.startswith("res/"))
            return
        if PurePosixPath(name).suffix.lower() == ".png" and not apk:
            self.fail(label, "invalid PNG signature")
            return
        if data.startswith(b"PK\x03\x04"):
            self.fail(label, "archive disguised as source")
        self.text(name.encode("utf-8", errors="surrogateescape"), label)
        self.text(
            data, label, code=PurePosixPath(name).suffix.lower() in CODE_EXTS,
            fixture_hosts=synthetic_test_hosts(name),
        )

    def file(self, root: Path, name: str) -> None:
        path = root / name
        if path.is_symlink() or any(parent.is_symlink() for parent in path.parents if parent != root.parent):
            self.fail(name, "symlink")
        elif path.exists():
            if not path.is_file():
                self.fail(name, "non-regular file")
            elif path_problem(name):
                self.fail(name, path_problem(name) or "forbidden path")
            elif path.stat().st_size > MAX_FILE:
                self.fail(name, "file exceeds review limit")
            else:
                self.blob(name, path.read_bytes())

    def tree(self, root: Path) -> None:
        for current, dirs, files in os.walk(root, followlinks=False):
            dirs[:] = [d for d in dirs if d != ".git"]
            for dirname in list(dirs):
                rel = (Path(current) / dirname).relative_to(root).as_posix()
                if (Path(current) / dirname).is_symlink():
                    self.fail(rel, "symlink")
                    dirs.remove(dirname)
                elif dirname.lower() in BLOCKED_DIRS:
                    self.fail(rel, "runtime/build/private directory")
                    dirs.remove(dirname)
            for filename in files:
                self.file(root, (Path(current) / filename).relative_to(root).as_posix())

    @staticmethod
    def git(root: Path, *args: str) -> bytes:
        return subprocess.check_output(
            ["git", "-C", str(root), *args], stderr=subprocess.DEVNULL
        )

    def git_tree(self, root: Path, history: bool) -> None:
        # Inspect blobs, not just checkout bytes: git add followed by a clean edit
        # must not hide an unsafe staged version.
        stages = self.git(root, "ls-files", "--stage", "-z").split(b"\0")
        objects: list[tuple[str, str, str]] = []
        names: set[str] = set()
        for record in filter(None, stages):
            meta, raw_name = record.split(b"\t", 1)
            mode, oid, stage = meta.decode().split()
            name = os.fsdecode(raw_name)
            names.add(name)
            objects.append((mode, oid, name))
        for name in names:
            self.file(root, name)
        # Include untracked, non-ignored files so a forgotten source export is reviewed.
        for name in filter(None, self.git(root, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0")):
            self.file(root, os.fsdecode(name))
        refs = ["HEAD"]
        if history:
            refs = self.git(root, "rev-list", "--all").decode().splitlines()
        for ref in refs:
            try:
                tree = self.git(root, "ls-tree", "-r", "-z", ref)
            except subprocess.CalledProcessError:
                continue  # Unborn HEAD is normal during initial staging.
            for record in filter(None, tree.split(b"\0")):
                meta, raw_name = record.split(b"\t", 1)
                mode, kind, oid = meta.decode().split()
                objects.append((mode, oid, os.fsdecode(raw_name)))
        for mode, oid, name in objects:
            marker = name + ":" + oid
            if marker in self.checked:
                continue
            self.checked.add(marker)
            if mode not in {"100644", "100755"}:
                self.fail(marker, "symlink/submodule/non-regular git entry")
            elif path_problem(name):
                self.fail(marker, path_problem(name) or "forbidden path")
            elif int(self.git(root, "cat-file", "-s", oid)) > MAX_FILE:
                self.fail(marker, "file exceeds review limit")
            else:
                self.blob(name, self.git(root, "cat-file", "blob", oid), marker)

    def artifact(self, path: Path) -> None:
        if path.is_symlink() or any(parent.is_symlink() for parent in path.parents) or not path.is_file():
            self.fail(str(path), "artifact is not a regular file")
            return
        if path.name == CONTAINER_NAME:
            self.container(path)
            return
        if path.suffix.lower() not in {".apk", ".zip"}:
            self.fail(str(path), "only APK/ZIP and the pinned Docker-save archive are supported")
            return
        pinned = path.name == VOICE_NAME
        if pinned:
            with path.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            if digest != VOICE_SHA256:
                self.fail(path.name, "voice pack SHA256 mismatch")
                return
        try:
            with zipfile.ZipFile(path) as archive:
                self.archive(archive, path.name, path.suffix.lower() == ".apk", pinned)
        except (OSError, ValueError, zipfile.BadZipFile, RuntimeError, NotImplementedError):
            self.fail(path.name, "unreadable/encrypted archive")

    def container(self, path: Path) -> None:
        with path.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != CONTAINER_SHA256:
                self.fail(path.name, "Docker-save archive SHA256 mismatch")
                return

        def safe_name(name):
            value = PurePosixPath(name)
            if value.is_absolute() or ".." in value.parts or "\\" in name or not value.parts:
                raise ValueError("unsafe Docker archive path")
            return value.as_posix()

        def canonical_hash(value):
            return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

        scanner = self

        def raw_security(data, public):
            if any(value in data for value in scanner.deny + scanner.deny_wide):
                scanner.fail(path.name, "local private-value denylist")
            if any(pattern.search(data) for pattern in RAW_SECRET_PATTERNS[1 if public else 0:]):
                scanner.fail(path.name, "secret/credential pattern")
            for match in RAW_PRIVATE_HOST.finditer(data):
                if not public or hashlib.sha256(match[0]).hexdigest() not in PUBLIC_BASE_NETWORK_METADATA_SHA256:
                    scanner.fail(path.name, "private network hostname in raw artifact")
            for pattern in RAW_IP_PATTERNS:
                for match in pattern.finditer(data):
                    if not allowed_ip(match[0].decode("ascii")):
                        if public and hashlib.sha256(match[0]).hexdigest() in PUBLIC_BASE_NETWORK_METADATA_SHA256:
                            continue
                        scanner.fail(path.name, "non-example private IP")
            for pattern, encoding in zip(RAW_WIDE_TEXT, ("utf-16-le", "utf-16-be")):
                for match in pattern.finditer(data):
                    scanner.text(match[0].decode(encoding).encode(), path.name, critical_only=True, public_base=public)

        class LayerReader:
            def __init__(self, stream, public):
                self.stream, self.public = stream, public
                self.sha, self.buffer, self.tail = hashlib.sha256(), bytearray(), b""
                self.count = 0

            def check(self, data):
                raw_security(self.tail + data, self.public)
                overlap = max([512] + [2 * len(value) + 2 for value in scanner.deny])
                self.tail = (self.tail + data)[-overlap:]

            def read(self, size=-1):
                data = self.stream.read(size)
                self.count += len(data)
                if self.count > MAX_ARCHIVE:
                    raise ValueError("oversized Docker layer")
                self.sha.update(data)
                self.buffer.extend(data)
                if len(self.buffer) >= 1024 * 1024 or not data:
                    self.check(bytes(self.buffer))
                    self.buffer.clear()
                return data

        try:
            with tarfile.open(path, "r:gz") as outer:
                members = outer.getmembers()
                if len(members) > MAX_MEMBERS or sum(m.size for m in members) > MAX_ARCHIVE:
                    raise ValueError("oversized Docker archive")
                files = {}
                for member in members:
                    name = safe_name(member.name)
                    if PurePosixPath(name).suffix.lower() in {".pdf", ".epub", ".docx", ".wav"}:
                        raise ValueError("forbidden document in Docker archive")
                    if member.isdir():
                        continue
                    if not member.isfile() or name in files:
                        raise ValueError("duplicate/link Docker archive entry")
                    files[name] = member

                def read_file(name, limit=MAX_FILE):
                    member = files[safe_name(name)]
                    if member.size > limit:
                        raise ValueError("oversized Docker metadata")
                    return outer.extractfile(member).read()

                manifest = json.loads(read_file("manifest.json"))
                if len(manifest) != 1 or manifest[0].get("RepoTags") != [CONTAINER_TAG]:
                    raise ValueError("unexpected Docker image/tag")
                image = manifest[0]
                config = json.loads(read_file(image["Config"]))
                layers = image["Layers"]
                referenced = set(layers) | {
                    image["Config"], "manifest.json", "index.json", "oci-layout", "repositories",
                }
                if any(
                    not re.fullmatch(r"blobs/sha256/[0-9a-f]{64}", name)
                    for name in set(files) - referenced
                ):
                    raise ValueError("unexpected Docker metadata file")
                diff_ids = config["rootfs"]["diff_ids"]
                prefix = len(CONTAINER_BASE_DIFF_IDS)
                if (
                    len(layers) != len(diff_ids) or len(set(layers)) != len(layers)
                    or tuple(diff_ids[:prefix]) != CONTAINER_BASE_DIFF_IDS
                    or config.get("os") != "linux" or config.get("architecture") != "amd64"
                ):
                    raise ValueError("unapproved Docker base/platform")
                settings = config["config"]
                if (
                    canonical_hash(settings.get("Env")) != CONTAINER_ENV_SHA256
                    or canonical_hash(settings.get("Labels")) != CONTAINER_LABELS_SHA256
                    or settings.get("Entrypoint") != ["nginx"]
                    or settings.get("Cmd") != ["-g", "daemon off;"]
                ):
                    raise ValueError("unapproved Docker environment/configuration")
                for history in config.get("history", []):
                    self.text(
                        history.get("created_by", "").encode(), path.name,
                        metadata_kind="public_base_history",
                    )
                # Docker-save's OCI descriptors/configs are read, never extracted.
                for name in set(files) - set(layers):
                    data = read_file(name, 1024 * 1024)
                    json.loads(data)
                    self.text(data, path.name, critical_only=True)

                web = "usr/share/nginx/html/"
                allowed = {web + name for name in (*CONTAINER_INSTALLERS, "SHA256SUMS", "index.html")}
                allowed.add("etc/nginx/conf.d/default.conf")
                directories = {str(parent) for name in allowed for parent in PurePosixPath(name).parents}
                seen, payload_hashes, checksum_data = set(), {}, b""
                for index, name in enumerate(layers):
                    source = outer.extractfile(files[safe_name(name)])
                    signature = source.read(2)
                    source.seek(0)
                    decompressed = gzip.GzipFile(fileobj=source) if signature == b"\x1f\x8b" else source
                    reader = LayerReader(decompressed, index < prefix)
                    with tarfile.open(fileobj=reader, mode="r|") as layer:
                        count = 0
                        for member in layer:
                            count += 1
                            if count > MAX_MEMBERS:
                                raise ValueError("too many layer files")
                            member_name = safe_name(member.name)
                            if PurePosixPath(member_name).suffix.lower() in {".pdf", ".epub", ".docx", ".wav"}:
                                self.fail(path.name, "forbidden document/audio in Docker layer")
                            if index < prefix:
                                continue  # Exact public base bytes are checked below.
                            if member.isdir():
                                if member_name not in directories:
                                    raise ValueError("unexpected added Docker directory")
                                continue
                            if not member.isfile() or member_name not in allowed or member_name in seen:
                                raise ValueError("unexpected/duplicate added Docker file")
                            if member.size > MAX_ARCHIVE:
                                raise ValueError("oversized Docker payload")
                            seen.add(member_name)
                            data = layer.extractfile(member).read()
                            basename = PurePosixPath(member_name).name
                            if basename in CONTAINER_INSTALLERS:
                                payload_hashes[basename] = hashlib.sha256(data).hexdigest()
                                pinned = basename == VOICE_NAME
                                if pinned and payload_hashes[basename] != VOICE_SHA256:
                                    self.fail(path.name, "container voice pack SHA256 mismatch")
                                else:
                                    with zipfile.ZipFile(io.BytesIO(data)) as archive:
                                        self.archive(archive, path.name + "!" + basename, basename.endswith(".apk"), pinned)
                            elif basename == "SHA256SUMS":
                                checksum_data = data
                            else:
                                self.text(data, path.name)
                    while reader.read(1024 * 1024):
                        pass
                    if "sha256:" + reader.sha.hexdigest() != diff_ids[index]:
                        raise ValueError("Docker layer digest mismatch")
                if seen != allowed:
                    raise ValueError("missing Docker installer files")
                expected = {}
                for line in checksum_data.decode("ascii").splitlines():
                    match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)", line)
                    if not match or match[2] in expected:
                        raise ValueError("invalid internal installer manifest")
                    expected[match[2]] = match[1]
                if expected != payload_hashes:
                    raise ValueError("internal installer manifest mismatch")
        except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError,
                tarfile.TarError, zipfile.BadZipFile, EOFError):
            self.fail(path.name, "invalid/unapproved Docker-save structure or payload")

    def archive(self, archive: zipfile.ZipFile, label: str, apk: bool, pinned: bool) -> None:
        members = archive.infolist()
        if len(members) > MAX_MEMBERS or sum(m.file_size for m in members) > MAX_ARCHIVE:
            self.fail(label, "archive exceeds review limit")
            return
        seen: set[str] = set()
        top_levels = {
            PurePosixPath(member.filename).parts[0]
            for member in members if PurePosixPath(member.filename).parts
        }
        for member in members:
            name = member.filename
            entry = label + "!" + name
            if name in seen:
                self.fail(entry, "duplicate archive entry")
            seen.add(name)
            if member.is_dir():
                continue
            if stat.S_ISLNK(member.external_attr >> 16):
                self.fail(entry, "archive symlink")
                continue
            problem = path_problem(name, apk=apk)
            if problem:
                # APK signatures use certificate containers, not signing keys.
                if not (apk and re.fullmatch(r"META-INF/[^/]+\.(RSA|DSA|EC)", name)):
                    self.fail(entry, problem)
                    continue
            self.text(name.encode(), entry)
            if pinned:
                # Exact immutable pack hash is the trust boundary for large model
                # and dictionary bytes. Never keyword-match arbitrary brand words.
                continue
            if member.file_size > MAX_FILE:
                self.fail(entry, "archive member exceeds review limit")
                continue
            data = archive.read(member)
            source_name = name
            # A source ZIP may wrap the entire project in one top-level folder.
            if not apk and len(top_levels) == 1:
                relative = PurePosixPath(*PurePosixPath(name).parts[1:]).as_posix()
                if relative in APPROVED_SOURCE_BINARIES:
                    source_name = relative
            self.blob(source_name, data, entry, apk=apk)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--history", action="store_true", help="also scan all locally reachable commits")
    parser.add_argument("--artifact", type=Path, action="append", default=[], help="scan APK/ZIP or the pinned Docker-save archive (repeatable); replaces tree scan")
    parser.add_argument("--deny-stdin", action="store_true", help="additional private literals, newline-delimited on stdin; never echoed")
    args = parser.parse_args(argv)
    scanner = Scanner([s for s in sys.stdin.buffer.read().splitlines() if s] if args.deny_stdin else [])
    try:
        if args.artifact:
            for path in args.artifact:
                scanner.artifact(path)
        else:
            root = args.root.absolute()
            if not root.is_dir() or root.is_symlink():
                scanner.fail("root", "root is not a regular directory")
            elif (root / ".git").exists():
                scanner.git_tree(root, args.history)
            else:
                scanner.tree(root)
    except Exception:
        scanner.fail("scan", "incomplete scan; resolve filesystem/git/archive error")
    for identifier, reason in sorted(scanner.errors):
        print(f"BLOCKED [{identifier}]: {reason}", file=sys.stderr)
    if scanner.errors:
        print(f"Privacy check FAILED: {len(scanner.errors)} finding(s); values and paths redacted.", file=sys.stderr)
        return 1
    print("Privacy check passed. Human review of synthetic screenshots and licenses is still required.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
