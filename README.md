# koreader-tategumi

**English** | [日本語](#日本語)

A [KOReader](https://github.com/koreader/koreader) fork for Japanese books:
vertical text (縦書き), right-to-left manga, Yomitan dictionary lookups and
line breaking that keeps words together. Based on
[m-tky/koreader-tategumi](https://github.com/m-tky/koreader-tategumi) and synced
with upstream KOReader master.

![Vertical text rendering of 三四郎 (Natsume Soseki)](doc/screenshots/tategumi.png)

## Install

Download the package for your device from the
[latest release](https://github.com/tera8m4/koreader-tategumi/releases/latest)
and install it like upstream KOReader
([Kindle](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices) •
[Kobo](https://github.com/koreader/koreader/wiki/Installation-on-Kobo-devices) •
[Android](https://github.com/koreader/koreader/wiki/Installation-on-Android-devices)).
Installing over an existing KOReader keeps your settings.

For vertical text, choose a Japanese font with the OpenType `vert` and `vrt2`
features, such as Noto Serif CJK JP.

## Dictionary

Each release includes `yomitan-jitendex.zip`, [Jitendex](https://jitendex.org)
converted for the Yomitan plugin:

1. Unzip it into `koreader/data/yomitan/` on the device.
2. Enable it in **Search settings → Yomitan dictionaries → Manage dictionaries**.

To use other Yomitan dictionaries, convert them on a computer with
`python3 tools/yomitan_convert.py -o out/ dictionary.zip` and copy each folder
from `out/` to the same place. On Windows, `tools/yomitan_install.ps1` converts
them and copies them to a Kindle connected over USB. See the
[plugin README](plugins/yomitan.koplugin/README.md).

## Yomitan lookups

- Long-press a character, or tap it with **Tap to look up**, to select the
  longest word starting there, including inflected forms
  (食べさせられた → 食べる). Furigana is skipped.
- A compact popup shows short definitions; **Full** opens the whole entry with
  tags, the inflection chain and images.
- Looked-up words are remembered per book and marked wherever they appear
  again, with optional furigana and export to Anki
  (**Search → Looked-up words**).

## Line breaking

In vertical text, columns no longer break in the middle of a word (飛び降|りる).
The text is split into words with the enabled Yomitan dictionaries, inflected
forms included, and a column break:

- falls between words where it can, keeping short particles with their word
  (二階から|飛び降りて);
- leaves at least 3 letters on each side when it has to split a word;
- keeps idioms such as 腰を抜かす together;
- squeezes the rest of a word into the column when the column's punctuation
  spacing can shrink, instead of splitting it.

This is on whenever a Yomitan dictionary is enabled. Columns can be slightly
looser, and books take a little longer to render. See
[doc/Japanese_line_breaking.md](doc/Japanese_line_breaking.md).

## Vertical text and manga

- EPUBs with `writing-mode: vertical-rl` render vertically. For other books,
  enable **Document → Document settings → Vertical reading** (saved per book).
- Manga EPUBs with `page-progression-direction="rtl"`, and CBZ/CBR/CBT archives
  marked right-to-left in `ComicInfo.xml`, turn pages right to left. Change it
  in **Menu → Taps & gestures → Page turns → Switch page-turn direction**.

## Credits

Built on [KOReader](https://github.com/koreader/koreader) (AGPL-3.0) and
[m-tky/koreader-tategumi](https://github.com/m-tky/koreader-tategumi).
Jitendex is licensed under CC BY-SA 4.0 and includes JMdict data from the
[EDRDG](https://www.edrdg.org/).

---

# 日本語

[English](#koreader-tategumi) | **日本語**

日本語書籍向けの [KOReader](https://github.com/koreader/koreader) フォークです。
縦書き、右開きの漫画、Yomitan 方式の辞書引き、単語を分割しない改行に対応しています。
[m-tky/koreader-tategumi](https://github.com/m-tky/koreader-tategumi) をベースに、
upstream KOReader の master と同期しています。

![三四郎（夏目漱石）の縦書き表示](doc/screenshots/tategumi.png)

## インストール

[最新リリース](https://github.com/tera8m4/koreader-tategumi/releases/latest)から
端末向けのパッケージをダウンロードし、upstream KOReader と同じ手順でインストール
してください
（[Kindle](https://github.com/koreader/koreader/wiki/Installation-on-Kindle-devices) •
[Kobo](https://github.com/koreader/koreader/wiki/Installation-on-Kobo-devices) •
[Android](https://github.com/koreader/koreader/wiki/Installation-on-Android-devices)）。
既存の KOReader に上書きすれば設定は引き継がれます。

縦書きには、OpenType の `vert` と `vrt2` 機能を持つ日本語フォント
（Noto Serif CJK JP など）を選んでください。

## 辞書

各リリースには、Yomitan プラグイン用に変換した [Jitendex](https://jitendex.org)
（`yomitan-jitendex.zip`）が含まれます:

1. 端末の `koreader/data/yomitan/` に展開します。
2. **検索設定 → Yomitan dictionaries → Manage dictionaries** で有効にします。

ほかの Yomitan 辞書は、パソコン上で
`python3 tools/yomitan_convert.py -o out/ dictionary.zip` により変換し、`out/` 内の
各フォルダを同じ場所にコピーしてください。Windows では `tools/yomitan_install.ps1`
が変換と、USB 接続した Kindle へのコピーを行います。詳細は
[プラグインの README](plugins/yomitan.koplugin/README.md) を参照してください。

## Yomitan 辞書引き

- 文字を長押し（**Tap to look up** 有効時はタップ）すると、そこから始まる最長の
  単語を選択します。活用形にも対応します（食べさせられた → 食べる）。ルビは
  読み飛ばします。
- コンパクトなポップアップに短い定義を表示し、**Full** でタグ・活用の経路・画像を
  含む全体を開きます。
- 調べた単語は本ごとに記録され、再び出てきた箇所に印が付きます。ふりがな表示と
  Anki への送信も可能です（**検索 → Looked-up words**）。

## 改行

縦書きで、単語の途中での改行（飛び降|りる）を避けます。有効な Yomitan 辞書を使って
本文を単語（活用形を含む）に分け、改行位置を次のように選びます:

- できるだけ単語の間で改行し、短い助詞は前の単語と一緒にします（二階から|飛び降りて）。
- 単語の途中で改行する場合も、前後に 3 文字以上を残します。
- 腰を抜かす などの慣用句は分割しません。
- 行内の約物の空きを詰められる場合は、単語を分割せずに残りを行内に収めます。

Yomitan 辞書を有効にしている間は常に動作します。行の字間がやや広がることがあり、
本の描画に少し時間がかかります。詳細は
[doc/Japanese_line_breaking.md](doc/Japanese_line_breaking.md) を参照してください。

## 縦書きと漫画

- `writing-mode: vertical-rl` を含む EPUB は縦書きで表示されます。それ以外の本は
  **Document → Document settings → Vertical reading** で縦書きにできます（本ごとに保存）。
- `page-progression-direction="rtl"` の漫画 EPUB と、`ComicInfo.xml` で右開きと
  指定された CBZ/CBR/CBT は右から左へページをめくります。
  **メニュー → タップとジェスチャー → ページめくり → ページめくり方向を切り替え**
  で変更できます。

## クレジット

[KOReader](https://github.com/koreader/koreader)（AGPL-3.0）と
[m-tky/koreader-tategumi](https://github.com/m-tky/koreader-tategumi) をベースに
しています。Jitendex は CC BY-SA 4.0 で提供され、[EDRDG](https://www.edrdg.org/)
の JMdict のデータを含みます。
