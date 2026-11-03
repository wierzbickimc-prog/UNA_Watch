// Host test for RouteTracker. From this folder:
//   c++ -std=c++17 -I../Libs/Header RouteTrackerTest.cpp -o /tmp/route_test && /tmp/route_test

#include "RouteTracker.hpp"

#include <cmath>
#include <cstdio>
#include <vector>

static int sFailures = 0;

static void check(const char* name, bool ok)
{
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", name);
    sFailures += ok ? 0 : 1;
}

static constexpr double kLat = 40.0;
static constexpr double kLon = -105.0;
static constexpr double kPerLat = 111320.0;
static const double kPerLon = kPerLat * std::cos(kLat * 3.14159265358979323846 / 180.0);

static double latOf(double north) { return kLat + north / kPerLat; }
static double lonOf(double east) { return kLon + east / kPerLon; }

static void putU32(std::vector<uint8_t>& out, uint32_t v)
{
    for (int i = 0; i < 4; ++i) {
        out.push_back(static_cast<uint8_t>(v >> (8 * i)));
    }
}

/// A route file from points given as metres east and north.
static std::vector<uint8_t> routeFile(const std::vector<std::pair<double, double>>& points)
{
    std::vector<uint8_t> out = {'U', 'R', 'T', 'E'};
    putU32(out, static_cast<uint32_t>(points.size()));
    for (const auto& p : points) {
        putU32(out, static_cast<uint32_t>(static_cast<int32_t>(std::lround(latOf(p.second) * 1e7))));
        putU32(out, static_cast<uint32_t>(static_cast<int32_t>(std::lround(lonOf(p.first) * 1e7))));
    }
    return out;
}

static RouteTracker loaded(const std::vector<std::pair<double, double>>& points)
{
    RouteTracker tracker;
    const auto file = routeFile(points);
    tracker.load(file.data(), file.size());
    return tracker;
}

static RouteTracker::Event at(RouteTracker& t, uint32_t sec, double east, double north)
{
    return t.update(sec, latOf(north), lonOf(east));
}

