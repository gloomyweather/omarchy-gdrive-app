# Create your Google key

omarchy-gdrive talks to Google Drive with *your own* Google app. rclone's shared
app is heavily rate limited and is being retired in 2026. Creating your own takes
about 10 minutes, is free and is done once.

Open <https://console.cloud.google.com/> and sign in with the Google account
whose Drive you want to use.

## 1. Project and Drive API

1. **Create a project**: top bar → project picker → **New project**.
   Name it `omarchy-gdrive` → **Create**. Make sure it is selected in the top bar.
2. **Enable the Drive API**: search for **Google Drive API** → **Enable**.

## 2. Consent screen

Go to **Google Auth Platform** (search for it) → **Get started**.

1. App name: `omarchy-gdrive`. User support email: your address. **Next**.
2. Audience: **External**. **Next**.
3. Contact email: your address. **Next**.
4. Agree to the Google API Services User Data Policy → **Continue** → **Create**.

Then:

- **Data Access → Add or remove scopes**. Paste into *Manually add scopes*:
  ```
  https://www.googleapis.com/auth/drive,https://www.googleapis.com/auth/docs,https://www.googleapis.com/auth/drive.metadata.readonly
  ```
  **Add to table** → **Update** → **Save**.
- **Audience → Test users → Add users**: your Gmail address → **Save**.

## 3. Client ID

**Clients → Create client**: Application type **Desktop app**, any name → **Create**.

Copy the **Client ID** (`...apps.googleusercontent.com`) and the **Client secret**
(`GOCSPX-...`). The secret is shown only once. If you lose it, create a new client.

Now run `omarchy-gdrive setup` and paste both. Google warns that it *hasn't
verified this app*: click **Continue**, it is your own app.

## 4. Stop the weekly sign-out (recommended)

While the app is in **Testing**, Google signs you out after 7 days.
To avoid that, publish the app. Google then wants a home page and a privacy
policy on a domain you own. No website? Use GitHub Pages:

1. Fork this repository on GitHub.
2. In your fork: **Settings → Pages**, source **Deploy from a branch**,
   branch `main`, folder `/docs` → **Save**.
   After a minute the pages are at `https://<your-login>.github.io/omarchy-gdrive-app/`.
3. In Google Cloud: **Google Auth Platform → Branding**:
   - Application home page: `https://<your-login>.github.io/omarchy-gdrive-app/`
   - Application privacy policy link: `https://<your-login>.github.io/omarchy-gdrive-app/privacy.html`
   - Authorized domains: `<your-login>.github.io`
   - **Save**.
4. **Audience → Publish app → Confirm**. Status: *In production*.
   You do not need Google's verification for personal use (up to 100 users).
5. Sign in once more, because sign-ins from the Testing period still expire:
   `omarchy-gdrive reconnect`.

To revoke the app's access at any time: <https://myaccount.google.com/permissions>.
