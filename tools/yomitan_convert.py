#!/usr/bin/env python3
"""Convert Yomitan dictionaries into the format read by yomitan.koplugin.

Usage:
    python3 tools/yomitan_convert.py [-o OUTPUT_DIR] DICTIONARY.zip [...]

Each input (a Yomitan .zip, or a directory with the same layout) becomes a
folder in OUTPUT_DIR (default: current directory) containing:

    dict.sqlite3   term and tag banks plus dictionary metadata
    styles.css     the dictionary stylesheet, if any
    media/         images referenced by the glossaries

Copy the resulting folders into koreader/data/yomitan/ on the device.

Glossaries are stored as zlib-compressed blocks of consecutive rows, which
keeps a full JMdict-sized dictionary in the tens of megabytes. Images in
formats KOReader cannot display (AVIF, WebP, ...) are converted to JPEG or PNG when
Pillow is installed (pip install Pillow); otherwise they are kept as-is and
reported.

The conversion mirrors Yomitan's DictionaryImporter
(ext/js/dictionary/dictionary-importer.js): term rows keep their bank order,
v1 rows are converted to the v3 layout, empty readings become the expression,
{"type": "text"} glossary items become strings, and image glossary items and
structured-content <img> nodes get their real pixel size stored next to their
preferred size. Frequency, pitch, IPA and kanji banks are not used by the
plugin and are skipped.

Only the Python standard library is required; Pillow is optional.
"""

import argparse
import io
import json
import os
import posixpath
import re
import shutil
import sqlite3
import struct
import sys
import tempfile
import zipfile
import zlib

SCHEMA_VERSION = 1  # Must match plugins/yomitan.koplugin/yomitan/db.lua
CONVERTER_VERSION = "1"

BANK_PATTERNS = {
    "term": re.compile(r"^term_bank_(\d+)\.json$"),
    "term_meta": re.compile(r"^term_meta_bank_(\d+)\.json$"),
    "kanji": re.compile(r"^kanji_bank_(\d+)\.json$"),
    "kanji_meta": re.compile(r"^kanji_meta_bank_(\d+)\.json$"),
    "tag": re.compile(r"^tag_bank_(\d+)\.json$"),
}

# Formats MuPDF (used by KOReader to render HTML definitions) can decode.
MUPDF_IMAGE_EXTENSIONS = {".png", ".jpg", ".jpeg", ".jfif", ".pjpeg", ".pjp", ".gif", ".bmp", ".tif", ".tiff", ".svg"}

# Rows per compressed glossary block: larger blocks compress better (JSON
# glossaries share a lot of structure), smaller ones are faster to read.
GLOSSARY_BLOCK_ROWS = 32

# Longest side of images re-encoded for KOReader (see convert_image).
CONVERTED_IMAGE_MAX_SIZE = 1024

try:
    from PIL import Image  # optional, used to convert unsupported images
except ImportError:  # pragma: no cover
    Image = None

SCHEMA = """
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE terms (
    id INTEGER PRIMARY KEY,
    expression TEXT NOT NULL,
    reading TEXT NOT NULL,
    definition_tags TEXT,
    rules TEXT,
    score REAL,
    glossary_block INTEGER NOT NULL,
    glossary_index INTEGER NOT NULL,
    sequence INTEGER,
    term_tags TEXT
);
CREATE TABLE tags (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    category TEXT,
    ord REAL,
    notes TEXT,
    score REAL
);
CREATE TABLE media (path TEXT PRIMARY KEY, width INTEGER, height INTEGER);
-- Newline-separated JSON glossaries of consecutive term rows, zlib-compressed.
CREATE TABLE glossary_blocks (id INTEGER PRIMARY KEY, size INTEGER NOT NULL, data BLOB NOT NULL);
"""

INDEXES = """
CREATE INDEX terms_expression ON terms(expression);
CREATE INDEX terms_reading ON terms(reading);
CREATE INDEX tags_name ON tags(name);
"""


class ConversionError(Exception):
    pass


