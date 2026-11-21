# External Brightness

External Brightness is a small menu bar app for the Mac that lets you change an external monitor's brightness, contrast, colour and input without reaching for the buttons on the monitor. It's for anyone who plugs a Mac into a separate screen, and it's most useful with the laptop lid closed, when the Mac's brightness keys would otherwise do nothing.

<img src="docs/images/menu.png" width="560" alt="The External Brightness menu, with brightness and contrast sliders and the Colour &amp; Sharpness submenu open">

## Features

- **Brightness and contrast sliders** in the menu bar, with one-click brightness presets.
- **Brightness keys that work with the lid closed.** When the Mac's own screen is off, the keys on your keyboard change the monitor instead, and a small overlay shows the level. Hold Option and Shift for finer steps.
- **Sync with the built-in display.** Turn on Sync with Built-in Display and a brightness change on either screen carries over to the other.
- **Colour controls.** Pick a colour preset or picture mode, or set red, green, blue and sharpness yourself.
- **Input switching** between USB-C / Thunderbolt, DisplayPort and HDMI.
- **Keeps up with the monitor's own buttons.** Change the brightness on the monitor and the menu catches up.
- **The small stuff:** sleep the display, launch at login, and reset the monitor's settings when you've gone too far.

<img src="docs/images/brightness-overlay.png" width="244" alt="The brightness overlay that appears when you press a brightness key">

## How to start

You need a Mac with Apple silicon running macOS 13 or later, and a monitor that accepts settings from the computer it's plugged into. Most do, through a standard called DDC/CI.

1. Download the zip from the [releases page](https://github.com/jjohnson1994/mac-monitor-control/releases/latest), unzip it and drag External Brightness into your Applications folder.
2. Open it. Apple hasn't checked the app, so macOS blocks it the first time. Go to System Settings, then Privacy & Security, and choose Open Anyway.
3. Look for the sun icon in the menu bar. That's the whole app.
4. To use the brightness keys, allow External Brightness under Accessibility when macOS asks. If you missed the prompt, choose Enable Brightness Keys… in the menu.

## Good to know

- The app was built around a Dell U2725QE. The colour preset, picture mode and input lists are that monitor's, so on another monitor some of those choices may not match.
- It controls one external monitor: the first one it finds.
- If the sliders show N/A, the app can't find a monitor it can talk to.

## Build it yourself

With Xcode's command line tools installed, run the build script:

```
./build.sh
```

```
Built: build/External Brightness.app
```

## Owner

Made by [jjohnson1994](https://github.com/jjohnson1994). If something doesn't work with your monitor, [open an issue](https://github.com/jjohnson1994/mac-monitor-control/issues).
