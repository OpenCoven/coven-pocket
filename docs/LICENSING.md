# Licensing decision record

Status: **Accepted** (M0 gate) — engineering decision record, not legal advice.
Maintainer sign-off is required before any App Store submission.

## Facts

- Coven Pocket links the `claurst-core` / `claurst-api` (and later `claurst-query`,
  `claurst-tools`) crates from [OpenCoven/coven-code](https://github.com/OpenCoven/coven-code),
  which is a **GPL-3.0** derivative of [Claurst](https://github.com/Kuberwastaken/claurst)
  by Kuber Mehta.
- Linking GPL-3.0 code makes the combined app a derivative work. This repository is
  therefore licensed **GPL-3.0** (see `LICENSE.md`).
- OpenCoven does not hold the full copyright: upstream Claurst copyright belongs to
  Kuber Mehta and external contributors. OpenCoven cannot unilaterally relicense or
  grant additional permissions covering upstream code.

## The App Store problem

The FSF's position is that Apple's App Store terms (usage rules, DRM) impose
restrictions beyond what GPLv3 permits, conflicting with GPLv3 sections 6 and 10.
Precedent: VLC was removed from the App Store in 2011 after a copyright-holder
complaint; VLC later relicensed its mobile engine to LGPL to return.

## Decision

1. **Reuse the GPL crates.** Coven Pocket is and remains GPL-3.0, full source
   published. This maximizes alignment with the coven-code engine (session format,
   provider adapters, permission engine) and is the entire point of the project.
2. **Distribution channels, in order of preference:**
   - **Build from source / Xcode sideload** — always available, zero conflict.
   - **AltStore / EU alternative marketplaces** — viable GPL channels.
   - **TestFlight** — used for development betas. Accepted-risk interim channel;
     revisit before any public beta.
   - **App Store** — **blocked** until item 3 lands.
3. **Pursue a GPLv3 §7 additional permission** ("App Store exception") from all
   copyright holders: Kuber Mehta (upstream), OpenCoven, and external contributors
   of the linked crates. Track in a dedicated issue. If granted, App Store
   distribution unblocks.
4. **Fallback (not chosen):** a permissively-licensed core re-implementing the
   engine contracts (session schema, provider wire formats) without GPL code.
   Estimated as a multi-month effort; only revisit if item 3 definitively fails
   and App Store distribution becomes existential.

## Consequences

- `README.md` states the license and distribution posture plainly.
- No proprietary code may be linked into the app target.
- Dependencies added to `rust/` or the Xcode project must be GPL-3.0-compatible
  (MIT/Apache-2.0/BSD are fine).
- CI publishes buildable source for every tagged release.
