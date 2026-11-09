#include "ScreenLayout.hpp"

#include <cstdio>

#include "SDK/JSON/JsonStreamReader.hpp"

bool parseScreenLayout(const char* json, size_t len, ScreenLayout& layout)
{
    SDK::JsonStreamReader reader(json, len);
    if (!reader.validate()) {
        return false;
    }
    uint32_t schema = 0;
    if (!reader.get("schema", schema) || schema != ScreenLayout::kSchema) {
        return false;
    }
    size_t screens = 0;
    if (!reader.getArrayLength("screens", screens)) {
        return false;
    }

    ScreenLayout parsed;
    char query[40];
    for (size_t i = 0; i < screens && parsed.count < ScreenLayout::kMaxScreens; ++i) {
        const char* text = nullptr;
        size_t textLen = 0;
        snprintf(query, sizeof(query), "screens[%u].kind", static_cast<unsigned>(i));
        if (!reader.get(query, text, textLen)) {
            continue;
        }
        const ScreenLayout::Kind kind = ScreenLayout::kindFromKey(text, textLen);
        if (kind == ScreenLayout::Kind::COUNT) {
            continue;
        }
        ScreenLayout::Screen screen = ScreenLayout::special(kind);
        if (kind == ScreenLayout::Kind::DATA) {
            size_t fields = 0;
            snprintf(query, sizeof(query), "screens[%u].fields", static_cast<unsigned>(i));
            reader.getArrayLength(query, fields);
            for (size_t f = 0; f < fields && screen.fieldCount < ScreenLayout::kMaxFields; ++f) {
                snprintf(query, sizeof(query), "screens[%u].fields[%u]", static_cast<unsigned>(i),
                         static_cast<unsigned>(f));
                if (!reader.get(query, text, textLen)) {
                    continue;
                }
                const ScreenLayout::Field field = ScreenLayout::fieldFromKey(text, textLen);
                if (field != ScreenLayout::Field::NONE) {
                    screen.fields[screen.fieldCount++] = field;
                }
            }
            if (screen.fieldCount == 0) {
                continue;
            }
        }
        parsed.add(screen);
    }
    if (parsed.count == 0) {
        return false;
    }
    layout = parsed;
    return true;
}