class Source:
    """Read files from a zip archive or a directory, in archive order."""

    def __init__(self, path):
        self.path = path
        if os.path.isdir(path):
            self.zip = None
            names = []
            for root, _dirs, files in os.walk(path):
                for name in sorted(files):
                    full = os.path.join(root, name)
                    names.append(os.path.relpath(full, path).replace(os.sep, "/"))
            self.names = names
        else:
            self.zip = zipfile.ZipFile(path)
            self.names = [i.filename for i in self.zip.infolist() if not i.is_dir()]
        self.name_set = set(self.names)

    def read(self, name):
        if self.zip is not None:
            return self.zip.read(name)
        with open(os.path.join(self.path, *name.split("/")), "rb") as f:
            return f.read()

    def has(self, name):
        return name in self.name_set

    def read_json(self, name):
        try:
            return json.loads(self.read(name).decode("utf-8-sig"))
        except (ValueError, UnicodeDecodeError) as e:
            raise ConversionError(f"{name}: invalid JSON: {e}") from e


# Image size detection (Yomitan decodes images to get their real size).

def image_size(data, path):
    """Return (width, height) of an image, or None if it cannot be determined."""
    try:
        if data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] in (b"IHDR",):
            return struct.unpack(">II", data[16:24])
        if data[:6] in (b"GIF87a", b"GIF89a"):
            return struct.unpack("<HH", data[6:10])
        if data[:2] == b"BM":
            w, h = struct.unpack("<ii", data[18:26])
            return abs(w), abs(h)
        if data[:2] == b"\xff\xd8":
            return _jpeg_size(data)
        if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
            return _webp_size(data)
        if data[4:8] == b"ftyp":
            return _isobmff_size(data)
        if path.lower().endswith(".svg"):
            return _svg_size(data)
    except (struct.error, IndexError, ValueError):
        return None
    return None


def _jpeg_size(data):
    i = 2
    while i + 9 < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xD8, 0x01) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        length = struct.unpack(">H", data[i + 2:i + 4])[0]
        if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
            h, w = struct.unpack(">HH", data[i + 5:i + 9])
            return w, h
        i += 2 + length
    return None


def _isobmff_size(data):
    """Size from the 'ispe' property of an AVIF/HEIF image."""
    i = data.find(b"ispe")
    if i < 4:
        return None
    w, h = struct.unpack(">II", data[i + 8:i + 16])
    return w, h


def _webp_size(data):
    chunk = data[12:16]
    if chunk == b"VP8 ":
        w, h = struct.unpack("<HH", data[26:30])
        return w & 0x3FFF, h & 0x3FFF
    if chunk == b"VP8L":
        b = data[21:25]
        w = 1 + (((b[1] & 0x3F) << 8) | b[0])
        h = 1 + (((b[3] & 0x0F) << 10) | (b[2] << 2) | ((b[1] & 0xC0) >> 6))
        return w, h
    if chunk == b"VP8X":
        w = 1 + int.from_bytes(data[24:27], "little")
        h = 1 + int.from_bytes(data[27:30], "little")
        return w, h
    return None


def _svg_size(data):
    text = data[:4096].decode("utf-8", "replace")
    m = re.search(r"<svg\b[^>]*>", text, re.S)
    if not m:
        return None
    tag = m.group(0)

    def attr(name):
        a = re.search(r'\b' + name + r'\s*=\s*["\']\s*([0-9.]+)', tag)
        return float(a.group(1)) if a else None

    w, h = attr("width"), attr("height")
    if w and h:
        return round(w), round(h)
    vb = re.search(r'viewBox\s*=\s*["\']\s*[-0-9.]+[\s,]+[-0-9.]+[\s,]+([0-9.]+)[\s,]+([0-9.]+)', tag)
    if vb:
        return round(float(vb.group(1))), round(float(vb.group(2)))
    return None


def safe_folder_name(title):
    name = re.sub(r'[\x00-\x1f/\\:*?"<>|]', "_", title).strip(" .")
    return name or "dictionary"


def safe_media_path(path):
    norm = posixpath.normpath(path)
    if norm.startswith("/") or norm == ".." or norm.startswith("../") or "\x00" in norm:
        raise ConversionError(f"unsafe media path {path!r}")
    return norm


