# Maxo

**Independent app volume and audio routing for macOS.**

Maxo is a native macOS sound mixer that lives in the menu bar. Adjust each app’s playback volume, mute it, or send its sound to a different output while other apps keep playing.

Listen to Spotify on a Bluetooth speaker, keep YouTube in Chrome on your MacBook speakers, and send Discord to connected headphones. Each app keeps its own volume, including when several apps share the same output.

## What you can do

- **Mix apps independently.** Change an app’s volume while its audio is playing.
- **Choose an output per app.** Select System Default or an available playback device.
- **Use several outputs together.** Route different apps to different connected devices.
- **Balance loudness automatically.** Measure sustained playback and adjust the apps’ sliders to a similar level.
- **See live audio levels.** Waveforms respond to playback, slider changes, mute, and silence.
- **Arrange your mixer.** Drag a row by its background or app icon. The entire row follows the pointer.
- **Hide apps you don’t need.** Right-click a row and choose Remove from Mixer. Restore it from Maxo’s menu.
- **Pick up where you left off.** App volumes, mute states, preferred outputs, row order, and hidden apps are saved locally.

The compact menu-bar panel and full mixer window share the same controls. Closing the window leaves the mixer running. Maxo appears in the menu bar and stays out of the Dock.

## Requirements

| Component | Requirement |
| --- | --- |
| Mac | macOS 14.2 or later |
| Build tools | Xcode 26 or later |
| Permission | System audio capture |
| Outputs | Playback devices recognized by macOS |

The panel uses Apple’s Liquid Glass on macOS 26 and later, with a native translucent material on earlier versions. It follows light and dark appearance, Reduce Motion, and Reduce Transparency.

## Get it running

### Build in Xcode

1. Clone this repository and open the project.

   ```sh
   git clone https://github.com/To-nevim/maxo-sound-mixer.git
   cd maxo-sound-mixer
   open Maxo.xcodeproj
   ```

2. Select the **Maxo** scheme and **My Mac** as the destination.
3. Press **⌘R** to build and launch.
4. Allow system audio capture when macOS asks.
5. Start playback in an app, then click the mixer icon in the menu bar.

The project uses Apple’s frameworks and builds locally with ad hoc signing. A paid Apple Developer account and additional packages are unnecessary for a local build.

### Build from Terminal

Select the full Xcode installation if your active developer tools point to Command Line Tools.

```sh
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
```

From the repository folder, build and launch Maxo.

```sh
xcodebuild \
  -project Maxo.xcodeproj \
  -scheme Maxo \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath .build \
  build

open .build/Build/Products/Release/Maxo.app
```

### Install for everyday use

Quit Maxo using its menu, then copy **Maxo.app** from the build’s Products folder into **Applications**. Replace the existing copy when updating. Open the installed app from Applications or Spotlight.

With the Terminal build above, the app is at `.build/Build/Products/Release/Maxo.app`. In Finder, press **⌘⇧G** to open that folder inside your checkout.

Keep Applications as the place you launch Maxo from. Build products are temporary and can be removed after installation. Your preferences are stored separately and survive replacing the app.

## First mix

1. Connect the speakers or headphones you want to use.
2. Start audio in Spotify and a video in Chrome.
3. Click Maxo’s mixer icon in the menu bar.
4. Choose an output in each app’s row.
5. Drag the sliders to set each app’s volume.

For example, a setup could look like this.

| App | Output | Volume |
| --- | --- | --- |
| Spotify | Bluetooth speaker | 70% |
| Google Chrome, including YouTube | MacBook speakers | 50% |
| Discord | Connected headphones | 100% |

These percentages are an example. Your source material and listening preferences determine the mix.

Choose **System Default** to follow the current macOS playback output. Choose a device by name to keep that preference for the app. If it disconnects, Maxo temporarily uses the system default and shows the fallback in the row. When the preferred device reconnects, Maxo restores the route.

Browser audio is grouped under the browser’s row. Tabs and websites, including YouTube in Chrome, share that browser’s volume and output.

## Auto Balance

Start sustained audio in at least two unmuted apps and click **Auto Balance**. Keep the apps playing for about six seconds.

Maxo measures the incoming audio, requires at least three seconds of audible material from an app, and adjusts the eligible apps to match the quietest source at its full level. Brief sounds, such as a screenshot click, are excluded from the calculation.

The resulting slider values are saved. Running it again measures the sources afresh, so a previous reduction does not compound. Click **Cancel** or change a mixer control to cancel a measurement.

