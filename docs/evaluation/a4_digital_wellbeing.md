# A4: Anchor vs Digital Wellbeing (thesis 5.4.5)

Check from the spec: compare full days of Anchor's screen time with
Android's Digital Wellbeing; Anchor should be no more than 10% higher.

Device: the researcher's own Samsung phone (One UI Digital Wellbeing,
weekly report W46, 8–14 Nov 2026). Anchor values are the saved
`usage_daily` rows from the export of 20 Nov 2026 (`total_min`).

| Day | Anchor | Digital Wellbeing | Difference |
|---|---|---|---|
| Fri 13 Nov 2026 | 7.4 h (446.6 min) | ≈ 7.7 h | Anchor ≈ 4% lower |
| Sat 14 Nov 2026 | 12.4 h (746.8 min) | ≈ 12.7 h | Anchor ≈ 2% lower |

**Result: within 10%, and Anchor is slightly lower, not higher.**

Notes:

- Digital Wellbeing values were read from the weekly bar chart (about
  ±0.3 h). Exact values can be read by tapping each day in Digital
  Wellbeing; replace the estimates if they are needed.
- These two rows have no `counting_version` (saved before A5), so they were
  counted by the A2 or A4 logic. Either way the result holds.
- A small under-count is expected: Anchor ignores the launcher, the system
  UI and Anchor itself, and does not count picture-in-picture video.
- Categories differ between the tools, so only totals are compared.
  Samsung's "Social" includes WhatsApp and Chrome; Anchor puts messaging
  apps under `chat` and browsers under `other`.

## Observation: category is not purpose

The largest share of the researcher's "other" time that week (about 3.7 h a
day) was one AI chat app, used mainly for creative writing. Like a video
app playing music in the background while studying, the app's category
alone does not say whether the use was problematic. This supports the
design choice of pairing passive screen-time sensing with self-reported
logs and drafted episodes, where the user says what the session was for.
AI chat apps are not a separate group in Anchor; treating them as their
own category is possible future work.
