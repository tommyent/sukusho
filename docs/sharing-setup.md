# Setting up sharing

Sukusho's share pages, comments, likes and passwords come from this fork's Worker, [tommyent/sukusho-worker](https://github.com/tommyent/sukusho-worker), built on Cloudflare Workers with R2 and D1.

1. In Sukusho, open **Settings → Cloud** and copy the generated upload token.
2. Deploy the Worker from its repository:

   ```bash
   git clone https://github.com/tommyent/sukusho-worker.git
   cd sukusho-worker
   pnpm install
   npx wrangler secret put UPLOAD_TOKEN   # paste the token from step 1
   pnpm run deploy
   ```

   The deploy provisions the R2 bucket and D1 database; the database schema sets itself up on first use.
3. Paste the Worker's URL into **Settings → Cloud** and click **Verify Connection**.

Optional `AUTHOR_NAME` and `AUTHOR_AVATAR` secrets set the name and picture shown beside each share. The Worker's README covers updating an existing deployment and its API.

**Deploy to Cloudflare** in **Settings → Cloud** does the same from the browser: it clones the Worker, provisions R2 and D1, and asks for the `UPLOAD_TOKEN` secret. Galleries need Worker 2.0.0 and summaries and translated captions 2.1.0; Settings → Cloud says when your Worker is older than the published one.
