// Host test for RouteCatalog. From this folder:
//   c++ -std=c++17 -I../Libs/Header RouteCatalogTest.cpp -o /tmp/catalog_test && /tmp/catalog_test

#include "RouteCatalog.hpp"

#include <cstdio>
#include <cstring>
#include <string>

static int sFailures = 0;

static void check(const char* name, bool ok)
{
    std::printf("%s %s\n", ok ? "ok  " : "FAIL", name);
    sFailures += ok ? 0 : 1;
}

int main()
{
    RouteCatalog c;
    check("starts empty", c.size() == 0 && c.selected() == RouteCatalog::kNone);
    check("takes a route", c.add("Starr Hill.bin"));
    check("takes another", c.add("Alpha Loop.bin"));
    check("skips another kind of file", !c.add("notes.txt"));
    check("skips macOS hidden files", !c.add("._Alpha Loop.bin"));
    check("skips an empty name", !c.add(".bin"));
    check("skips a name too long", !c.add((std::string(40, 'x') + ".bin").c_str()));
    check("takes the longest name", c.add((std::string(39, 'z') + ".bin").c_str()));

    c.sort();
    check("sorts by name", std::strcmp(c.name(0), "Alpha Loop") == 0 && std::strcmp(c.name(1), "Starr Hill") == 0);

    char path[64];
    check("gives the path", c.path(1, path, sizeof(path)) && std::strcmp(path, "Routes/Starr Hill.bin") == 0);
    check("no path for no route", !c.path(RouteCatalog::kNone, path, sizeof(path)));
    check("no path past the end", !c.path(99, path, sizeof(path)));
    char tiny[8];
    check("no path if it does not fit", !c.path(1, tiny, sizeof(tiny)));

    c.select(1);
    check("selects by index", c.selected() == 1);
    c.select(99);
    check("a bad index selects nothing", c.selected() == RouteCatalog::kNone);
    c.selectName("Alpha Loop");
    check("selects by name", c.selected() == 0);
    c.selectName("Deleted Route");
    check("a missing name selects nothing", c.selected() == RouteCatalog::kNone);

    RouteCatalog full;
    for (size_t i = 0; i < RouteCatalog::kMaxRoutes; ++i) {
        full.add(("r" + std::to_string(i) + ".bin").c_str());
    }
    check("stops when full", !full.add("one more.bin") && full.size() == RouteCatalog::kMaxRoutes);

    c.clear();
    check("clears", c.size() == 0 && c.selected() == RouteCatalog::kNone);

    std::printf(sFailures ? "%d FAILED\n" : "all passed\n", sFailures);
    return sFailures ? 1 : 0;
}
