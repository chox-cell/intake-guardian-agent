import { describe, it } from 'node:test';
import assert from 'node:assert';
import { normalizeText } from './normalize';

describe('normalizeText', () => {
  it('should trim whitespace from both ends', () => {
    assert.strictEqual(normalizeText('  hello world  '), 'hello world');
  });

  it('should convert text to lowercase', () => {
    assert.strictEqual(normalizeText('Hello WORLD'), 'hello world');
  });

  it('should normalize Windows line endings to Unix', () => {
    assert.strictEqual(normalizeText('line1\r\nline2'), 'line1\nline2');
  });

  it('should collapse multiple spaces and tabs into a single space', () => {
    assert.strictEqual(normalizeText('word1   word2\t\tword3'), 'word1 word2 word3');
  });

  it('should reduce 3 or more newlines to 2 newlines', () => {
    assert.strictEqual(normalizeText('line1\n\n\nline2'), 'line1\n\nline2');
    assert.strictEqual(normalizeText('line1\n\n\n\nline2'), 'line1\n\nline2');
  });

  it('should handle complex combinations', () => {
    const input = '  Title\r\n\r\n  Subtitle\t\tHere   \n\n\nContent  ';
    // Breakdown:
    // 1. \r\n -> \n => "  Title\n\n  Subtitle\t\tHere   \n\n\nContent  "
    // 2. [ \t]+ -> " " => " Title\n\n Subtitle Here \n\n\nContent "
    // 3. \n{3,} -> \n\n => " Title\n\n Subtitle Here \n\nContent "
    // 4. trim() => "Title\n\n Subtitle Here \n\nContent"
    // 5. toLowerCase() => "title\n\n subtitle here \n\ncontent"

    // Wait, let's trace the implementation order:
    // .replace(/\r\n/g, "\n")
    // .replace(/[ \t]+/g, " ")
    // .replace(/\n{3,}/g, "\n\n")
    // .trim()
    // .toLowerCase();

    // Trace:
    // input: '  Title\r\n\r\n  Subtitle\t\tHere   \n\n\nContent  '
    // replace 1 (\r\n -> \n): '  Title\n\n  Subtitle\t\tHere   \n\n\nContent  '
    // replace 2 ([ \t]+ -> " "): ' Title\n\n Subtitle Here \n\n\nContent ' (Note: leading spaces become ' ')
    // replace 3 (\n{3,} -> \n\n): ' Title\n\n Subtitle Here \n\nContent '
    // trim: 'Title\n\n Subtitle Here \n\nContent'
    // lower: 'title\n\n subtitle here \n\ncontent'

    // Wait, replace 2 collapses spaces.
    // '  Title' -> ' Title' (because it matches the two spaces at start)
    // '\n  Subtitle' -> '\n Subtitle' (matches spaces after newline)

    const expected = 'title\n\n subtitle here \n\ncontent';
    assert.strictEqual(normalizeText(input), expected);
  });

  it('should return empty string for null/undefined input if types allowed (checking resilience, though typed string)', () => {
     // Since it's TS, we assume string input. But checking empty string:
     assert.strictEqual(normalizeText(''), '');
     assert.strictEqual(normalizeText('   '), '');
  });
});