int main()
{
    using Event  = RouteTracker::Event;
    using Status = Track::RouteStatus;

    {
        RouteTracker t;
        check("no route to start with", t.view().status == Status::NO_ROUTE);
        const std::vector<uint8_t> junk = {'n', 'o', 'p', 'e', 1, 0, 0, 0};
        check("rejects a wrong header", !t.load(junk.data(), junk.size()));
        auto cut = routeFile({{0, 0}, {0, 100}});
        cut.pop_back();
        check("rejects a cut-off file", !t.load(cut.data(), cut.size()));
        check("rejects one point", !t.load(routeFile({{0, 0}}).data(), routeFile({{0, 0}}).size()));
        check("rejects no data", !t.load(nullptr, 0));
    }

    const std::vector<std::pair<double, double>> north = {{0, 0}, {0, 2000}};

    {
        RouteTracker t = loaded(north);
        check("waits for GPS", t.view().status == Status::WAITING);
        at(t, 0, 0, 0);
        check("on course at the start", t.view().status == Status::ON_COURSE);
        check("remaining at the start", std::fabs(t.view().remainingM - 2000.0f) < 3.0f);
        at(t, 1, 0, 60);
        at(t, 2, 0, 70);
        const Track::RouteView v = t.view();
        check("line runs straight up when heading north", v.count >= 2 && std::abs(v.x[v.count - 1]) < 20);
        check("line reaches 300 ft ahead", std::fabs(v.y[v.count - 1] / 10.0f - 91.44f) < 3.0f);
        check("line starts 30 ft behind", std::fabs(v.y[0] / 10.0f + 9.144f) < 3.0f);
    }

    {
        RouteTracker t = loaded({{0, 0}, {2000, 0}});
        at(t, 0, 0, 0);
        at(t, 1, 10, 0);
        at(t, 2, 20, 0);
        const Track::RouteView v = t.view();
        check("line still runs up when heading east", v.y[v.count - 1] > 800 && std::abs(v.x[v.count - 1]) < 20);
    }

    {
        // Heading north towards a right turn: the line should bend to the right.
        RouteTracker t = loaded({{0, 0}, {0, 100}, {200, 100}});
        at(t, 0, 0, 40);
        at(t, 1, 0, 50);
        at(t, 2, 0, 60);
        const Track::RouteView v = t.view();
        check("a right turn bends right", v.x[v.count - 1] > 200);
    }

    {
        RouteTracker t = loaded(north);
        at(t, 0, 0, 100);
        bool early = false;
        for (uint32_t s = 1; s < 10; ++s) {
            early = early || at(t, s, 60, 100) != Event::None;
        }
        check("no alarm for the first 10 seconds", !early);
        check("alarm after 10 seconds off", at(t, 11, 60, 100) == Event::WentOff);
        check("shows off course", t.view().status == Status::OFF_COURSE);
        check("reports the distance off", std::fabs(t.view().offCourseM - 60.0f) < 2.0f);
        bool repeated = false;
        for (uint32_t s = 12; s < 71; ++s) {
            repeated = repeated || at(t, s, 60, 100) != Event::None;
        }
        check("quiet between alarms", !repeated);
        check("repeats after a minute", at(t, 71, 60, 100) == Event::StillOff);
        check("stays off in between the limits", at(t, 72, 40, 100) == Event::None && t.view().status == Status::OFF_COURSE);
        check("back on course", at(t, 73, 20, 100) == Event::BackOn);
        check("shows on course", t.view().status == Status::ON_COURSE);
    }

    {
        RouteTracker t = loaded(north);
        at(t, 0, 0, 100);
        for (uint32_t s = 1; s < 8; ++s) {
            at(t, s, 60, 100);
        }
        at(t, 8, 0, 100);
        bool alarm = false;
        for (uint32_t s = 9; s < 15; ++s) {
            alarm = alarm || at(t, s, 60, 100) != Event::None;
        }
        check("a brief wander restarts the wait", !alarm);
    }

    {
        RouteTracker t = loaded(north);
        bool alarm = false;
        for (uint32_t s = 0; s < 40; ++s) {
            alarm = alarm || at(t, s, 500, 0) != Event::None;
        }
        check("no alarm before reaching the route", !alarm);
        check("shows the way to the route", t.view().status == Status::TO_START);
        check("reports the distance to the route", std::fabs(t.view().offCourseM - 500.0f) < 2.0f);
        at(t, 41, 10, 0);
        check("joins on arrival", t.view().status == Status::ON_COURSE);
    }

    {
        // Out and back along one road: progress must not jump to the return leg.
        RouteTracker t = loaded({{0, 0}, {0, 500}, {0, 0}});
        for (uint32_t s = 0; s < 40; ++s) {
            at(t, s, 2, s * 5.0);
        }
        check("stays on the outward leg", std::fabs(t.view().remainingM - (1000.0f - 195.0f)) < 10.0f);
        for (uint32_t s = 0; s < 100; ++s) {
            at(t, 40 + s, 2, 195.0 + s * 3.0);
        }
        for (uint32_t s = 0; s < 96; ++s) {
            at(t, 140 + s, 2, 495.0 - s * 5.0);
        }
        check("follows the return leg", t.view().remainingM < 40.0f);
        at(t, 300, 2, 0);
        check("finishes", t.view().status == Status::DONE);
        bool alarm = false;
        for (uint32_t s = 0; s < 30; ++s) {
            alarm = alarm || at(t, 301 + s, 500, 500) != Event::None;
        }
        check("no alarm after finishing", !alarm);
    }

    {
        // A shortcut rejoins further on, beyond what a following search covers.
        RouteTracker t = loaded({{0, 0}, {0, 1000}, {1000, 1000}, {1000, 0}});
        at(t, 0, 0, 100);
        at(t, 1, 1000, 100);
        check("a shortcut is picked up", t.view().status == Status::ON_COURSE &&
                                         std::fabs(t.view().remainingM - 100.0f) < 5.0f);
    }

    {
        std::vector<std::pair<double, double>> dense;
        for (int i = 0; i < 3000; ++i) {
            dense.push_back({0.0, i * 0.5});
        }
        RouteTracker t = loaded(dense);
        at(t, 0, 0, 300);
        const Track::RouteView v = t.view();
        check("a dense route stays within the message", v.count <= Track::RouteView::kMaxPoints);
        check("a dense route still reaches ahead", std::fabs(v.y[v.count - 1] / 10.0f - 91.44f) < 3.0f);
    }

    {
        RouteTracker t = loaded(north);
        at(t, 0, 0, 100);
        t.reset();
        check("reset keeps the route", t.view().status == Status::WAITING);
    }

    {
        // 60 m off a route heading north: beyond the default 150 ft.
        const std::vector<std::pair<double, double>> route = {{0, 0}, {0, 2000}};
        RouteTracker standard = loaded(route);
        RouteTracker wide = loaded(route);
        wide.setLimits(100.0f, 80.0f, 10, 60, 20.0f);
        at(standard, 0, 0, 100);
        at(wide, 0, 0, 100);
        bool standardAlarmed = false, wideAlarmed = false;
        for (uint32_t second = 1; second < 40; ++second) {
            standardAlarmed = at(standard, second, 60, 100) != RouteTracker::Event::None || standardAlarmed;
            wideAlarmed     = at(wide, second, 60, 100) != RouteTracker::Event::None || wideAlarmed;
        }
        check("the default limit alarms at 60 m", standardAlarmed);
        check("a wider limit doesn't", !wideAlarmed);
    }

    std::printf(sFailures ? "%d FAILED\n" : "all passed\n", sFailures);
    return sFailures ? 1 : 0;
}
