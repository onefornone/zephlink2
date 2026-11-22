# Linking over the internet (optional)

By default Zephlink links your phone and PC over the same Wi-Fi, and nothing
goes through the internet. If you also want them to link when the phone is on
mobile data or you are away from home, you can turn on the **internet link**.

## What it is, and what it can see

The internet link uses a tiny program called a **relay**. It runs on your own
free Cloudflare account, so you control it. No one else's server is involved.

- Everything is already **end-to-end encrypted** by your two devices before it
  reaches the relay. The relay has no keys, so it cannot read or change your
  files, messages or screen. A man-in-the-middle is also blocked, because each
  device checks the other's saved identity (the same check used on Wi-Fi).
- The relay **stores nothing**. It only passes bytes along while both devices
  are connected.
- It can see that two connections exist, **when** they connect, their **IP
  addresses**, and **how much** data moves. It cannot see what the data is.
- The meeting room on the relay has a long secret name that only your two
  devices can work out, so strangers cannot find or join it.
- Only devices you have **already paired** (once, on the same Wi-Fi) can use
  it. You cannot pair for the first time over the internet.

## Limits (honest)

- Slower than Wi-Fi: speed depends on both internet connections and the
  distance to the relay.
- Both devices need Zephlink running and the internet link switched on. After
  a link drops, the devices can take up to about 15 seconds to find each other
  again.
- Cloudflare's free plan allows about 100,000 requests per day. One pair of
  devices uses a small fraction of that. Very large transfers use more
  messages, but a normal day is far below the limit.
- Big pictures in screen mirroring use a lot of data. Use it over Wi-Fi when
  you can.

## Setup, step by step (about 10 minutes, once)

1. Make a free account at <https://dash.cloudflare.com/sign-up>.
2. In Cloudflare, open **Workers & Pages** once. If it asks you to pick a
   free "workers.dev" name, pick one (for example `yourname`).
3. Find your **Account ID**: on the Workers & Pages page it is shown on the
   right side. Copy it.
4. Make an **API token**: click your profile (top right) > **My Profile** >
   **API Tokens** > **Create Token** > use the template **Edit Cloudflare
   Workers** > **Continue to summary** > **Create Token**. Copy the token (it
   is shown only once).
5. In your GitHub repository open **Settings > Secrets and variables >
   Actions > New repository secret** and add two secrets:
   - `CLOUDFLARE_API_TOKEN` = the token from step 4
   - `CLOUDFLARE_ACCOUNT_ID` = the Account ID from step 3
6. Open the **Actions** tab, choose **Deploy relay** on the left, press
   **Run workflow**. Wait for the green tick.
7. Open that run and look in the log for a line like
   `https://zephlink-relay.yourname.workers.dev`. That is your relay address.
   Opening it in a browser should say "Zephlink relay is running."
8. On **both** devices: Settings > **Internet link** > type the address
   (`zephlink-relay.yourname.workers.dev` is enough) > turn it **on**.
9. Link the two devices once on the same Wi-Fi (this happens by itself when
   both are on and the app is open). That is when they swap the secret that
   names their meeting room. Then they can find each other from anywhere.

If you never set this up, nothing changes: Zephlink keeps working over Wi-Fi.
