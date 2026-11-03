// c++ -std=c++17 -I../Libs/Header -I../../../una-sdk/Libs/Header ZoneAlertsTest.cpp -o /tmp/zone_test && /tmp/zone_test
#include <cstdio>

#include "RunConfig.hpp"
#include "RunZoneAlerts.hpp"

using Alert = RunZoneAlerts::Alert;
using Zone  = RunZoneAlerts::Zone;

static int failures = 0;

static void check(const char* name, bool ok)
{
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", name);
    failures += ok ? 0 : 1;
}

/// The seconds, from the start of a step, on which staying above target alerts.
static int alertsIn(RunZoneAlerts& alerts, int seconds, int* first = nullptr)
{
    alerts.stepStarted();
    int count = 0;
    for (int second = 1; second <= seconds; ++second) {
        if (alerts.tick(Zone::Above) == Alert::Above) {
            if (count == 0 && first != nullptr) {
                *first = second;
            }
            ++count;
        }
    }
    return count;
}

int main()
{
    RunZoneAlerts standard;
    int first = 0;
    check("defaults match the SDK", alertsIn(standard, 111, &first) == 4 && first == 21);

    RunZoneAlerts custom;
    custom.setTimings(5, 10);
    check("timings can be changed", alertsIn(custom, 26, &first) == 3 && first == 6);

    RunZoneAlerts quiet;
    quiet.setTimings(0, 600);
    check("a long repeat stays quiet", alertsIn(quiet, 100, &first) == 1 && first == 1);

    RunZoneAlerts back;
    back.stepStarted();
    for (int second = 0; second < 25; ++second) {
        back.tick(Zone::Above);
    }
    check("coming back in says so", back.tick(Zone::In) == Alert::BackIn);
    check("and only once", back.tick(Zone::In) == Alert::None);

    const RunConfig config;
    check("the default threshold is 8:30", config.thresholdPaceSec == 510);

    std::printf(failures == 0 ? "All passed\n" : "%d failed\n", failures);
    return failures == 0 ? 0 : 1;
}
