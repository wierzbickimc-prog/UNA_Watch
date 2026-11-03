# UNA Watch apps

Personal apps for the UNA Watch, built on a Mac. `MyRun` is a copy of UNA's `RunLVGL` example with custom running screens.

## Using the watch

The buttons are Up (top left), Down (bottom left), Select (top right) and Back (bottom right).

| Task | How |
|---|---|
| Open settings | From the home screen, press Up |
| Power off | Settings > power off |
| Power on | Hold Select for a few seconds, and let go once the screen lights up |
| Add an external sensor, such as a heart rate strap | Settings |
| Open the app list | Press Select |
| Control music (pause, forward, back) | Hold Down while an app runs. Works with Spotify on iPhone. |

**Avoid factory reset:** holding Select for too long while the watch powers on reportedly opens a bootloader menu with a Factory reset option.

## Install an app

1. Plug in the watch over USB. It mounts as `UNA WATCH`.
2. Create `Apps/<AppName>/` on the drive.
3. Copy the `.uapp` into that folder from Terminal. Finder and `cp` can both leave hidden `._` files, so remove any that appear:

   ```bash
   mkdir -p "/Volumes/UNA WATCH/Apps/MyRun"
   COPYFILE_DISABLE=1 cp -X MyRun/Output/MyRun_*.uapp "/Volumes/UNA WATCH/Apps/MyRun/"
   find "/Volumes/UNA WATCH/Apps" -maxdepth 2 -name '._*'
   ```

4. Eject `UNA WATCH` and unplug the watch.
5. Power the watch off and back on.
6. Press Select and look for the app.

## MyRun

Running screens, paged with Up and Down:

1. Heart rate, lap pace, distance
2. Time, distance, calories
3. Condition
4. Clock, GPS, battery

The post-run summary adds three pages: VO2 MAX, Condition with its start, lowest and end values plus calories, and Training. Distance and pace are always in miles, whatever the watch is set to.

### Estimates

| Value | How it works |
|---|---|
| Calories | Distance (km) × body weight (165 lb) |
| VO2max | Daniels-Gilbert running cost ÷ the share of VO2max implied by heart rate (Swain), using a max heart rate of 197. Needs about 15 minutes, 10 of them steady and flat. |
| Condition | Current estimate against the usual VO2max, in percent. Appears about 6 minutes in. |
| Baseline | Starts at 51, the Garmin's reading. Each saved run with a VO2max moves it 20% of the way to that value. |

Condition labels: Fresh is +3 or higher, Normal is −2 to +2, Tired is −3 to −7, Struggling is −8 or lower.

### Training metrics

These follow intervals.icu, but only count runs recorded in `MyRun` and `RunRoute`. Intensity is live on the Condition screen. The post-run Training page shows intensity, load, fitness, fatigue and form.

| Value | How it works |
|---|---|
| Intensity | Pace against threshold (8:30/mile), adjusted roughly for grade. 1.00 is threshold pace held throughout. |
| Load | One hour at threshold is 100 |
| Fitness, Fatigue | 42 and 7 day exponentially weighted averages of daily load. Started from 12 and 24 on November 2, 2026. |
| Form | Fitness minus fatigue |

Each app saves `training.json` in its own folder and reads the other's when it starts, using the newest. That file also holds the VO2max baseline.

### Settings

`RouteSync`'s Settings screen sets the threshold, weight, max heart rate, condition labels, target alert timing, route alarms and 80/20 zones. Send to Watch writes `app_config.json` to each app's folder, and each app reads it when it starts. It also updates the targets of workouts already on the watch, and can set fitness, fatigue and the VO2max baseline. Values not set in that file use the defaults in [RunConfigLoader.cpp](MyRun/Software/Libs/Sources/RunConfigLoader.cpp), which has a copy in `RunRoute`. Changing a default means changing it in those two files and in [RunSettings.swift](RunRoute/mac/RouteSync/Sources/RouteCore/RunSettings.swift). `RouteSync`'s tests compare them.

## RunRoute

A separate copy of `MyRun` that follows a route. It has its own app ID and settings, and shares its training history and VO2max baseline with `MyRun`. Its first running screen shows the route, and the `MyRun` screens follow.

| Behavior | Setting |
|---|---|
| Line ahead and behind | 300 ft ahead, 30 ft behind, turned to your direction of travel |
| Off-course alarm | More than 150 ft off for 10 seconds, repeating each minute |
| Back on course | Within 100 ft, with a short signal |
| More than 80 ft off, or heading to the route | The view zooms out so the route stays visible |
| Before you reach the route, or after you finish it | No alarm |

Set these in `RouteSync`'s [Settings](#settings).

Choose a route on the watch from the app's start menu: Routes, then Select. The name shows under Start, and the choice stays until you change it. "No route" runs without one. If you delete the selected route, no route is selected. The route is read when a run starts. The list holds up to 32 routes.

