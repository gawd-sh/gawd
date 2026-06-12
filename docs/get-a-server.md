# Get a Server

**The complete guide for someone who has never rented a server before.**

You clicked "Summon your Gawd" on gawd.sh, hit a wall when it mentioned you need a server, and you're here. That's exactly where this guide starts.

This takes about 15–30 minutes. By the end you will have a running Linux server in the cloud, Docker installed on it, and a terminal prompt waiting for the Gawd install command.

---

## What this costs

> **The honest monthly math (as of June 2026):**
>
> | Item | Monthly cost |
> |---|---|
> | DigitalOcean server (Comfortable tier) | ~$24/mo |
> | Hetzner server (Comfortable tier, EU regions) | ~€4–€4.50/mo (~$4.50–$5 USD) |
> | Hetzner server (US regions, CPX line) | ~$10–12/mo |
> | LLM API usage (DeepSeek, typical daily use) | $1–5/mo |
> | **Total, Hetzner path** | **roughly $5–10/mo** |
> | **Total, DigitalOcean path** | **roughly $25–30/mo** |
>
> DigitalOcean is friendlier to set up. Hetzner is significantly cheaper — we're talking $5/month versus $24/month for the same hardware. Both work fine for Gawd.
>
> There is no subscription to Gawd, no account with us, and Gawd does not phone home. Your only recurring cost is the server and whatever LLM API usage your conversations generate. DeepSeek (the recommended provider to start with) is pay-as-you-go and among the cheapest — light daily use typically lands at a few dollars a month.

---

## Before you start

You need three things:

