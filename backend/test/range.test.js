import assert from 'node:assert/strict';
import test from 'node:test';
import { parseByteRange } from '../src/range.js';

test('parseByteRange accepts bounded, open, and suffix ranges', () => {
  assert.deepEqual(parseByteRange('bytes=10-19', 100), {
    start: 10, end: 19, length: 10, unsatisfiable: false,
  });
  assert.deepEqual(parseByteRange('bytes=90-', 100), {
    start: 90, end: 99, length: 10, unsatisfiable: false,
  });
  assert.deepEqual(parseByteRange('bytes=-12', 100), {
    start: 88, end: 99, length: 12, unsatisfiable: false,
  });
  assert.deepEqual(parseByteRange('bytes=-999', 100), {
    start: 0, end: 99, length: 100, unsatisfiable: false,
  });
});

test('parseByteRange clamps end and rejects invalid or multiple ranges', () => {
  assert.deepEqual(parseByteRange('bytes=95-999', 100), {
    start: 95, end: 99, length: 5, unsatisfiable: false,
  });
  for (const value of ['items=0-1', 'bytes=100-', 'bytes=8-2', 'bytes=0-1,4-5', 'bytes=-0', 'bytes=-']) {
    assert.deepEqual(parseByteRange(value, 100), { unsatisfiable: true });
  }
  assert.equal(parseByteRange(undefined, 100), null);
});
