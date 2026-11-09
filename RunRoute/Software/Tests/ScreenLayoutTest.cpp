// S=../../../una-sdk; cc -c -I$S/ThirdParty/coreJSON/source/include $S/ThirdParty/coreJSON/source/core_json.c -o /tmp/core_json.o && c++ -std=c++17 -I../Libs/Header -I$S/Libs/Header -I$S/ThirdParty/coreJSON/source/include ScreenLayoutTest.cpp ../Libs/Sources/ScreenLayout.cpp $S/Libs/Source/JSON/JsonStreamReader.cpp /tmp/core_json.o -o /tmp/screens_test && /tmp/screens_test
#include <cstdio>
#include <cstring>

#include "ScreenLayout.hpp"

using Field = ScreenLayout::Field;
using Kind  = ScreenLayout::Kind;

static int failures = 0;

static void check(const char* name, bool ok)
{
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", name);
    failures += ok ? 0 : 1;
}

static bool parse(const char* json, ScreenLayout& layout)
{
    return parseScreenLayout(json, std::strlen(json), layout);
}

int main()
{
    {
        ScreenLayout d = ScreenLayout::defaults();
        check("defaults: five screens", d.count == 5);
        check("defaults: route first", d.screens[0].kind == Kind::ROUTE);
        check("defaults: run screen", d.screens[1].fieldCount == 3 && d.screens[1].fields[0] == Field::HR &&
                                      d.screens[1].fields[1] == Field::LAP_PACE && d.screens[1].fields[2] == Field::DISTANCE);
        check("defaults: status last", d.screens[4].kind == Kind::STATUS);
    }
    {
        ScreenLayout l;
        const bool ok = parse(R"({"schema":1,"screens":[
            {"kind":"data","fields":["pace"]},
            {"kind":"route"},
            {"kind":"data","fields":["hr","lapPace","distance","clock"]}]})", l);
        check("parses", ok && l.count == 3);
        check("one field", l.screens[0].kind == Kind::DATA && l.screens[0].fieldCount == 1 && l.screens[0].fields[0] == Field::PACE);
        check("route", l.screens[1].kind == Kind::ROUTE);
        check("four fields", l.screens[2].fieldCount == 4 && l.screens[2].fields[3] == Field::CLOCK);
        check("find route", l.find(Kind::ROUTE) == 1 && l.find(Kind::STATUS) == 3);
    }
    {
        ScreenLayout l;
        const bool ok = parse(R"({"schema":1,"screens":[
            {"kind":"hologram"},
            {"kind":"data","fields":["cadence","hr","warp"]},
            {"kind":"data","fields":["warp"]},
            {"kind":"data"}]})", l);
        check("unknown kinds and fields are skipped", ok && l.count == 1 && l.screens[0].fieldCount == 1 &&
                                                      l.screens[0].fields[0] == Field::HR);
    }
    {
        ScreenLayout l;
        parse(R"({"schema":1,"screens":[{"kind":"data","fields":["pace","hr","time","distance","laps"]},
            {"kind":"status"},{"kind":"status"},{"kind":"status"},{"kind":"status"},
            {"kind":"status"},{"kind":"status"},{"kind":"status"},{"kind":"route"}]})", l);
        check("at most four fields", l.screens[0].fieldCount == 4);
        check("at most eight screens", l.count == 8 && l.screens[7].kind == Kind::STATUS);
    }
    {
        ScreenLayout l = ScreenLayout::defaults();
        check("bad JSON fails", !parse("{\"schema\":1,\"screens\":[", l));
        check("other schema fails", !parse(R"({"schema":2,"screens":[{"kind":"route"}]})", l));
        check("no screens fails", !parse(R"({"schema":1,"screens":[]})", l));
        check("nothing usable fails", !parse(R"({"schema":1,"screens":[{"kind":"data","fields":[]}]})", l));
        check("failure leaves the layout", l.count == 5);
    }
    {
        bool roundTrip = true;
        for (uint8_t i = 1; i < static_cast<uint8_t>(Field::COUNT); ++i) {
            const char* k = ScreenLayout::key(static_cast<Field>(i));
            roundTrip = roundTrip && ScreenLayout::fieldFromKey(k, std::strlen(k)) == static_cast<Field>(i);
        }
        check("every key reads back", roundTrip);
    }

    std::printf(failures ? "%d FAILED\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