Auto Balance estimates the digital playback signal. Device volume, speaker sensitivity, headphone fit, and room acoustics also affect the loudness you hear. Run it again when your source material changes.

## Read the waveform

The waveform shows recent playback after Maxo’s volume adjustment. Silence and mute settle to a flat line.

| Color | Level |
| --- | --- |
| Cyan | Quiet |
| Green | Normal |
| Yellow | Strong |
| Orange | High |
| Red | Within 1 dB of digital clipping |

The colors describe signal level. They do not measure physical sound pressure or listening safety.

## Keep the list tidy

Apps appear as they begin playback. After roughly 15 seconds without audio, a row drops out and returns when playback resumes.

Drag the background or icon to move an app up or down. Right-click a row for **Move Up**, **Move Down**, or **Remove from Mixer**. Removing a row hides the app and releases its Maxo audio route, allowing normal playback to resume.

Use **… → Restore Hidden Apps** to bring a hidden app back. The order and hidden-app choices apply to both mixer views and are remembered across launches.

## Permissions and privacy

Maxo needs macOS system audio capture permission to measure playback and apply per-app volume and routing. Audio is processed live in memory on your Mac.

Settings are stored locally in macOS preferences. The app has no audio recording or upload feature, account service, or analytics integration.

You can review audio access in **System Settings → Privacy & Security → Screen & System Audio Recording**. The exact label can vary by macOS version. After changing access, relaunch Maxo if macOS requests it, or choose **Fix → Retry** on an affected row.

## Troubleshooting

| What you see | What to try |
| --- | --- |
| No Dock icon | Open Maxo from its menu-bar mixer icon. Choose Open Mixer for the full window. |
| Spotlight cannot find Maxo | Copy the built app into Applications and launch it there. |
| An app is missing | Start audible playback in it. Check Restore Hidden Apps if you previously removed it. |
| A row disappears | Inactive rows leave after about 15 seconds. Resume playback to show the app again. |
| Mixing unavailable | Check audio permission and the selected device, then use Fix → Retry. |
| A preferred device is offline | The row shows the fallback. Reconnect the device or select another output. |
| Auto Balance is disabled | Start audio in at least two unmuted apps with a nonzero slider value. |
| Auto Balance asks you to try again | Keep both sources audible for several seconds and retry. |
| Audio behaves unexpectedly | Quit Maxo from its menu to release its taps, then relaunch and check the outputs. |
| You still see an older interface after an update | Quit the running copy, replace Maxo in Applications, and reopen the installed copy. |

## Playback scope and verification

This release focuses on playback volume and routing. Microphone mixing and transport controls are outside its current scope.

Verification during development covered simultaneous test-tone playback through built-in speakers and a Bluetooth speaker, independent gain and mute, live level readings, preference persistence, and mixer window behavior. Output fallback and restoration were also checked with simulated device changes.

A physical Bluetooth disconnect/reconnect cycle and two simultaneous Bluetooth outputs still need hardware listening checks. Device combinations and source apps should be checked on the Mac where you plan to use them.

To check your setup, play two distinguishable sources, assign different outputs, and move one slider at a time. Confirm that each comes from its selected device, close the full window and repeat from the menu bar, then disconnect and reconnect the preferred device.

## How it works

Maxo uses SwiftUI and AppKit for its interface and Apple’s public Core Audio process-tap APIs for audio capture. It groups audio processes by their owning app and uses private tap instances for local metering. When an app needs volume adjustment or routing, a private aggregate device forwards its captured audio to the selected output.

Managed taps suppress the source’s original hardware playback while Maxo reads them, preventing duplicate output. If a managed playback callback stalls or route setup fails, Maxo releases the route so normal playback can resume.

Auto Balance uses frequency weighting based on the K-weighting filters in ITU-R BS.1770, with a short measurement window and gating for quiet material.

| Location | Purpose |
| --- | --- |
| `Maxo/MaxoApp.swift` | App lifecycle, menu-bar icon, panel, and full window |
| `Maxo/MixerModel.swift` | Shared settings, persistence, row order, and Auto Balance state |
| `Maxo/Audio/` | Device discovery, process grouping, taps, routing, and sample processing |
| `Maxo/UI/` | Mixer controls, waveforms, and full-row dragging |
| `Maxo.xcodeproj/` | Xcode project and shared build scheme |

The implementation follows Apple’s Core Audio tap sample and native interface APIs. [Core Audio process taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) · [Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views) · [Agent apps](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement) · [ITU-R BS.1770](https://www.itu.int/dms_pubrec/itu-r/rec/bs/R-REC-BS.1770-5-202311-I%21%21PDF-E.pdf)
