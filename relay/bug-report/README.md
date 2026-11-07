# Bug report relay

A Cloudflare Worker (free plan, no card) that turns Tala's **Report a problem**, and
the crash report the app offers, into a GitHub issue, so users don't need a GitHub
account and the app holds no token. Copied from XBTune's relay, with a `facts` field
for what the app checks about its setup. How it keeps the tracker clean is described at
the top of `worker.js`. Not part of the snap.

The app side is `lib/src/report.dart`. It posts to
`https://tala-bug-report.jimmy-tigert.workers.dev/report`; `TALA_REPORT_URL` overrides
it. Until the Worker is deployed, sends fail and the app keeps the reports in
`<config>/tala/pending/`, retrying on later starts (up to 5, for 30 days).

**The repo is public, so reports are public.** The app's dialog says so, and it masks
the server address, username, room tokens, IP addresses and home folder before sending.

## One-time setup

1. **GitHub token:** <https://github.com/settings/personal-access-tokens/new>
   - Repository access: **Only select repositories** → `kz6fittycent/tala`
   - Permissions → Repository → **Issues: Read and write** (nothing else)
   - Expiration: the longest offered. When it expires, reports fail and the app saves
     them to retry; make a new token and repeat the `secret put` step.
2. **Labels:**

   ```bash
   gh label create user-report --repo kz6fittycent/tala --color d93f0b --description "Filed from the app's Report a problem"
   gh label create keep --repo kz6fittycent/tala --color 0e8a16 --description "Don't auto-close this user report"
   ```

3. **Deploy**, using the same Cloudflare account as XBTune. The argument to `secret put`
   is literally `GITHUB_TOKEN`; paste the token only at the prompt.

   ```bash
   cd relay/bug-report
   npx wrangler@4 login
   npx wrangler@4 deploy
   npx wrangler@4 secret put GITHUB_TOKEN
   ```

## Checking it

```bash
curl -s -X POST https://tala-bug-report.jimmy-tigert.workers.dev/report \
  -H 'Content-Type: application/json' \
  -d '{"description":"Test report from setup - please close.","version":"test","platform":"curl"}'
```

That should answer with `{"issue":<number>,...}` and open a `user-report` issue. Logs:
`npx wrangler@4 tail`.

`node --test relay/bug-report/worker.test.mjs` tests the Worker with GitHub faked.

From the app: `tala --crash-test` throws an error after 3 seconds and offers a report at
once. `kill -SEGV` on a running Tala tests a native crash; the next start offers it.
