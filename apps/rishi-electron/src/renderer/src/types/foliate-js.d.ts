// foliate-js ships pure ESM with no .d.ts. Decoder API is intentionally
// loose (it returns parsed sections with whatever the book contains), so
// we silence the implicit-any warning rather than over-typing it. The
// Azw3View / parser modules type their consumption locally.
declare module 'foliate-js/mobi.js'
declare module 'foliate-js/vendor/fflate.js'
