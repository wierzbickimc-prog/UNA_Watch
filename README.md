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

Each app saves `training.json` in its own folder and reads the other's when it starts, using the newest. That file also holds the VO2max baseline. The starting values and threshold are in [TrainingLoad.hpp](MyRun/Software/Libs/Header/TrainingLoad.hpp), with a copy in `RunRoute`.

Weight and max heart rate are constants in [Format.hpp](MyRun/Software/Apps/LVGL-GUI/gui/include/gui/Format.hpp) and [FitnessEstimator.hpp](MyRun/Software/Libs/Header/FitnessEstimator.hpp). The starting baseline is in [Settings.hpp](MyRun/Software/Libs/Header/Settings.hpp).

## RunRoute

A separate copy of `MyRun` that follows a route. It has its own app ID and settings, and shares its training history and VO2max baseline with `MyRun`. Its first running screen shows the route, and the `MyRun` screens follow.

| Behavior | Setting |
|---|---|
| Line ahead and behind | 300 ft ahead, 30 ft behind, turned to your direction of travel |
| Off-course alarm | More than 150 ft off for 10 seconds, repeating each minute |
| Back on course | Within 100 ft, with a short signal |
| More than 80 ft off, or heading to the route | The view zooms out so the route stays visible |
| Before you reach the route, or after you finish it | No alarm |

These settings are in [RouteTracker.hpp](RunRoute/Software/Libs/Header/RouteTracker.hpp).

Choose a route on the watch from the app's start menu: Routes, then Select. The name shows under Start, and the choice stays until you change it. "No route" runs without one. If you delete the selected route, no route is selected. The route is read when a run starts. The list holds up to 32 routes.

Add a route over USB, with the watch plugged in and `RunRoute` already installed. The route takes its name from the GPX file:

```bash
.venv/bin/python3 RunRoute/tools/gpx2route.py my_route.gpx --install
```

Then eject the watch. To install the app itself, follow [Install an app](#install-an-app) with `RunRoute` in place of `MyRun`. To build or simulate it, use the commands below with `RunRoute` in place of `MyRun`. Its tests are in `RunRoute/Software/Tests/`.

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
