export function parseByteRange(header, size) {
  if (!Number.isSafeInteger(size) || size < 0) throw new TypeError('size must be a non-negative safe integer');
  if (header === undefined || header === null || header === '') return null;
  if (typeof header !== 'string' || !header.startsWith('bytes=')) return { unsatisfiable: true };

  const specification = header.slice(6).trim();
  if (!specification || specification.includes(',')) return { unsatisfiable: true };
  const match = /^(\d*)-(\d*)$/u.exec(specification);
  if (!match || (!match[1] && !match[2]) || size === 0) return { unsatisfiable: true };

  let start;
  let end;
  if (!match[1]) {
    const suffixLength = Number(match[2]);
    if (!Number.isSafeInteger(suffixLength) || suffixLength <= 0) return { unsatisfiable: true };
    start = Math.max(size - suffixLength, 0);
    end = size - 1;
  } else {
    start = Number(match[1]);
    end = match[2] ? Number(match[2]) : size - 1;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start >= size || end < start) {
      return { unsatisfiable: true };
    }
    end = Math.min(end, size - 1);
  }

  return { start, end, length: end - start + 1, unsatisfiable: false };
}
