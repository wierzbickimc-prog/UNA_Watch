/**
 ******************************************************************************
 * @file    ScreenLayout.hpp
 * @brief   The run screens RouteSync's screen builder sets: which screens a
 *          run pages through, in order, and the fields on each data screen.
 *
 *          RouteSync writes them to screens.json in the app's folder:
 *
 *              {"schema":1,"screens":[
 *                  {"kind":"route"},
 *                  {"kind":"data","fields":["hr","lapPace","distance"]},
 *                  {"kind":"status"}]}
 *
 *          The service reads the file when the app starts and sends the layout
 *          to the GUI. A missing or unusable file means the default screens,
 *          the same ones the app had before the builder.
 *
 *          RouteSync's ScreenLayout.swift holds the same keys. Its tests check
 *          them against this file.
 ******************************************************************************
 */

#ifndef SCREEN_LAYOUT_HPP
#define SCREEN_LAYOUT_HPP

#include <cstddef>
#include <cstdint>
#include <cstring>

struct ScreenLayout {
    static constexpr uint8_t kMaxScreens = 8;
    static constexpr uint8_t kMaxFields  = 4;
    static constexpr uint8_t kSchema     = 1;

    enum class Kind : uint8_t {
        DATA = 0,   ///< One to four fields
        ROUTE,      ///< The route map
        CONDITION,  ///< Performance condition
        STATUS,     ///< Sensors, clock and battery
        COUNT
    };

    /// Append only: the numbers travel between the service and the GUI.
    enum class Field : uint8_t {
        NONE = 0,
        PACE, AVG_PACE, LAP_PACE,
        DISTANCE, LAP_DISTANCE,
        TIME, LAP_TIME, LAPS,
        HR, AVG_HR, MAX_HR, LAP_HR, HR_ZONE,
        SPEED, AVG_SPEED,
        ELEVATION, CALORIES, INTENSITY, CONDITION,
        CLOCK, BATTERY,
        COUNT
    };

    struct Screen {
        Kind    kind       = Kind::DATA;
        uint8_t fieldCount = 0;
        Field   fields[kMaxFields] = {};
    };

    uint8_t count = 0;
    Screen  screens[kMaxScreens] = {};

    /// The key screens.json uses for each field, in Field order.
    static const char* key(Field field)
    {
        static const char* const kKeys[] = {
            "",
            "pace", "avgPace", "lapPace",
            "distance", "lapDistance",
            "time", "lapTime", "laps",
            "hr", "avgHr", "maxHr", "lapHr", "hrZone",
            "speed", "avgSpeed",
            "elevation", "calories", "intensity", "condition",
            "clock", "battery",
        };
        static_assert(sizeof(kKeys) / sizeof(kKeys[0]) == static_cast<size_t>(Field::COUNT),
                      "one key per field");
        const auto i = static_cast<size_t>(field);
        return i < static_cast<size_t>(Field::COUNT) ? kKeys[i] : "";
    }

    static const char* key(Kind kind)
    {
        static const char* const kKeys[] = { "data", "route", "condition", "status" };
        static_assert(sizeof(kKeys) / sizeof(kKeys[0]) == static_cast<size_t>(Kind::COUNT),
                      "one key per kind");
        const auto i = static_cast<size_t>(kind);
        return i < static_cast<size_t>(Kind::COUNT) ? kKeys[i] : "";
    }

    /// Field::NONE for a key this app doesn't know.
    static Field fieldFromKey(const char* text, size_t len)
    {
        for (uint8_t i = 1; i < static_cast<uint8_t>(Field::COUNT); ++i) {
            const char* k = key(static_cast<Field>(i));
            if (std::strlen(k) == len && std::strncmp(k, text, len) == 0) {
                return static_cast<Field>(i);
            }
        }
        return Field::NONE;
    }

    /// Kind::COUNT for a key this app doesn't know.
    static Kind kindFromKey(const char* text, size_t len)
    {
        for (uint8_t i = 0; i < static_cast<uint8_t>(Kind::COUNT); ++i) {
            const char* k = key(static_cast<Kind>(i));
            if (std::strlen(k) == len && std::strncmp(k, text, len) == 0) {
                return static_cast<Kind>(i);
            }
        }
        return Kind::COUNT;
    }

    bool add(const Screen& screen)
    {
        if (count >= kMaxScreens) {
            return false;
        }
        screens[count++] = screen;
        return true;
    }

    static Screen special(Kind kind)
    {
        Screen s;
        s.kind = kind;
        return s;
    }

    static Screen data(Field a, Field b = Field::NONE, Field c = Field::NONE, Field d = Field::NONE)
    {
        Screen s;
        const Field all[kMaxFields] = { a, b, c, d };
        for (Field f : all) {
            if (f != Field::NONE) {
                s.fields[s.fieldCount++] = f;
            }
        }
        return s;
    }

    /// The screens the app had before the builder: route, run, totals,
    /// condition, status.
    static ScreenLayout defaults()
    {
        ScreenLayout layout;
        layout.add(special(Kind::ROUTE));
        layout.add(data(Field::HR, Field::LAP_PACE, Field::DISTANCE));
        layout.add(data(Field::TIME, Field::DISTANCE, Field::CALORIES));
        layout.add(special(Kind::CONDITION));
        layout.add(special(Kind::STATUS));
        return layout;
    }

    /// The first screen of @p kind, or count if there is none.
    uint8_t find(Kind kind) const
    {
        for (uint8_t i = 0; i < count; ++i) {
            if (screens[i].kind == kind) {
                return i;
            }
        }
        return count;
    }
};

/**
 * Reads screens.json. Unknown screen kinds and field keys are skipped, so a
 * newer RouteSync can't break an older app. Returns false, leaving @p layout
 * untouched, when nothing usable is left: a bad file, another schema, or no
 * screens.
 */
bool parseScreenLayout(const char* json, size_t len, ScreenLayout& layout);

#endif // SCREEN_LAYOUT_HPP