Add a route over USB, with the watch plugged in and `RunRoute` already installed. The route takes its name from the GPX file:

```bash
.venv/bin/python3 RunRoute/tools/gpx2route.py my_route.gpx --install
```

Or use `RouteSync`, a Mac app that does all of that. Build it once:

```bash
RunRoute/mac/RouteSync/build_app.sh
open RunRoute/mac/RouteSync/build/RouteSync.app
```

Choose a GPX file or drop one on the window, check its name, and choose Send to Watch. Plug in the watch if it isn't already. `RouteSync` sends the route, checks it and ejects the watch. If something goes wrong, it leaves the watch connected and says what happened. New routes appear the next time you open `RunRoute`. To run its tests: `RunRoute/mac/RouteSync/test.sh`.

With the watch plugged in, See What's on the Watch renames or deletes routes and workouts.

Routes can't be sent from the Mac over Bluetooth for now: while the watch is paired to a phone, it ignored the Mac's connection attempts. `RunRoute/tools/route_ble.py` (needs `.venv/bin/pip install bleak`) and `RunRoute/mac/RouteSync/Bluetooth/` are kept for testing that.

After using `gpx2route.py --install`, eject the watch. To install the app itself, follow [Install an app](#install-an-app) with `RunRoute` in place of `MyRun`. To build or simulate it, use the commands below with `RunRoute` in place of `MyRun`. Its tests are in `RunRoute/Software/Tests/`.

## Structured workouts

`MyRun` and `RunRoute` both list FIT workouts from the `Workouts` folder at the top of the watch's drive, under Workouts in the start menu. `RouteSync` sends them the same way as routes: choose a `.fit` file, rename it if you like, and choose Send to Watch. A workout you've chosen runs alongside the route selected in `RunRoute`.

[80/20 Endurance's workouts](https://www.8020endurance.com/8020-workout-library/) only name a zone in each step's notes, and its seven zones are percentages of your own threshold. So `RouteSync` writes a copy with real targets, and leaves the original alone. These are the starting zones, which you can change in its [Settings](#settings):

| Zone | Heart rate, % of threshold | Pace, % of threshold speed |
|---|---|---|
| 1 | 72 to 81 | 60 to 76 |
| 2 | 81 to 90 | 76 to 87 |
| X | 90 to 95 | 87 to 93 |
| 3 | 95 to 100 | 93 to 100 |
| Y | 100 to 102 | 100 to 102 |
| 4 | 102 to 105 | 102 to 115 |
| 5 | 105 to 110 | 115 to 130 |

80/20 gives Zone 5 only as "over" its lower figure, so the top is my choice. In heart rate mode, steps under 2 minutes or 800 m stay as labels by default, because heart rate can't catch up in that time.

### Workout builder

`RouteSync`'s Workout builder makes your own workouts from steps and repeats. A step ends by time, distance or lap press, and aims at an 80/20 zone, a pace range, a heart rate range, or nothing. Workouts save on the Mac as you edit them, in `~/Library/Application Support/RouteSync/workouts.json`, and Import FIT makes an editable copy of an existing workout. Repeats inside repeats can't be built or imported.

Send to Watch uses the same check-and-send screen as a downloaded workout. Zones are worked out from your threshold when you send, and again whenever you send settings.

## Build

`una-sdk/`, `tools/` and `.venv/` are not in git. To recreate them:

```bash
git clone https://github.com/UNAWatch/una-sdk.git
git -C una-sdk checkout sdk-v1.6.2
git -C una-sdk submodule update --init ThirdParty/lvgl
brew install cmake ninja sdl2 python@3.13
/opt/homebrew/bin/python3.13 -m venv .venv
.venv/bin/pip install -r una-sdk/Utilities/Scripts/app_packer/requirements.txt
pkgutil --expand-full <STM32CubeCLT Mac .pkg> tools/stm32cubeclt
```

Build the watch app. The result is in `MyRun/Output/`:

```bash
export UNA_SDK="$PWD/una-sdk"
export PATH="$PWD/tools/stm32cubeclt/tmp.pkg/Payload/GNU-tools-for-STM32/bin:$PATH"
cmake -G "Unix Makefiles" -S MyRun/Software/Apps/RunLVGL-CMake -B MyRun/build \
  -DUNA_PYTHON_EXECUTABLE="$PWD/.venv/bin/python3"
cmake --build MyRun/build -j10
```

Run the Mac simulator, using keys 1 to 4 for Up, Down, Select and Back:

```bash
export UNA_SDK="$PWD/una-sdk"
cd MyRun/Software/Apps/LVGL-GUI/simulator
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Debug
cmake --build build
cd build/bin && ./RunLVGLSimulator
```

Run the estimator tests:

```bash
cd MyRun/Software/Tests
c++ -std=c++17 -I../Libs/Header FitnessEstimatorTest.cpp -o /tmp/fitness_test && /tmp/fitness_test
```
