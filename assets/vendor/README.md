# Supabase browser SDK

`supabase-2.118.0.js` is the pinned official UMD distribution of
`@supabase/supabase-js@2.118.0` (MIT), downloaded from
https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.118.0/dist/umd/supabase.js
on 2026-10-20. SHA256:
`ee3be8de192b97cb1d73d1e95d6b82bb1f6b658c0f97c4ef757fc331996ed3d3`.

The local copy avoids a runtime dependency on a third-party CDN. Upgrade it
explicitly, update the hash, and check the Supabase Auth / PKCE flow afterwards.

## Rules reader

`marked.umd.js` is Marked 18.1.1, from
https://cdn.jsdelivr.net/npm/marked@18.1.1/lib/marked.umd.js
(license: `marked-LICENSE`). SHA256:
`b82b9334406d8bdd16b6236c08de1cb65b2a859873ca9503d9cc0b292ca3c12a`.

`purify.min.js` is DOMPurify 3.4.16, from
https://cdn.jsdelivr.net/npm/dompurify@3.4.16/dist/purify.min.js
(license: `dompurify-LICENSE`). SHA256:
`2c90a9b46d6463f26038a29b686e82bc91de01fdac9d5229e7cfe3b360134ea2`.

These pinned local copies render and sanitize `docs/rules.md` without a
runtime CDN request.
