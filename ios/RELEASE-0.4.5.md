# CapyFlow 0.4.5 build 12 — automatic album recording fallbacks

The previous resolver searched title/artist once, then appended album context.
An empty Songs response threw before that second query; strict title equality
also excluded harmless formatting differences. It now runs a bounded, deduplicated
query plan through the same Songs-filtered search and parser used by normal Search.
The plan includes artist/title, title/artist, original featured-artist formatting,
normalized title, album context, punctuation-neutral text and movie-title context.
Empty responses and transient query failures advance to the next query. Cancellation
and offline errors retain their appropriate behavior; failures are never cached.

Every returned candidate is scored for title, exact/credited artist, duration,
album agreement, source type and explicitness. Verified audio, Topic and official
audio receive preference. Close spelling/spacing/article differences require
corroboration. Music videos are rejected unless the requested metadata explicitly
asks for that version. Live, cover, karaoke, instrumental, remix, slowed, sped-up,
nightcore, extended, acoustic and language annotations must agree. Movie edit and
movie version remain distinct, including when their durations coincide. A Songs
listing that omits a movie annotation requires exact album/duration corroboration.
Primary playback endpoints determine source type; unrelated menu endpoints cannot
randomly classify an audio row as a video.

Existing canonical aliases are reused first. Cold album audio rows also reach
Songs automatically; a trustworthy primary album audio ID is a final fallback
after exhausting the query plan. Album video IDs are never used for that fallback.
Strong matches finish on the first query. Subsequent plays, downloads, lyrics,
playlist recovery and duration updates reuse the same persisted canonical identity.
Normal Songs results use the same index, so neither entry point requires manual
search priming. No MSI backend change, media transcoding, UI redesign or social
permission change is included.

Regression fixtures capture real Your Name., THE TORTURED POETS DEPARTMENT and
OK Computer rows and Songs responses. They include Nandemonaiya movie edit,
Sparkle movie version, Katawaredoki, Date 2, Fortnight, The Tortured Poets Department,
Let Down and Electioneering. Additional tests cover empty/wrong first results,
late metadata enrichment of the same media ID, all-query exhaustion and retry,
punctuation, credits, ordinary Radiohead titles, explicitness, forbidden versions,
and canonical stream/download/lyrics/quality cache convergence. Existing responsive
and safe-area/header-centering tests remain enabled on all three device sizes.

Real-device acceptance: try previously failing album rows before Songs search,
then download and save them, relaunch and play offline. Check the short movie edit
against the longer movie version. Confirm the same lyrics/duration after entering
through Songs and retain normal routing and lock-screen playback behavior.
