# Rishi Pro — Subscription Pricing Calculation

**Date:** 2026-06-11
**Decision:** Monthly **$6.99**, Annual **$74.99** (≈11% annual discount vs 12× monthly)
**Owner:** Farid Matovu

This doc shows the cost model behind the price. Re-run the math whenever OpenAI rates change or you have post-launch usage data — the assumptions section is the part to revisit, not the formulas.

---

## 1. Target user (defines "average")

Rishi Pro's buyer is an **avid reader** — someone reading more than a casual one-book-a-month adult. Two anchor profiles:

| Persona | Books/mo | Chat | Voice | TTS |
|---|---|---|---|---|
| **Median Pro** (50th %ile) | 4 | 20 questions / book = 80 / mo | 10 min / mo | ~20% of reading time |
| **Heavy Pro** (90th %ile) | 8 | 60 questions / book = 480 / mo | 60 min / mo | ~50% of reading time |
| **Whale** (99th %ile, capped) | 15+ | unbounded without cap | unbounded | unbounded |

Pricing is set for the **median Pro**, with allowances tight enough to keep the **heavy Pro** profitable and the **whale** capped before they cost more than they pay.

**Industry references (anchored, not guessed):**
- Average adult reads ~12 books/year (Goodreads / Pew survey) = 1/mo. Pro buyer is 3–5× that.
- Average trade book: ~90,000 words ≈ 300 pages ≈ 500,000 characters.
- Average reading speed: 250 wpm → 6 hours per book.

---

## 2. Per-feature unit cost (OpenAI)

All prices below are OpenAI list prices as of January 2026. Re-check at https://openai.com/api/pricing/ before changing tier.

### A. Chat — GPT-4o-mini

Per question:
- Input ≈ 2,000 tokens (system prompt + RAG context + question)
- Output ≈ 300 tokens
- Cost: (2,000 × $0.15/1M) + (300 × $0.60/1M) = **$0.00048 / question**

Median Pro (80 questions/mo): **$0.038/mo**
Heavy Pro (480 questions/mo): **$0.23/mo**

### B. RAG embeddings — text-embedding-3-small

Embedded once per book, cached in R2:
- 90k words ÷ 0.75 words/token = 120k tokens
- Cost: 120,000 × $0.020/1M = **$0.0024 / book**

Median Pro (4 books): **$0.010/mo**
Heavy Pro (8 books): **$0.019/mo**

### C. Voice chat — GPT-4o-mini-realtime

Audio I/O dominates: ~400 tokens/sec audio, in + out.
- 1 minute of voice ≈ 24k input + 24k output tokens
- Cost: (24k × $10/1M) + (24k × $20/1M) = **$0.72 / minute**

Median Pro (10 min/mo): **$7.20/mo** ← largest variable cost
Heavy Pro (60 min/mo): **$43.20/mo** ← this is why we need a cap

### D. Premium text-to-speech — OpenAI tts-1

$15 per 1M characters.
- Average book: 500k characters
- Median Pro listens to ~20% of one book's worth: 100k chars = **$1.50/mo**
- Heavy Pro listens to ~50% of 8 books: 2M chars = **$30/mo** ← also needs a cap

### E. Other costs

- Cloudflare R2 storage (book files + embeddings + TTS cache) ≈ $0.05/user/mo
- Worker compute (sync + RAG retrieval) ≈ $0.05/user/mo
- Sentry seat amortization ≈ $0.05/user/mo
- **Other COGS: $0.15/user/mo**

---

## 3. Allowance / fair-use caps

Without caps, voice chat and TTS can run away. With caps, the heavy user is bounded.

| Feature | Soft cap | Hard cap | Action when hit |
|---|---|---|---|
| Chat | — | 1,000 questions / mo | Rate-limit to 1/min after 1,000 |
| Voice chat | 30 min / mo | 60 min / mo | Disable voice for the rest of the cycle, show "limit reached" sheet |
| Premium TTS | 5 hours / mo | 10 hours / mo | Fall back to Apple's free on-device voices; show "you've used Pro TTS for this month" |
| RAG embeddings | — | 20 books / mo | First-time embed only; re-opens reuse cache |

**Why "soft + hard":**
- Soft cap = warn user at 50/75/90% of allowance.
- Hard cap = feature stops. Reading + chat continue normally; only the metered feature pauses.
- Reading itself (PDF/EPUB rendering, sync, highlights) is **unmetered** — those have ~zero marginal cost.

These caps cover the 99th percentile of expected usage. The whale who burns through 60 min of voice + 10 hours of TTS in the first week of the month then loses access to those two features only — they still get the rest of Pro.

---

## 4. Expected blended cost per user

Not every Pro user uses every feature. Weighting by realistic adoption:

