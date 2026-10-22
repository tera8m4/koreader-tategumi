# Stylus notes

Pen annotations for EPUB and other crengine documents on stylus devices such as
the Kindle Scribe. Horizontal and vertical (縦書き) text are both supported.

- **Write**: write or draw anywhere on the page, over the text or in the margins.
  The ink is pinned to the nearest text and follows it when the book reflows:
  after changes of font, size, margins or writing mode it moves and scales with
  its words. Margin ink stays beside its line.
- **Highlight**: a stroke highlights the text from where it starts to where it
  ends.
- **Erase**: removes the ink and the highlights it touches.
- **Handwritten notes**: the highlight dialog has a *Handwrite note* button that
  opens a ruled sheet. Tapping a highlight that has handwriting opens the sheet.
  Highlights with only handwriting get the typed note `✎`, so the existing note
  marks, filters and exports treat them as notes.

The pen tip writes by default. The eraser end erases. Holding the side button
erases, or highlights when *Side button highlights* is on. *Stylus notes →
Pen tip action* sets what the tip does, and the dispatcher actions *Stylus:
write / highlight / erase* bind it to gestures (useful for pens without
buttons). A short pen tap on a highlight opens it. Over menus and dialogs, the
pen works like a finger.

Ink is drawn while you write: it goes straight to the framebuffer and is
refreshed with the A2 waveform. Only page view mode is supported.

## Storage

Strokes are kept in the book's doc settings (`stylusnotes`), so they move,
sync and are purged with the book. Each stroke is stored as:

- an anchor xpointer
- the reference edge on the inline axis: `glyph`, or `start`/`end` for margins
- the points as a delta string in 1/64 em: inline offset, block offset, radius

See `stylusnotes/anchor.lua`.

## Native pieces

- `Input:registerStylusCallback`, `Input:stylusToScreen` and pen pressure
  (`frontend/device/input.lua`).
- `getXPointerFromScreenPoint` and `getXPointerLineMetrics` (`base/cre.cpp`,
  crengine `lvdocview_ink.cpp`).
- `BlitBuffer:paintStroke` (`base/blitbuffer.c`).
- In the SDL emulator, `KO_SDL_MOUSE_AS_PEN=1` turns the middle mouse button
  into the pen and X1 into the eraser.