1. **A server** — you're about to get one
2. **A Telegram bot token** — after the server is ready, go to [@BotFather](https://t.me/BotFather) on Telegram, send `/newbot`, follow the prompts, and copy the token it gives you
3. **An LLM API key** — the quickest start is [DeepSeek](https://platform.deepseek.com/): sign up free, add a few dollars of credit, create an API key

The Telegram bot and API key take about 5 minutes each. You can do them while the server is provisioning.

---

## Two paths: choose one

**Path A — DigitalOcean** is the better choice if you want the friendliest interface and don't mind paying more. Their control panel is designed for beginners. Support is excellent.

**Path B — Hetzner** is the better choice if you want to pay as little as possible. The UI is clean and capable — it just assumes slightly more comfort with the concept of a server. European company, German data centers, also US locations.

Pick one and follow that section completely. You do not need to read both.

---

## Path A — DigitalOcean

### What you are getting

A "Basic" Droplet: 2 vCPU, 4 GB RAM, 80 GB SSD. This is the Comfortable tier — the recommended floor for daily use. Cost: **$24/month** as of June 2026.

### Step 1: Create an account

Go to [digitalocean.com](https://www.digitalocean.com) and sign up. You will need a credit card to verify. New accounts typically receive free credits — check the welcome email.

### Step 2: Create a Droplet

1. Once logged in, click **Create** in the top navigation bar, then select **Droplets**.
2. Under "Choose Region," pick a location close to you — this affects response time but not much else.
3. Under "Choose an image," select **Ubuntu**. From the version dropdown, choose **24.04 (LTS) x64**.
4. Under "Choose Size," you will see a set of plan tiers. Click **Basic** (shared CPU). Scroll right or click through the sizes to find **2 vCPU / 4 GB RAM / 80 GB SSD**. This is currently labeled the Basic 2 vCPU plan and costs $24/month.
5. Under "Choose Authentication Method," you will see two options:

   **SSH Key (recommended if you have one):** An SSH key lets you log in securely without a password — you prove identity with a cryptographic key file on your computer instead of a password you type. If you already have SSH keys set up on your computer, click "New SSH Key," paste your public key (the contents of `~/.ssh/id_rsa.pub` or `~/.ssh/id_ed25519.pub`), and save it. If you do not have SSH keys and do not know what they are, choose the Password option for now — it is fine for a personal server. You can add SSH keys later.

   **Password:** DigitalOcean will ask you to set a root password. Pick a strong one (16+ characters, a mix of types). Store it somewhere safe. This is the password you will use to log in.

6. Leave everything else at defaults.
7. Scroll to the bottom and click **Create Droplet**.

Provisioning takes about 30–60 seconds. You will see the Droplet appear in your dashboard with a green dot and an IP address like `142.93.x.x`.

### Step 3: Log in to your server

You have two ways to get a terminal on your server. **The browser console is the easier path if you are new to this.**

#### Option A: Browser console (no setup required)

1. In your DigitalOcean dashboard, click the name of the Droplet you just created.
2. In the left sidebar or the top of the Droplet detail page, click **Console**.
3. A terminal window opens in your browser. You are now connected to your server.
4. Log in as `root` using the password you set. (If you chose SSH key auth and the console asks for credentials, try `root` with no password — the console bypasses SSH entirely.)

This is the beginner path. It works from any browser, on any operating system, with nothing to install.

#### Option B: SSH from your local terminal (Mac/Windows/Linux)

Open your Terminal app (macOS: search "Terminal" in Spotlight; Windows: use PowerShell or install Windows Terminal). Then:

```
ssh root@YOUR_IP_ADDRESS
```

Replace `YOUR_IP_ADDRESS` with the IP shown in your Droplet dashboard. If you chose password auth, type the password when prompted. If you chose SSH key, no password is needed.

### Step 4: Update the system

Once you have a terminal prompt on the server, run:

```bash
apt-get update && apt-get upgrade -y
```

This updates the system's package list and applies any pending security patches. It takes 1–3 minutes. Wait for the prompt to return before continuing.

### Step 5: Install Docker

Docker is the container system Gawd runs inside. Install it with Docker's official script:

```bash
curl -fsSL https://get.docker.com | sh
```

This downloads and runs the official Docker installer. It takes 1–2 minutes.

After it finishes, run:

```bash
docker --version
```

You should see something like `Docker version 27.x.x`. That confirms Docker is installed.

**One more step — allow your user to run Docker without `sudo`:**

```bash
usermod -aG docker $USER
```

On a root session (which is what you have right now), this is not strictly necessary — you are already root. But if you ever create a non-root user on this server, this is the command that grants them Docker access. Note it.

**Verify Docker works:**

```bash
docker run hello-world
```

Docker will download a tiny test image and print a "Hello from Docker!" message. That means everything is working.

---

## Path B — Hetzner

### What you are getting

In a **European region**: a CX23 server — 2 vCPU (shared), 4 GB RAM, 40 GB NVMe SSD, **about €3.99–€4.49/month** as of June 2026. In a **US region** (Ashburn or Hillsboro): the CX line isn't offered there — you'll use the equivalent 4 GB plan from the **CPX line** instead, roughly **$10–12/month** with a smaller traffic allowance. Either way: no setup fee, billed by the hour.

### Step 1: Create an account

Go to [hetzner.com/cloud](https://www.hetzner.com/cloud/) and click "Get started." Sign up with your email. Hetzner may ask for identity verification — upload a photo ID or credit card. This usually clears in a few minutes.

### Step 2: Create a project and a server

1. Once logged in, you land in the Hetzner Cloud Console. Click **+ New project**, name it anything ("gawd" works), and open it.
2. Inside the project, click the **+ Add Server** button.
3. Under "Location," choose a region. **For the best price, pick a European location**: Falkenstein (Germany), Nuremberg (Germany), or Helsinki (Finland). If you're in the US, an EU server is still the right default — typing over ssh to Europe has a slight delay, sometimes noticeable right after you connect (that's the ocean, and it affects the terminal only — this setup today, and any ssh session later; Gawd itself lives on Telegram, where you'll never feel it). If you'd rather have a US server anyway, choose Ashburn or Hillsboro — note the cheap CX plans aren't offered there, so you'll pick from the CPX line at roughly $10–12/month.
4. Under "Image," click **Ubuntu** and select **24.04**.
5. Under "Type," make sure you are on the **Shared vCPU** tab. In an EU region, find the **CX23** plan: 2 vCPU / 4 GB RAM / 40 GB NVMe — that's the one you want. In a US region you won't see CX plans; pick the **CPX plan with 4 GB RAM** instead.
6. Under "SSH keys," you will see an option to add an SSH key. This works the same as with DigitalOcean — if you have one, add it. If not, Hetzner will email you a root password after provisioning. Either path works.
7. Scroll down and click **Create & Buy Now**.

Your server will be ready in about 30 seconds. Hetzner shows a progress indicator. When it turns green, you have a running server. Note the IP address shown in the server list.

### Step 3: Log in to your server

Again, two paths — the browser console is the easier one for beginners.

#### Option A: Browser console (no setup required)

1. Click the name of your new server in the Hetzner Cloud Console.
2. At the top right of the server detail page, click the **>_** console icon (it looks like a terminal symbol).
3. A browser-based VNC console opens. This gives you direct keyboard and screen access to the server.
4. Log in as `root` using the password Hetzner emailed you (subject line will mention your server or Hetzner Cloud), or your SSH key passphrase if applicable.

**Note:** Hetzner's browser console uses VNC — it can feel slightly less snappy than DigitalOcean's console. If text input feels sluggish, allow popups from `console.hetzner.cloud` in your browser settings and try refreshing.

#### Option B: SSH from your local terminal

Same as DigitalOcean:

```
ssh root@YOUR_IP_ADDRESS
```

Use the IP address shown in Hetzner's server list. If Hetzner emailed you a root password, use it here.

### Step 4: Update the system

```bash
apt-get update && apt-get upgrade -y
```

Wait for it to finish.

### Step 5: Install Docker

```bash
curl -fsSL https://get.docker.com | sh
```

Then verify:

```bash
docker --version
```

Should show `Docker version 27.x.x` or similar.

Test it:

```bash
docker run hello-world
```

You should see the "Hello from Docker!" message.

---

## Your server is ready

At this point, regardless of which path you took:

- You have a running Linux server
- Docker is installed and working
- You have a terminal prompt on the server (browser console or SSH — either works)

Return to [gawd.sh](https://gawd.sh), find the Summon command, and paste it into the terminal you have open. The command looks like:

```bash
curl -fsSL https://gawd.sh/install | bash
```

Follow the prompts. The installer will walk you through adding your Telegram bot token and LLM API key, then start the daemon. The README has the full step-by-step from there.

---

## Troubleshooting

**I can't log in to my server at all.**

If you chose password authentication and cannot remember the password: use the **browser console** for your provider. DigitalOcean: find your Droplet, click Console. Hetzner: find your server, click the console icon. Both give you direct access that bypasses SSH and does not require your password to be correct beforehand — the console is a keyboard and screen feed directly to the machine.

**Hetzner emailed me a root password but it's not working.**

Paste it rather than typing. Root passwords from Hetzner sometimes contain characters that are tricky to type (symbols, mixed case). Copy the password from the email, paste it into the console. Paste in Hetzner's VNC console may require right-clicking and choosing "Paste from clipboard," or using the console's built-in paste tool.

**"permission denied" when running a Docker command.**

If you see `Got permission denied while trying to connect to the Docker daemon socket`, run:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

The first command adds your user to the docker group. The second applies the change immediately in your current session without needing to log out. If that does not work, log out and back in.

**If you are logged in as root** (which is the default on a fresh cloud server), you should not see this error — root has Docker access by default. If you see it as root, try `sudo docker run hello-world` as a test; if that works, the daemon is fine.

**"curl: command not found"**

Some minimal Ubuntu images are missing curl. Install it:

```bash
apt-get install -y curl
```

Then retry the Docker install command.

**The install script seems to hang / nothing is happening.**

The `apt-get upgrade` step can take several minutes on a fresh server with pending updates. If the cursor is blinking with no output for more than 5 minutes, the system may be waiting for you to confirm something. Press Enter or type `y` and Enter. If it is truly stuck, Ctrl+C to cancel and try again.

**I forgot to add my SSH key and want to use SSH instead of the browser console.**

No problem. You can add SSH keys to an existing server:

- **DigitalOcean**: Go to your account Settings → Security → SSH Keys to add a key. Then you can add it to a Droplet by using the Recovery Console to manually append it to `~/.ssh/authorized_keys`, or for a new server, simply destroy and recreate it (takes 2 minutes, everything you care about is in `~/.gawd` which you have not set up yet).
- **Hetzner**: In the server detail page, Hetzner offers a Rescue mode that lets you boot into a recovery environment and edit the server's authorized keys file.

For a personal Gawd server, the browser console works perfectly well and there is no urgency to set up SSH.

---

*Prices and UI details verified June 2026 against: [DigitalOcean Droplet Pricing](https://www.digitalocean.com/pricing/droplets) · [DigitalOcean Console docs](https://docs.digitalocean.com/products/droplets/how-to/connect-with-console/) · [Hetzner server creation docs](https://docs.hetzner.com/cloud/servers/getting-started/creating-a-server/) · [Docker Engine install docs](https://docs.docker.com/engine/install/ubuntu/). If something here has drifted from what you see, the provider's own docs win.*