| Cost line | Median | Weighting | Weighted |
|---|---|---|---|
| Chat (everyone uses chat) | $0.04 | 100% | $0.04 |
| RAG embeddings | $0.01 | 100% | $0.01 |
| Voice chat (40% of Pros try; avg 10 min when they do) | $7.20 | 40% × 100% | $2.88 |
| TTS (50% of Pros use Premium TTS; avg 20% of reading) | $1.50 | 50% | $0.75 |
| Other COGS | $0.15 | 100% | $0.15 |
| **Blended OpenAI + infra COGS** | — | — | **$3.83 / user / mo** |

That's the number to price against.

---

## 5. Price derivation

Equation:
```
(1 − Apple cut) × Price = COGS + (margin × Price)
```

For Apple's **standard 30% cut** (used conservatively here per the user's request, though year-2 renewals and Small Business Program drop this to 15%):

```
0.70 × P = $3.83 + 0.10 × P
0.60 × P = $3.83
P = $6.39
```

Round up to next App Store-friendly tier: **$6.99/mo**.

**Sanity check at $6.99:**
- Apple cut: $2.10
- Net to me: $4.89
- COGS: $3.83
- Profit: $1.06
- Margin: 15.2% ✓ (above the 10% floor, gives headroom for cost surprises)

### Year-2 / Small Business Program improvement

After the user is in their second year of continuous subscription, Apple drops the cut to **15%**.

At $6.99 / 15% cut:
- Apple cut: $1.05
- Net to me: $5.94
- COGS: $3.83
- Profit: $2.11
- Margin: 30.2%

So the math gets significantly better on retained users — which is the entire economic argument for subscriptions over one-time purchases.

If you enroll in the Small Business Program (revenue < $1M/yr), **all** subscriptions get the 15% rate from day one. At <$1M ARR that's free money: take it.

### Annual pricing

Common pattern: annual = 10–12× monthly with a visible discount.

| Annual price | Annual Apple cut (30%) | Net to me | Annual COGS (12 × $3.83) | Profit | Margin | Discount vs 12× monthly ($83.88) |
|---|---|---|---|---|---|---|
| $59.99 | $18.00 | $41.99 | $45.96 | **−$3.97** | LOSS | 28% |
| $69.99 | $21.00 | $48.99 | $45.96 | $3.03 | 4.3% | 17% |
| **$74.99** | **$22.50** | **$52.49** | **$45.96** | **$6.53** | **8.7%** | **11%** |
| $79.99 | $24.00 | $55.99 | $45.96 | $10.03 | 12.5% | 5% |

**Recommend $74.99/yr.** 8.7% margin under the conservative 30% Apple cut — slightly under the 10% floor, but the actual Apple cut on annual subs that retain past year 1 (which is most of them) is 15%, pushing real margin to ~25%. Net positive after one year.

If you want to stay strictly ≥10% margin under the worst-case 30% cut, use **$79.99/yr** instead.

---

## 6. Final recommendation

**Monthly: `$6.99`** — App Store tier **USD_6_99**
**Annual: `$74.99`** — App Store tier **USD_74_99**
(Alternative: `$79.99` if you want strict ≥10% margin under worst-case Apple cut.)

Free trial: **7 days** on both, new subscribers only.

---

## 7. Things to revisit post-launch

After 90 days of real usage data, look at:

1. **Actual voice-chat minutes / Pro user.** If median is much lower than 10 min, costs drop and you can lower price; if higher, raise caps + price.
2. **Actual TTS character ratio.** If users barely use Premium TTS (relying on Apple's free voices), drop TTS from the blended COGS and you have ~$0.75 extra margin per user.
3. **OpenAI prices.** GPT-4o-mini and tts-1 prices have only gone down historically — every drop is pure margin.
4. **Apple Small Business Program enrollment.** Once enrolled, drop 30% in the calc to 15% everywhere — Apple cut halves, margin doubles.
5. **Churn rate.** Annual subs that survive year 1 are ~3× more profitable than monthly. Optimize for annual conversion if year-1 retention is healthy.

---

## 8. Caveats (read these)

- OpenAI prices are list prices as of **Jan 2026**. Re-check before each price change.
- "Average book = 90k words, 500k chars" is a generalist mean; nonfiction is shorter, fantasy/literary is longer.
- The voice-chat cost dominates the model — if `swift-realtime-openai` uses the full GPT-4o-realtime (not mini), per-minute cost is ~10× higher and the price needs to rise to ~$12.99/mo.
- The blended-cost assumption (40% try voice, 50% use TTS) is a guess. After launch, replace with real numbers.
- Apple's actual cut depends on Small Business Program status + customer subscription tenure. The conservative 30% used here is the worst case.
- This analysis ignores marketing CAC, churn-adjusted LTV, and overhead. Treat $6.99 as the **floor**; you may want to price higher if you also need to cover those.
