// Preloaded with `node --import <this file>` so the ORIGINAL status-writer.js runs unmodified
// but sees a deterministic clock: `new Date()` / `Date.now()` return CODD_FAKE_NOW (ISO string).
// Every other Date behaviour (parsing, formatting, explicit arguments) is untouched.
const RealDate = globalThis.Date;
const fixed = process.env.CODD_FAKE_NOW;

if (fixed) {
  const fixedMs = RealDate.parse(fixed);
  if (!Number.isFinite(fixedMs)) throw new Error(`CODD_FAKE_NOW is not a valid date: ${fixed}`);

  class FakeDate extends RealDate {
    constructor(...args) {
      if (args.length === 0) super(fixedMs);
      else super(...args);
    }
    static now() {
      return fixedMs;
    }
  }
  globalThis.Date = FakeDate;
}
