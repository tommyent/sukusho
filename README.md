<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/readme-header-dark@2x.png">
    <img alt="Sukusho" src="docs/brand/readme-header-light@2x.png" width="640" height="160">
  </picture>
</h1>

Sukusho captures the screen on a Mac and hands someone a link from the project's own Worker, with the markup, the cut and their comments on that same capture. The Worker runs in your own Cloudflare account, so your uploads, comments and likes stay there, with no Sukusho service in between.

Sukusho started as a fork of [Screendrop](https://github.com/fayazara/Screendrop) by Fayaz Ahmed, and thanks go to that project for the foundation. It has since grown into a separate project: a heavily modified app with its own features, its own name and app identity, and its own Cloudflare Worker for share pages. The two apps install side by side and don't share updates.

> [!IMPORTANT]
> Sukusho is not affiliated with or supported by Screendrop or its author. Please report Sukusho problems here, not to the Screendrop project.

> [!NOTE]
> There are no releases yet. To use Sukusho, [build it from source](#building-from-source). It is under active development, so expect rough edges.

<a href="https://screendrop-worker.tommyent.workers.dev/cfcda18c"><img src="docs/screenshots/share-page.jpg" alt="An example Sukusho share page in a browser, with comments allowed: a screenshot of the Sukusho editor marking up a travel website, titled Sukusho editor, with its size, a view count, a like button, Copy Image and Download below it, and a comment box beside it" width="100%"></a>

This is a typical share page, as the person you send a link to sees it: the capture, a like button, Copy Image and Download, and a place to comment. Comments can be turned off for each share. The page carries the name and logo you choose in Sukusho's settings. [Open the demo share](https://screendrop-worker.tommyent.workers.dev/cfcda18c), which has comments turned off.

## Screenshots

The Library keeps your captures in one window, next to everything that came back from your share pages: uploads, shared files, comments and likes.

<a href="docs/screenshots/library.jpg"><img src="docs/screenshots/library.jpg" alt="Sukusho Library with nine captures of a travel website in a grid, including a 29-second recording and green cloud badges on the shared ones, the Cloud section with 7 uploads, Files, Comments and 11 likes, a green Travel tag in the sidebar, and the inspector for a lake photo" width="100%"></a>

Click a picture to see it full size.

<table>
  <tr>
    <td width="50%" valign="top">
      <a href="docs/screenshots/comments.jpg"><img src="docs/screenshots/thumbs/comments.jpg" alt="Sukusho Comments view listing seven viewer comments with thumbnails of the captures they're on, one of them open in the inspector" width="100%"></a>
      <br><b>Comments</b> from your share pages arrive in the Library, each with the upload it's on.
    </td>
    <td width="50%" valign="top">
      <a href="docs/screenshots/studio.jpg"><img src="docs/screenshots/thumbs/studio.jpg" alt="Sukusho Studio editing a 29-second recording of a travel website: the video zoomed in on a gradient background, the clip timeline with two zooms below, and the inspector with background, redaction and zoom settings" width="100%"></a>
      <br><b>Studio</b> edits a recording before you export or upload it.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <a href="docs/screenshots/editor.jpg"><img src="docs/screenshots/thumbs/editor.jpg" alt="Sukusho image editor: a travel website screenshot on a blue gradient background, marked up with a red box, an arrow, red text, a boxed label with a speech-bubble tail, two numbered circles and a blurred card, with the tool dock above it and the inspector beside it" width="100%"></a>
      <br>The <b>editor</b> marks up a screenshot, here with a boxed label and its tail, and sets it on a background.
    </td>
    <td width="50%" valign="top">
      <a href="docs/screenshots/scrolling-capture.png"><img src="docs/screenshots/thumbs/scrolling-capture.jpg" alt="A full-page Scrolling Capture of a travel website, 2,108 by 6,524 pixels, shown in four columns" width="100%"></a>
      <br><b>Scrolling Capture</b> turns a whole page into one tall image, shown here in four columns.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <a href="docs/screenshots/agent-prompt.jpg"><img src="docs/screenshots/thumbs/agent-prompt.jpg" alt="Above, the Sukusho Library with a recording called Slow Roads walkthrough selected, a green check beside its title for its current Agent Prompt and an outline circle on an older recording, and the inspector naming Safari and the window it was recorded in. Below, a strip of eight frames from the prompt, with a red ring on the pointer as it draws a red pen loop around a card of the travel website" width="100%"></a>
      <br><b>Export Agent Prompt</b> turns a recording into a walkthrough for a coding agent. The green check marks the newest prompt; below it, one of the prompt's frame strips, with the pointer ringed and the pen stroke drawn in.
    </td>
    <td width="50%" valign="top">
      <a href="docs/screenshots/share-options.jpg"><img src="docs/screenshots/thumbs/share-options.jpg" alt="Sukusho Share Options over the image editor: the title Home page, a link that expires in 7 days, a password, Encrypt link turned on, and comments and likes allowed, with Cancel and Upload buttons" width="100%"></a>
      <br><b>Share Options</b> set a title, an expiry and a password for the link, and can encrypt it so the Worker stores only a file it can't read.
    </td>
  </tr>
</table>

## Features

### Sharing

Sharing is optional and self-hosted. Uploads go to a Cloudflare Worker you deploy, which keeps files in R2 and their details in D1. Sukusho only needs the Worker's URL and an upload token ([set up the Worker](#setting-up-the-worker)).

- **Share pages:** screenshots get a clean viewer with Copy Image and Download. Recordings get a video player with captions, a searchable transcript, chapters and previews as you scrub. Pages count views and show a preview card when the link is pasted into a chat app.
- **Upload from anywhere:** after a capture, from its preview card, from the Library, or from Studio, which uploads the finished cut. The link is copied when the upload finishes.
- **Share Options:** a title, a link expiry, an optional password, **Encrypt link**, whether comments and likes are allowed, and whether people can comment without signing in. Expiry, password and anonymous comments can be changed after upload, in the inspector on the Library's Uploads page.
- **Encrypted links:** with **Encrypt link** on, an image or a file of up to 32 MB is sealed on your Mac with CryptoKit before it's uploaded. The key goes only in the part of the link after `#`, which browsers don't send, so the Worker stores a file it can't read, and the recipient's browser decrypts it. The key is kept in this Mac's Keychain, so the full link can be copied again only from this Mac. Recordings aren't encrypted, because their share page needs the video for its poster, previews and seeking.
- **File requests:** on the Library's **Received** page, **Request Files…** makes a link someone can use to send you files, with an optional message and password, an expiry of 1, 7 or 30 days, and limits on how many files and how large. The link is shown once and copied. Senders pass a bot check; what they send is private to you and isn't scanned for malware. While a request is open and Sukusho is running, it checks every five minutes and notifies you of new files. Received files download to Downloads or a folder you choose in **Settings → Cloud**, automatically if you turn that on, and are marked as downloaded from the internet so macOS checks them when they're opened.
- **Comments and likes** come back to the Library, newest first, each with the upload it belongs to. The sidebar counts the new ones.
- **Files:** the Library's Files page shares files of any kind. Drop them on the page or click **Add Files…**, choose the same Share Options, and the links are copied.
- **Settings → Cloud** sets the default link expiry, the share page's name, logo and favicon, and a storage threshold. A bar at the foot of the Library's sidebar shows how much the Worker stores against it; it turns amber at 80% and red at the threshold, and never blocks an upload.
- If you add redactions to a recording that's already shared, Studio says the link still shows the old version and offers to replace the shared video, keeping the same link.

> [!NOTE]
> Encrypted links and file requests need a newer Worker than the one published now. Until your Worker is updated, Sukusho says so: Request Files asks you to update it, and an encrypted upload is removed instead of being shared.

### Library

One window for screenshots, recordings and recording projects, with **Uploads**, **Files**, **Received**, **Comments** and **Likes** under Cloud.

- Cards with an adjustable size, search (**Command + F**), and filters for screenshots or recordings. Tags have their own colours and icons.
- **Search inside captures:** search matches names, titles, tags, the app and window a capture was taken from, and the words in it. The Library reads the text in screenshots, and in recordings three frames plus their captions, on your Mac. Type `app:` and a name, such as `app:safari` or `app:"visual studio"`, to keep only captures taken in that app.
- An inspector with dimensions, dates, duration, disk use, the app and window a capture came from, the text read in it (with **Copy Text**), and tags (**Option + Command + I** shows or hides it). It suggests tags, starting with the app's name; a suggestion is added only when you click it, and one you dismiss stays gone for that capture.
- **Apple Intelligence**, where it's available, names captures you haven't named and suggests more tags, from the text read in them, on your Mac. **Settings → General → Library** turns text reading and this off, and titles older captures when you click **Start**.
- Right-click a capture for **Quick Look**, **Edit**, **Rename**, **Revert to Original…** (on an edited capture), **Copy**, **Export…**, the system **Share…** sheet, **Reveal in Finder** and **Move to Trash**. Recordings add **Export as GIF…** and **Export Agent Prompt**. The same menu holds the cloud actions: **Share to Cloud…** before upload; **Copy Cloud Link**, **Open Shared Capture** and **Delete from Cloud…** after.
- Each card has a cloud badge: click it to share the capture, or to copy its link once shared. Shared captures show a green cloud with a tick.
- Right-click between the cards to change the sort order or **Refresh** (**Command + R**).
- **Space** opens Quick Look and **Return** renames. Select several captures to copy, export, share, reveal or trash them together.

Opening Sukusho shows the Library; when it starts at login, it stays in the menu bar.

### Screen recording and Studio

- Record a display, a window or an area, with a camera, a microphone and system audio as separate sources, a 1, 3 or 5 second start timer, and a teleprompter that follows your narration on-device. **Clean desktop**, on by default, keeps desktop icons, the Dock and notification banners out of display and area recordings without changing your real desktop. **Bug report**, on the same bar, records a take for a coding agent: it keeps the menu bar and notification banners in, and **Stop** writes its Agent Prompt straight away instead of opening Studio.
- A floating bar shows the time and a microphone level meter, and pauses, starts over, stops or discards the take.
- **Draw while recording:** the pen on the bar turns drags into a red marker on screen instead of clicks. Strokes fade a couple of seconds after the last one, **Escape** puts the pen down and **Command + Z** undoes the last stroke. The pen itself stays out of the recording; Studio replays the strokes under **Drawings**, where you can hide them or delete one, and they're drawn into exports, GIFs and shares.
- Every recording is a non-destructive project. In Studio, split, trim and delete clips, change their speed, add automatic or manual zooms, and show a reconstructed cursor, click highlights and keystroke captions. Move and resize the camera, crop the video, and set a background, padding, corners, shadow and an aspect ratio for social formats. **Styles** saves a look to reuse, with import and export.
- **Audio:** **Isolate voice** cleans the microphone track with Apple's voice isolation. Add background music from your own file or from the [Free To Use](https://freetouse.com/music) library, looped to fit, starting where you choose, lowered while you speak, and faded out at the end.
- **Redactions:** blur or pixelate a region for part of the recording. They apply to every preview, export and share, and the original footage stays untouched.
- **Words:** transcribe your narration on-device, edit the captions, or cut the video by deleting words from its transcript. Chapters can be suggested from pauses and are named from what you said; the share page lists them so viewers can jump.
- **Output:** export the finished video as MOV, MP4 or GIF, export its audio, or click **Upload** to send it to your Worker and copy the link. Movie exports use HEVC unless you choose H.264; uploads and shares are always H.264, so they play in every browser.
- **Export Agent Prompt**, in Studio or the Library's right-click menu, or by itself after a **Bug report** take, turns a recording into a walkthrough for a coding agent. `prompt.md` names the app that was in front when it started and the screen's pixel scale, and lists each click, pressed shortcut, pointer rest, scroll and pen stroke, with what was said, a still of the whole screen at each moment and a strip of frames around it. Stills and strips come from the recording itself, with the pointer ringed and the pen strokes drawn in, so click positions match them and the export takes seconds: cuts and speed changes apply, Studio's zoom, crop, background, camera and redactions don't.
  - It's saved in `~/Agent Prompts`, one folder per recording, named after the recording's package and replaced when you export again. The folder's path is copied, and `~/Agent Prompts/latest.json` names the newest export, so a terminal action can read it.
  - A progress ring shows on Studio's button and on the Library card while it works, and the Glass chime plays when it's done if **Play sounds** is on.
  - On the Library card, a circle beside the title shows the prompt's state: green for the one `latest.json` names (click to show it in Finder), an outline for an older one (click to make it the newest), and amber when the recording was edited since (click to export it again).
  - Moving a recording to the Trash moves its prompt too.
- Studio has no Save button: a project saves after a two-second pause, when you switch away, close or quit, and with **File → Save** (**Command + S**). **File → Revert To** goes back to the original recording, to how the window opened, or to one of the last five sessions. Double-click the title to rename the recording.

### Image editor

Editing is non-destructive. The untouched image and an editable copy of your markup are kept side by side, so annotations can be changed later, and exports render at the image's full resolution.

- **Saves by itself** after a two-second pause, when you switch away, close or quit, and with **File → Save** (**Command + S**). The title bar shows the capture's name with **Edited**, **Saving…** or **Saved**; double-click it to rename. **File → Revert To** goes back to the capture as taken, to how the window opened, or to one of the last five sessions.
- **Tool dock** floating over the canvas: Select, rectangle, circle, Spotlight, arrow, straight line, freehand, Highlighter, text, numbered circle, magnifier, pixelate and blur, then **Crop**, **Pick Color**, **Measure** and a colour and size pill. Most tools have a single-key shortcut (R, O, L, A, N, T, M, P, B, and C for Crop).
- **Place a shape, then adjust it:** shapes, arrows, lines, magnifiers and redactions return to Select with the new annotation selected. Freehand, Highlighter and numbered circles stay armed for the next stroke or number. The Highlighter draws a straight horizontal or vertical line in see-through yellow, with its own remembered style.
- **Copy and paste:** **Command + C** and **Command + V** copy and paste the selected annotations. Paste an image from the clipboard to add it as a picture you can move and resize; dragging it past the edge grows the canvas.
- **Text labels** can sit in a box, with the text centred in it. Drag the round handle under a selected boxed label to pull out a speech-bubble tail; drop it back on the box to remove it.
- **Pick Color** copies a pixel's hex colour (or press **Tab** over the image). **Measure** shows the width and height under the pointer; hold **1** for height or **2** for width with any tool.
- **Crop** freeform or to a fixed ratio, or **Command-click** the image to crop to the box under the pointer. Annotations follow the crop.
- Shapes snap to each other and to the image's edges and centre, with alignment guides. The colour popover includes an opacity slider.
- **Find sensitive text…**, with pixelate or blur chosen, finds sensitive text and covers it.
- **Inspector:** **Styles** saves and reapplies a whole look, sets a default for new screenshots, and imports or exports `.screendroppreset` files. **Background** offers colours, gradients, wallpapers, your own images and [Unsplash](https://unsplash.com/oauth/applications) search with your own Access Key. Add padding, corner radius, shadow, a border, a watermark, a camera angle and progressive blur.

### Capture

Capture a display, a window, an area, a scrolling region, or just the text in an area. Sukusho runs from its menu bar item and global shortcuts:

| Default shortcut | Action |
| --- | --- |
| `Command + Shift + 1` | Capture full screen |
| `Command + Shift + 2` | Capture a window |
| `Command + Shift + 3` | Capture an area |
| `Command + Shift + 4` | Scrolling Capture |
| `Command + Shift + 5` | Capture Text to the clipboard |
| `Command + Shift + 6` | Screen recording |

`Command + Shift + 3`, `4` and `5` are also macOS's own screenshot shortcuts, so turn those off in macOS's keyboard shortcut settings (under Screenshots) for Sukusho to get them. Change any shortcut in **Settings → General**. If a shortcut can't be registered, Settings says why and keeps the previous one.

- **Screenshot options** in **Settings → Screenshots**: a 3, 5 or 10 second timer, window shadows, trimming the empty menu bar strip from full-screen captures on notched Macs, PNG or JPEG, and an option to also copy as TIFF for apps that can't paste PNG.
- **After each capture**, choose any of: show the preview, copy, save, upload and copy the link, and open the editor or pin the screenshot above other windows. Recordings have their own set, and open in Studio by default.
- **Floating preview cards** let you copy, drag, save, compress, pin, view, edit, upload or delete a capture. Rearrange their actions, and set where they appear and when they close, in **Settings → Overlay**.
- **Capture Text** drags out an area, reads its text on-device, and puts the text on the clipboard. No image is saved.
- **Open With → Sukusho** in Finder imports a copy of an image and opens the copy in the editor. The original file is never changed.

### Scrolling Capture

Draw a box over a scrolling view, then scroll through it yourself or click the auto-scroll button on the capture bar. Sukusho lines up each new frame with the last one and adds only the rows that scrolled into view, giving one tall image up to 16,384 pixels high.

- **Auto-scroll** moves the view a step at a time, paced by what has been captured, and finishes by itself at the end of the page. Scrolling yourself or moving the pointer off the bar hands control back to you. Auto-scroll needs the Accessibility permission; the bar offers to open it.
- **Every frame is checked before it's added.** Apple's Vision framework proposes where the new frame fits, and Sukusho adds it only once an exact pixel match confirms it. A frame that doesn't fit is skipped, not joined in the wrong place.
- **The capture bar** stays quiet through brief misses. If frames keep failing to fit, it says **Scroll back a little** when the view has moved past where it can line up, or **Something on the page keeps changing** for a video, an animation or a hover.
- Click **Done**, or press the Scrolling Capture shortcut again, to keep everything captured so far. At the height limit the capture stops and waits for **Done**.

Draw the box around the part that scrolls: a sidebar or button that stays put inside the box is repeated down the image.

### Automation

Shortcuts, Siri and Spotlight can take a full-screen, window or area screenshot, capture text, and start, stop or toggle a screen recording.

## Privacy and permissions

- Captures, projects, edits and transcripts stay on your Mac. Transcription, text recognition and Apple Intelligence run on-device. The text read from captures, the app and window they came from, and the model's titles stay on this Mac and are never uploaded.
- Agent Prompts hold stills and frames of your screen, so `~/Agent Prompts` is a folder only your user account can open. Nothing in it is uploaded.
- The upload token, your Unsplash Access Key and the keys of encrypted links are kept in the Keychain. Captures are uploaded only when you, or an after-capture action you turned on, ask for it.
- There is no Sukusho account, no central Sukusho server and no automatic app updates. Sukusho goes online for your Worker, a check on GitHub for a newer Worker version in **Settings → Cloud**, Unsplash search and wallpaper downloads, Free To Use music search and downloads, and the setup video in **Settings → Cloud**, which starts loading from the upstream project's server whenever the pane shows its setup steps. Apple's on-device speech models may need a one-time download for transcription or the teleprompter.

macOS asks for **Screen & System Audio Recording** for captures and recordings, and, when you first use them, **Camera**, **Microphone**, **Input Monitoring** (for keystroke captions), **Accessibility** (for auto-scroll) and **Notifications** (for finished exports and received files). Sukusho's own windows are left out of captures unless you turn on **Settings → General → Include Sukusho windows in captures**.

## Building from source

Requirements:

- macOS 27.0 or newer.
- Xcode 27 beta (installed as `Xcode-beta.app`), with its Metal Toolchain for Studio's motion-blur shader:

  ```bash
  xcodebuild -downloadComponent MetalToolchain
  ```

- Your Apple Developer team ID, to sign the app.

Build Sukusho with your team ID in place of `YOUR_TEAM_ID`:

```bash
xcodebuild build -project Screendrop.xcodeproj -scheme Screendrop \
  -configuration Release -destination "platform=macOS" \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates
```

The `Screendrop` scheme builds `Sukusho.app` (`com.tommyent.Sukusho`). The `Screendrop Dev` scheme with the `Debug Dev` configuration builds `Sukusho Dev.app` (`com.tommyent.Sukusho.dev`), which keeps its own data folder and keychain item, apart from Sukusho's. The Xcode target, schemes and Swift module keep the name Screendrop.

Run the test suite:

```bash
xcodebuild test -project Screendrop.xcodeproj -scheme "Screendrop Dev" \
  -configuration "Debug Dev" -destination "platform=macOS" \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID -allowProvisioningUpdates
```

The tests use Swift Testing, need no app host, and never touch your captures or settings; see [ScreendropTests/README.md](ScreendropTests/README.md). DockProgress is the only package dependency, and Xcode resolves it. [Editor performance](docs/editor-performance.md) and [export performance](docs/export-performance.md) describe the standalone checks and benchmarks.

If Screendrop was installed before, Sukusho brings over its captures, recordings, settings and Cloud token once, the first time it opens. Screendrop's own copy is left unchanged.

## Setting up the Worker

Sukusho's share pages, comments, likes and passwords come from this fork's Worker, [tommyent/screendrop-worker](https://github.com/tommyent/screendrop-worker), built on Cloudflare Workers with R2 and D1.

1. In Sukusho, open **Settings → Cloud** and copy the generated upload token.
2. Deploy the Worker from its repository:

   ```bash
   git clone https://github.com/tommyent/screendrop-worker.git
   cd screendrop-worker
   pnpm install
   npx wrangler secret put UPLOAD_TOKEN   # paste the token from step 1
   pnpm run deploy
   ```

   The deploy provisions the R2 bucket and D1 database; the database schema sets itself up on first use.
3. Paste the Worker's URL into **Settings → Cloud** and click **Verify Connection**.

Optional `AUTHOR_NAME` and `AUTHOR_AVATAR` secrets set the name and picture shown beside each share. The Worker's README covers updating an existing deployment and its API.

Encrypted links and file requests need a Worker update that hasn't been published yet.

## Credits and licence

Sukusho is based on [Screendrop](https://github.com/fayazara/Screendrop) by Fayaz Ahmed, which its author dedicated to the public domain under [CC0 1.0 Universal](LICENSE-CC0). Code that came from Screendrop remains available under CC0. This fork's own changes are licensed under the [MIT License](LICENSE). See [NOTICE](NOTICE) for the details and for the licences of third-party packages.
