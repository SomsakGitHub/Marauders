/** Max bytes to remux in the Worker (memory-safe on the 128 MB isolate limit). */
export const MP4_FASTSTART_MAX_BYTES = 80 * 1024 * 1024;

type Mp4Box = {
  offset: number;
  size: number;
  type: string;
};

/**
 * Moves the `moov` atom before `mdat` so AVPlayer can start with HTTP Range
 * without downloading the entire file (same idea as `qt-faststart` / `-movflags +faststart`).
 */
export function mp4ApplyFastStart(input: Uint8Array): Uint8Array {
  if (input.byteLength < 16) {
    return input;
  }
  if (!isIsoBmff(input)) {
    return input;
  }

  const boxes = parseTopLevelBoxes(input);
  const moovIndex = boxes.findIndex((box) => box.type === "moov");
  const mdatIndex = boxes.findIndex((box) => box.type === "mdat");
  if (moovIndex < 0 || mdatIndex < 0 || moovIndex < mdatIndex) {
    return input;
  }

  const mdat = boxes[mdatIndex];
  const moov = boxes[moovIndex];
  const mdatEnd = mdat.offset + mdat.size;

  const chunks: Uint8Array[] = [];

  for (const box of boxes) {
    if (box.type === "moov") {
      continue;
    }
    if (box.offset < mdat.offset) {
      chunks.push(input.subarray(box.offset, box.offset + box.size));
    }
  }

  chunks.push(input.subarray(moov.offset, moov.offset + moov.size));
  chunks.push(input.subarray(mdat.offset, mdat.offset + mdat.size));

  for (const box of boxes) {
    if (box.type === "moov" || box.type === "mdat") {
      continue;
    }
    if (box.offset >= mdatEnd) {
      chunks.push(input.subarray(box.offset, box.offset + box.size));
    }
  }

  const total = chunks.reduce((sum, part) => sum + part.byteLength, 0);
  const output = new Uint8Array(total);
  let writeOffset = 0;
  for (const part of chunks) {
    output.set(part, writeOffset);
    writeOffset += part.byteLength;
  }
  return output;
}

function isIsoBmff(bytes: Uint8Array): boolean {
  if (bytes.byteLength < 8) {
    return false;
  }
  const type = readBoxType(bytes, 4);
  return type === "ftyp" || type === "moov" || type === "mdat";
}

function readBoxType(bytes: Uint8Array, typeOffset: number): string {
  return String.fromCharCode(
    bytes[typeOffset],
    bytes[typeOffset + 1],
    bytes[typeOffset + 2],
    bytes[typeOffset + 3],
  );
}

function parseTopLevelBoxes(bytes: Uint8Array): Mp4Box[] {
  const boxes: Mp4Box[] = [];
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let offset = 0;

  while (offset + 8 <= bytes.byteLength) {
    let size = view.getUint32(offset, false);
    const type = readBoxType(bytes, offset + 4);
    let headerSize = 8;

    if (size === 0) {
      size = bytes.byteLength - offset;
    } else if (size === 1) {
      if (offset + 16 > bytes.byteLength) {
        break;
      }
      const sizeBig =
        (BigInt(view.getUint32(offset + 8, false)) << 32n) |
        BigInt(view.getUint32(offset + 12, false));
      if (sizeBig > BigInt(Number.MAX_SAFE_INTEGER)) {
        break;
      }
      size = Number(sizeBig);
      headerSize = 16;
    }

    if (size < headerSize || offset + size > bytes.byteLength) {
      break;
    }

    boxes.push({ offset, size, type });
    offset += size;
  }

  return boxes;
}
