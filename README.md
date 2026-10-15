# Jacquard Mac Jacket Dodger

## What Jacquard set out to do

Jacquard came out of Google's ATAP research group and was unveiled at Google I/O in 2015, led by interaction designer Ivan Poupyrev. The starting idea was that a woven textile has the same grid structure as a touchscreen. If some of the threads are replaced with conductive yarn, the fabric can sense simple touch gestures ([Dezeen](https://www.dezeen.com/2015/06/03/google-smartphone-interfaces-conductive-threads-clothes-textiles-project-jacquard/)).

The goals, as the team described them in interviews and talks:

- **Make it real at industrial scale.** Poupyrev said the aim was to ["move beyond novelty"](https://techcrunch.com/2015/05/29/google-ataps-project-jacquard-wants-to-weave-sensors-into-your-clothes). The team built a conductive yarn that survives standard industrial looms and comes in any color, so the apparel industry would not have to change how it works ([TechCrunch](https://techcrunch.com/2015/05/29/google-ataps-project-jacquard-wants-to-weave-sensors-into-your-clothes), [Fast Company](https://www.fastcompany.com/3046864/meet-project-jacquard-googles-plan-to-turn-all-your-clothes-into-a-touchscreen)).
- **Only part of a garment needs to be smart.** A small woven patch, such as a cuff, is enough. The point was never to turn a whole garment into a touchscreen ([Fast Company](https://www.fastcompany.com/3046864/meet-project-jacquard-googles-plan-to-turn-all-your-clothes-into-a-touchscreen)).
- **A material for designers, not a gadget.** Google pitched Jacquard as a raw material that fashion and textile designers could use as part of their own language ([Engadget](https://www.engadget.com/2015-05-29-googles-first-partner-for-touch-sensitive-clothes-is-levis.html)). For the Levi's jacket, Poupyrev described the goal as ["a garment, not a gadget"](https://www.ideo.com/case-study/designing-the-levis-commuter-trucker-jacket-with-jacquard-by-google).
- **Ambient computing.** By 2019 Google framed Jacquard as easy access to digital functions through ordinary everyday things, with a small removable tag carrying the electronics ([Google blog](https://blog.google/products-and-platforms/products/atap/smarter-wardrobe-jacquard-google/)).

How it played out:

- **2015:** announced at Google I/O, with Levi's as the first partner ([Engadget](https://www.engadget.com/2015-05-29-googles-first-partner-for-touch-sensitive-clothes-is-levis.html)).
- **2017:** the Levi's Commuter Trucker Jacket, the first product ([Fast Company](https://www.fastcompany.co.za/)).
- **2019:** the second-generation Jacquard Tag, smaller than a stick of gum with up to two weeks of battery life, used in Levi's and Saint Laurent products ([Google blog](https://blog.google/products-and-platforms/products/atap/smarter-wardrobe-jacquard-google/)).
- **2020:** the Adidas GMR insole, built on the same second-generation tag and aimed at soccer ([9to5Google](https://9to5google.com/2020/03/10/adidas-gmr-jacquard-launch/)).
- **2021:** a public SDK for developers ([9to5Google](https://9to5google.com/2021/10/28/jacquard-sdk-allows-developers-to-make-their-own-smart-fabric-apps/)).
- **April 2023:** Google ended support for the Jacquard app ([9to5Google](https://9to5google.com/2023/03/28/google-shutting-down-jacquard-app/)).
- **April 2026:** Google archived the SDK repo this project is based on.

This project is a small test of what is left: one of those tags, in a garment it was not sold for, working over Bluetooth with no official app.

## About this project

An experiment in running an **Adidas GMR Jacquard tag inside a Levi's Trucker jacket**, driven from a **Mac** with Google's Jacquard iOS SDK, plus a small gesture-controlled game used to test how sensitive the gestures are and to learn what the tag actually reports.

Google's Jacquard app was shut down in April 2023 ([9to5Google](https://9to5google.com/2023/03/28/google-shutting-down-jacquard-app/)), so the jacket has no official software today. This repo shows that the open-source SDK can still talk to the tag directly over Bluetooth.

This application is written through the harness [Krystalize.AI](https://krystalize.ai/) - get your Mac M series private local LLM with memory for managing all of your development processes or as a local Chief of Staff.

Written by @GGDM on Krystalize.AI local harness.

## What was tested

- One Adidas GMR tag (Google's second-generation Jacquard tag, per [9to5Google](https://9to5google.com/2020/03/10/adidas-gmr-jacquard-launch/)) in one Levi's Trucker jacket with Jacquard, slide-in tag version.
- A MacBook Pro (Apple silicon), macOS 15, Xcode 26.3. No iPhone involved.

## What worked (observed on that one setup)

- The Mac connects to the tag over Bluetooth, and the tag reports the jacket as attached. Its vendor and product IDs match the SDK's Levi's Trucker Jacket entry.
- Brush In, Brush Out and Cover arrive as the SDK documents.
- **Double Tap arrives as raw event 8**, not event 1 as the SDK's `Gesture` enum expects. The SDK silently drops unknown events, so out of the box a double tap looks like nothing happened. The sample app here maps 8 to Double Tap. This mapping comes from observation, not documentation.
- Brush Up and Brush Down were not observed during testing. That does not mean they are unsupported.

## What did not work, and the workaround

- The tag in testing reported firmware 1.0.6, which the SDK treats as a flagged ("bad") version. On connect, the SDK then forces a firmware check against Google's cloud. That needs a Jacquard API key, and the Jacquard product is end of life, so no key could be obtained. The check failed and the SDK disconnected in a loop.
- This repo changes the SDK so that a failed cloud check logs a warning and the connection proceeds. The tag's firmware is not changed. The SDK does not say why 1.0.6 is flagged, so there may be problems we did not hit. **Use at your own risk.**
- Firmware updates, the IMU/motion features, and an iPhone app were **not** tested.

## Run it

Requirements: a Mac with Bluetooth, Xcode, a Jacquard tag in a supported garment, and the tag **not** paired to another app (a tag talks to one app at a time).

```sh
cd Apps/MacOSSample
xcodebuild -project MacOSSample.xcodeproj -scheme MacOSSample \
  -destination 'platform=macOS' -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build
open build/Build/Products/Debug/MacOSSample.app
```

Allow the Bluetooth prompt, wake the tag (tap it, or put it briefly on a charger), then Start Scanning and Connect. No API key is needed for connecting, gestures, LED or haptics; firmware updates need a key that is no longer obtainable.

## What the Mac app adds

- **Events list** (newest first) with raw event numbers and timestamps. Event numbers the SDK has no name for show up as "Unknown event N" instead of disappearing.
- **Raw touch mode**: live bars for the 12 sensor lines, a threshold slider, and a software tap / double tap detector. The detector rules (touch under 0.3 s, little sideways movement, second tap within 0.5 s) are guesses and may need tuning.
- **Jacket Dodger**, a three-lane dodger: Brush In/Out move left/right, Double Tap jumps, Cover raises a shield. Arrow keys, Space and S work from the keyboard. A toggle swaps left and right, because the physical direction of "in" is not documented.

## Changes from upstream

Based on [google/JacquardSDKiOS](https://github.com/google/JacquardSDKiOS) at commit `7db0fe2541c641d050584a6167b9ca977332d94e` (archived by Google in April 2026). Git history shows exactly what changed: the first commit is the unmodified upstream tree, and the second contains every change. Each modified source file carries a notice. In short:

- SDK: failed firmware check no longer disconnects; `disconnect(_:)` no longer asserts when there is no active connection; new `RawInferenceNotificationSubscription`.
- Mac sample: fixes for compile errors (switches that did not cover the SDK's newer firmware-update connection states) and a debug crash when disconnecting a tag with no live connection, plus the features above.
- One hardcoded Google API key in an upstream test file was replaced with a placeholder.

The original SDK README is kept as [README.SDK.md](README.SDK.md).

## License and trademarks

Apache License 2.0, as in the original; see [LICENSE](LICENSE). Copyright 2021 Google LLC for the original SDK; modifications are provided under the same license.

This is an independent hobby project. It is not affiliated with or endorsed by Google, Levi Strauss & Co. or adidas. Jacquard, Levi's, adidas and GMR are trademarks of their respective owners.