class GlossaryBlockWriter:
    """Pack glossary JSON of consecutive rows into compressed blocks."""

    def __init__(self, db):
        self.db = db
        self.block_id = 1
        self.pending = []

    def add(self, glossary_json):
        """Queue a glossary; return its (block id, index in block)."""
        if len(self.pending) >= GLOSSARY_BLOCK_ROWS:
            self.flush()
        self.pending.append(glossary_json)
        return self.block_id, len(self.pending) - 1

    def flush(self):
        if not self.pending:
            return
        # JSON text never contains a raw newline, so it separates entries.
        data = "\n".join(self.pending).encode("utf-8")
        self.db.execute("INSERT INTO glossary_blocks (id, size, data) VALUES (?, ?, ?)",
                        (self.block_id, len(data), zlib.compress(data, 9)))
        self.block_id += 1
        self.pending = []


class Converter:
    def __init__(self, source, out_dir, quiet=False):
        self.source = source
        self.out_dir = out_dir
        self.quiet = quiet
        self.media = {}  # path -> (width, height)
        self.warnings = []

    def log(self, msg):
        if not self.quiet:
            print(msg)

    def warn(self, msg):
        self.warnings.append(msg)

    def read_index(self):
        if not self.source.has("index.json"):
            nested = [n for n in self.source.names if n.endswith("/index.json")]
            if nested:
                raise ConversionError("index.json is inside a folder; the dictionary files must be at the root of the archive")
            raise ConversionError("missing index.json")
        index = self.source.read_json("index.json")
        if not isinstance(index, dict):
            raise ConversionError("index.json is not an object")
        title, revision = index.get("title"), index.get("revision")
        if not isinstance(title, str) or not isinstance(revision, str):
            raise ConversionError("index.json needs string 'title' and 'revision'")
        version = index.get("format", index.get("version"))
        if version not in (1, 2, 3):
            raise ConversionError(f"unsupported dictionary format/version {version!r}")
        return index, version

    def bank_files(self, kind):
        pattern = BANK_PATTERNS[kind]
        return [n for n in self.source.names if pattern.match(n)]

    # Images

    def load_image(self, path, context):
        """Store an image under media/ and return (stored_path, (width, height))."""
        if not isinstance(path, str) or not path:
            raise ConversionError(f"image without path in {context}")
        if path in self.media:
            return self.media[path]
        if not self.source.has(path):
            raise ConversionError(f"could not find image at path {path!r} for {context}")
        data = self.source.read(path)
        stored_path = path
        size = image_size(data, path)
        ext = posixpath.splitext(path)[1].lower()
        if ext not in MUPDF_IMAGE_EXTENSIONS:
            converted = self.convert_image(data, path)
            if converted is not None:
                # The glossary keeps the original size, as Yomitan computes
                # the layout from it; only the stored rendition may be smaller.
                data, size, new_ext = converted
                stored_path = path + new_ext
            else:
                self.warn(f"{path}: {ext or 'unknown'} images cannot be displayed by KOReader; install Pillow to convert them")
        if size is None or size[0] <= 0 or size[1] <= 0:
            self.warn(f"cannot determine the size of {path}; assuming 100x100")
            size = (100, 100)
        dest = os.path.join(self.tmp_dir, "media", *safe_media_path(stored_path).split("/"))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(data)
        self.media[path] = (stored_path, size)
        return self.media[path]

    def convert_image(self, data, path):
        """Re-encode an image with Pillow as JPEG (opaque) or PNG (with
        transparency), at most CONVERTED_IMAGE_MAX_SIZE pixels on its longest
        side. Returns (data, original size, extension), or None."""
        if Image is None:
            return None
        try:
            with Image.open(io.BytesIO(data)) as img:
                img.load()
                original_size = img.size
                has_alpha = img.mode in ("RGBA", "LA", "PA") or (img.mode == "P" and "transparency" in img.info)
                img = img.convert("RGBA" if has_alpha else "RGB")
                img.thumbnail((CONVERTED_IMAGE_MAX_SIZE, CONVERTED_IMAGE_MAX_SIZE))
                out = io.BytesIO()
                if has_alpha:
                    img.save(out, format="PNG", optimize=True)
                    return out.getvalue(), original_size, ".png"
                img.save(out, format="JPEG", quality=85, optimize=True)
                return out.getvalue(), original_size, ".jpg"
        except Exception as e:  # Pillow raises many exception types
            self.warn(f"{path}: cannot convert image ({e})")
            return None

    def create_image_data(self, source, context, structured):
        stored_path, (width, height) = self.load_image(source.get("path"), context)
        target = {"path": stored_path, "width": width, "height": height}
        if structured:
            target = {"tag": "img", **target}
        else:
            target = {"type": "image", **target}
        if isinstance(source.get("width"), (int, float)) and not isinstance(source.get("width"), bool):
            target["preferredWidth"] = source["width"]
        if isinstance(source.get("height"), (int, float)) and not isinstance(source.get("height"), bool):
            target["preferredHeight"] = source["height"]
        for key in ("title", "alt", "description", "imageRendering", "appearance"):
            if isinstance(source.get(key), str):
                target[key] = source[key]
        for key in ("pixelated", "background", "collapsed", "collapsible"):
            if isinstance(source.get(key), bool):
                target[key] = source[key]
        if structured:
            for key in ("verticalAlign", "border", "borderRadius", "sizeUnits"):
                if isinstance(source.get(key), str):
                    target[key] = source[key]
        return target

    def prepare_structured_content(self, content, context):
        if isinstance(content, list):
            return [self.prepare_structured_content(c, context) for c in content]
        if not isinstance(content, dict):
            return content
        if content.get("tag") == "img":
            return self.create_image_data(content, context, structured=True)
        if "content" in content:
            content = dict(content)
            content["content"] = self.prepare_structured_content(content["content"], context)
        return content

    def format_glossary(self, glossary, context):
        out = []
        for item in glossary:
            if isinstance(item, dict):
                kind = item.get("type")
                if kind == "text":
                    item = item.get("text", "")
                elif kind == "image":
                    item = self.create_image_data(item, context, structured=False)
                elif kind == "structured-content":
                    item = {"type": "structured-content", "content": self.prepare_structured_content(item.get("content"), context)}
                else:
                    raise ConversionError(f"unhandled glossary type {kind!r} in {context}")
            out.append(item)
        return out

    # Banks

    def convert_term_row(self, row, version, name, i):
        context = f"{name}[{i}]"
        if not isinstance(row, list):
            raise ConversionError(f"{context}: term row is not an array")
        if version == 1:
            if len(row) < 5:
                raise ConversionError(f"{context}: v1 term row needs at least 5 items")
            expression, reading, definition_tags, rules, score = row[:5]
            glossary, sequence, term_tags = list(row[5:]), None, ""
        else:
            if len(row) != 8:
                raise ConversionError(f"{context}: v3 term row needs exactly 8 items")
            expression, reading, definition_tags, rules, score, glossary, sequence, term_tags = row
            if not isinstance(glossary, list):
                raise ConversionError(f"{context}: glossary is not an array")
        if not isinstance(expression, str) or not isinstance(reading, str):
            raise ConversionError(f"{context}: expression and reading must be strings")
        if not isinstance(rules, str):
            raise ConversionError(f"{context}: rules must be a string")
        if not isinstance(score, (int, float)):
            raise ConversionError(f"{context}: score must be a number")
        if reading == "":
            reading = expression
        context = f"{expression}" + (f" ({reading})" if reading else "")
        glossary = self.format_glossary(glossary, context)
        row = (
            expression,
            reading,
            definition_tags if isinstance(definition_tags, str) else "",
            rules,
            score,
            sequence if isinstance(sequence, int) and not isinstance(sequence, bool) else None,
            term_tags if isinstance(term_tags, str) else "",
        )
        return row, json.dumps(glossary, ensure_ascii=False, separators=(",", ":"))

    def convert(self):
        index, version = self.read_index()
        title = index["title"]
        folder = os.path.join(self.out_dir, safe_folder_name(title))
        os.makedirs(self.out_dir, exist_ok=True)
        self.tmp_dir = tempfile.mkdtemp(prefix=".yomitan-", dir=self.out_dir)
        try:
            counts = self._convert_into(index, version)
            if os.path.exists(folder):
                shutil.rmtree(folder)
            os.replace(self.tmp_dir, folder)
        except BaseException:
            shutil.rmtree(self.tmp_dir, ignore_errors=True)
            raise
        return title, folder, counts

    def _convert_into(self, index, version):
        db = sqlite3.connect(os.path.join(self.tmp_dir, "dict.sqlite3"))
        try:
            db.execute("PRAGMA journal_mode = OFF")
            db.execute("PRAGMA synchronous = OFF")
            db.executescript(SCHEMA)
            counts = {"terms": 0, "tags": 0}

            blocks = GlossaryBlockWriter(db)
            for name in self.bank_files("term"):
                rows = self.source.read_json(name)
                if not isinstance(rows, list):
                    raise ConversionError(f"{name}: not an array")
                term_rows = []
                for i, raw_row in enumerate(rows):
                    row, glossary_json = self.convert_term_row(raw_row, version, name, i)
                    term_rows.append(row + blocks.add(glossary_json))
                db.executemany(
                    "INSERT INTO terms (expression, reading, definition_tags, rules, score, sequence, term_tags, glossary_block, glossary_index) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    term_rows)
                counts["terms"] += len(rows)
                self.log(f"  {name}: {len(rows)} terms")
            blocks.flush()

            old_tags = index.get("tagMeta") if isinstance(index.get("tagMeta"), dict) else {}
            for name in self.bank_files("tag"):
                rows = self.source.read_json(name)
                if not isinstance(rows, list):
                    raise ConversionError(f"{name}: not an array")
                tag_rows = []
                for i, row in enumerate(rows):
                    if not isinstance(row, list) or len(row) != 5:
                        raise ConversionError(f"{name}[{i}]: tag row needs exactly 5 items")
                    tag_rows.append(tuple(row))
                # Yomitan appends the legacy index.json tagMeta to every tag bank.
                for tag_name, value in old_tags.items():
                    value = value if isinstance(value, dict) else {}
                    tag_rows.append((tag_name, value.get("category"), value.get("order"), value.get("notes"), value.get("score")))
                db.executemany("INSERT INTO tags (name, category, ord, notes, score) VALUES (?, ?, ?, ?, ?)", tag_rows)
                counts["tags"] += len(tag_rows)

            for kind in ("term_meta", "kanji", "kanji_meta"):
                skipped = self.bank_files(kind)
                if skipped:
                    self.warn(f"skipped {len(skipped)} {kind.replace('_', ' ')} bank(s): not supported by KOReader")

            db.executemany("INSERT INTO media (path, width, height) VALUES (?, ?, ?)",
                           ((p, w, h) for p, (w, h) in self.media.values()))

            meta = {
                "title": index["title"],
                "revision": index["revision"],
                "format": str(version),
                "sequenced": "true" if index.get("sequenced") else "false",
                "converter_version": CONVERTER_VERSION,
                "source": os.path.basename(self.source.path.rstrip("/\\")),
                "term_count": str(counts["terms"]),
            }
            for key in ("author", "url", "description", "attribution", "sourceLanguage", "targetLanguage", "frequencyMode", "minimumYomitanVersion"):
                if isinstance(index.get(key), str):
                    meta[key] = index[key]
            db.executemany("INSERT INTO meta (key, value) VALUES (?, ?)", meta.items())

            db.executescript(INDEXES)
            db.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
            db.commit()
            db.execute("VACUUM")
        finally:
            db.close()

        if self.source.has("styles.css"):
            with open(os.path.join(self.tmp_dir, "styles.css"), "wb") as f:
                f.write(self.source.read("styles.css"))
        return counts


def main(argv=None):
    parser = argparse.ArgumentParser(description="Convert Yomitan dictionaries for KOReader's yomitan plugin.")
    parser.add_argument("inputs", nargs="+", help="Yomitan dictionary .zip files (or unpacked directories)")
    parser.add_argument("-o", "--output", default=".", help="output directory (default: current directory)")
    parser.add_argument("-q", "--quiet", action="store_true", help="only print errors and the summary")
    args = parser.parse_args(argv)

    # Dictionary titles are usually Japanese; don't crash on legacy consoles.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="backslashreplace")

    failed = 0
    for path in args.inputs:
        print(f"Converting {path}")
        try:
            converter = Converter(Source(path), args.output, quiet=args.quiet)
            title, folder, counts = converter.convert()
        except (ConversionError, OSError, zipfile.BadZipFile, sqlite3.Error) as e:
            print(f"  error: {e}", file=sys.stderr)
            failed += 1
            continue
        for w in converter.warnings:
            print(f"  warning: {w}")
        print(f"  {title}: {counts['terms']} terms, {counts['tags']} tags, {len(converter.media)} images -> {folder}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
