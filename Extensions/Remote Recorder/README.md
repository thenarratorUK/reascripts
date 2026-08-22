# Remote Recorder guide

Remote Recorder records the participant's selected microphone input in REAPER,
keeps a local safety copy, and transfers the completed recording directly to
the engineer. Input monitoring stays **off**.

## Install with ReaPack

1. Open REAPER. If **Extensions > ReaPack** is missing, install ReaPack from
   [reapack.com](https://reapack.com/) and restart REAPER.
2. Choose **Extensions > ReaPack > Import repositories…** and paste:
   `https://raw.githubusercontent.com/thenarratorUK/reascripts/main/index.xml`
3. Choose **Extensions > ReaPack > Browse packages**.
4. Install only the package for your role:
   - **Remote Recorder - Participant**
   - **Remote Recorder - Engineer**
5. Apply the transaction and restart REAPER.
6. Open **Extensions > Remote Recorder**.

## Participant guide

The Participant package supports Apple Silicon Mac, Intel Mac, and 64-bit
Windows 10 or 11.

### Set up once

1. Open the REAPER project.
2. Select and arm one microphone track.
3. Choose the correct microphone input.
4. Keep REAPER input monitoring **off**.
5. Open **Extensions > Remote Recorder**.
6. Click **Choose Microphone Input** and follow the prompt.
7. Click **Set Up Microphone Track**, then save the project.

### Record a session

1. Enter the six-character code from the engineer and click **Connect**.
2. When the window says you are connected, click **Start Recording**.
3. At the end, click **End Recording**.
4. Keep REAPER open and online until the window says **Session complete** and
   **Engineer recording: VERIFIED**.

If the internet drops, leave REAPER open. The local safety recording is retained
and transfer resumes automatically when the connection returns.

On Mac, use the REAPER build that matches your processor. If macOS blocks the
extension, open **System Settings > Privacy & Security**, choose **Open Anyway**,
then reopen REAPER. On Windows, use 64-bit REAPER.

## Engineer guide

The Engineer package currently supports Apple Silicon Mac.

### One-time access setup

If the window shows **Set Engineer Password**, ask the Remote Recorder owner for
your one-time Engineer password. Click the button and paste it once. It is saved
privately on that Mac.

Installing the Engineer package alone does not grant access.

### Create and receive a session

1. Open and save the correct REAPER project. Its configured media folder is
   where the completed WAV will be placed.
2. Open **Extensions > Remote Recorder**.
3. Click **Create Session Code** and send the six-character code to the
   participant.
4. Wait for the participant to connect and record.
5. At the end, ask them to click **End Recording** and keep REAPER open.
6. Keep your REAPER open until Remote Recorder reports
   **Engineer recording: VERIFIED**.

The participant's audio is sent directly to the Engineer Mac. There is no
central download folder to clear later.

### Owner: add or revoke an engineer

Only the owner's Mac shows **Manage Engineer Access**.

- To add someone, click **Manage Engineer Access**, choose **Yes**, and enter
  their name. Their one-time password is copied to the clipboard; send it to
  them privately.
- To revoke someone, click **Manage Engineer Access**, choose **No**, and enter
  their name. They can no longer create session codes, and any unused codes they
  created are cancelled. A recording that has already paired can still finish.

## Important

- Remote Recorder captures the participant's selected microphone input, not
  REAPER playback.
- Keep input monitoring off when monitoring through an audio interface.
- Both sides should leave REAPER open until the Engineer copy is verified.
- **Open Guide** in the Remote Recorder window always opens the current version
  of this page.
