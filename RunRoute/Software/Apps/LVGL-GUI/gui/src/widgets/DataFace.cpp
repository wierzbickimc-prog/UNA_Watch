/**
 ******************************************************************************
 * @file    DataFace.cpp
 * @brief   A data screen from RouteSync's screen builder (see DataFace.hpp).
 ******************************************************************************
 */

#include "gui/widgets/DataFace.hpp"

#include <cstdio>
#include <cstring>

#include "SDK/Utils/ClockTime.hpp"

#include "gui/Format.hpp"
#include "gui/theme/Theme.hpp"

using namespace SDK::GUI;
using Field = ScreenLayout::Field;
using F = Theme::Font;

namespace
{
/// Largest first. The values only print digits and : . - + %, which the
/// numeric 60 and 40 faces carry.
constexpr F kSteps[] = { F::SemiBold60, F::SemiBold40, F::SemiBold35, F::SemiBold30, F::SemiBold25 };
constexpr uint8_t kStepCount = sizeof(kSteps) / sizeof(kSteps[0]);
constexpr uint8_t kStep60 = 0, kStep40 = 1, kStep35 = 2, kStep30 = 3;

constexpr uint32_t kZoneColor[] = {
    Color::GRAY, Color::CHARTREUSE, Color::YELLOW, Color::YELLOW_DARK, Color::RED
};

int32_t lineHeight(uint8_t step)
{
    return lv_font_get_line_height(Theme::font(kSteps[step]));
}

/// 1 to 5, as the zone arc counts them, or 0 below the first.
int zoneOf(float bpm, const uint8_t* thresholds, uint8_t count)
{
    if (!thresholds || bpm < App::Display::kMinHR) {
        return 0;
    }
    int zone = 0;
    for (uint8_t i = 0; i < count && i < 5; ++i) {
        if (bpm > thresholds[i]) {
            zone = i + 1;
        }
    }
    return zone;
}

/// "m:ss" under an hour, then "h:mm:ss".
void duration(char* buf, size_t n, std::time_t sec)
{
    if (sec < 3600) {
        const auto t = SDK::Utils::toHMS(sec);
        snprintf(buf, n, "%u:%02u", t.m, t.s);
    } else {
        Fmt::hms(buf, n, sec);
    }
}
} // namespace

DataFace::DataFace(lv_obj_t* parent)
{
    mRoot = Theme::container(parent, 0, 0, 240, 240);
    mZoneHost = Theme::container(mRoot, 0, 0, 240, 240);
    mZone = std::make_unique<Widgets::HeartRateZone>(mZoneHost, 15, 4);
    mLine1   = Theme::hline(mRoot, 35, 79, 170);
    mLine2   = Theme::hline(mRoot, 35, 159, 170);
    mDivider = Theme::vline(mRoot, 119, 92, 60);
    for (Slot& slot : mSlots) {
        slot.caption = Theme::label(mRoot, F::Italic18, "", 0, 0, 240);
        slot.value   = Theme::label(mRoot, F::SemiBold40, "", 0, 0, LV_SIZE_CONTENT, LV_TEXT_ALIGN_LEFT);
    }
}

void DataFace::place(Slot& slot, int32_t centreX, int32_t top, int32_t width, uint8_t maxFont,
                     int32_t captionY, int32_t captionW)
{
    slot.centreX = centreX;
    slot.top     = top;
    slot.width   = width;
    slot.maxFont = maxFont;
    slot.font    = 0xFF;
    slot.textLen = 0;
    lv_label_set_text(slot.value, "");
    lv_obj_set_pos(slot.caption, centreX - captionW / 2, captionY);
    lv_obj_set_width(slot.caption, captionW);
    lv_obj_set_style_text_align(slot.caption, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_remove_flag(slot.caption, LV_OBJ_FLAG_HIDDEN);
    lv_obj_remove_flag(slot.value, LV_OBJ_FLAG_HIDDEN);
}

void DataFace::setScreen(const ScreenLayout::Screen& screen)
{
    mScreen = screen;
    const uint8_t n = screen.fieldCount;
    for (Slot& slot : mSlots) {
        lv_obj_add_flag(slot.caption, LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(slot.value, LV_OBJ_FLAG_HIDDEN);
    }
    Theme::setHidden(mLine1,   n < 2);
    Theme::setHidden(mLine2,   n < 3);
    Theme::setHidden(mDivider, n != 4);

    switch (n) {
        case 1:
            place(mSlots[0], 120, 76, 210, kStep60, 50, 200);
            break;
        case 2:
            place(mSlots[0], 120, 48, 190, kStep60, 26, 160);
            lv_obj_set_y(mLine1, 136);
            place(mSlots[1], 120, 142, 190, kStep40, 198, 140);
            break;
        case 3:
            // The Run and Totals screens' places.
            place(mSlots[0], 120, 30, 200, kStep40, 8, 140);
            lv_obj_set_y(mLine1, 79);
            place(mSlots[1], 120, 111, 180, kStep35, 86, 200);
            place(mSlots[2], 120, 162, 170, kStep35, 204, 150);
            break;
        default:
            place(mSlots[0], 120, 30, 200, kStep40, 8, 140);
            lv_obj_set_y(mLine1, 79);
            place(mSlots[1], 68, 111, 100, kStep30, 86, 104);
            place(mSlots[2], 172, 111, 100, kStep30, 86, 104);
            place(mSlots[3], 120, 162, 170, kStep35, 204, 150);
            break;
    }

    // The zone arc runs over the top caption's place, so with HR on top the
    // caption moves beside the value, as on the old Run screen.
    const bool arc = n >= 3 && screen.fields[0] == Field::HR;
    Theme::setHidden(mZoneHost, !arc);
    for (uint8_t i = 0; i < n; ++i) {
        lv_label_set_text(mSlots[i].caption, caption(screen.fields[i], mImperial));
    }
    if (arc) {
        lv_obj_set_width(mSlots[0].caption, 50);
        lv_obj_set_style_text_align(mSlots[0].caption, LV_TEXT_ALIGN_LEFT, 0);
    }
}

void DataFace::show(const Track::Data& data, const Context& context)
{
    if (context.imperial != mImperial) {
        mImperial = context.imperial;
        setScreen(mScreen);
    }
    char buf[16];
    for (uint8_t i = 0; i < mScreen.fieldCount; ++i) {
        uint32_t color = Color::WHITE;
        format(mScreen.fields[i], data, context, buf, sizeof(buf), color);
        setValue(mSlots[i], buf, color);
    }
    if (!lv_obj_has_flag(mZoneHost, LV_OBJ_FLAG_HIDDEN) && context.hrThresholds) {
        mZone->setHR(data.hr < App::Display::kMinHR ? 0.0f : data.hr, context.hrThresholds, context.hrThresholdCount);
        // "HR" beside the value.
        lv_obj_set_pos(mSlots[0].caption, lv_obj_get_x(mSlots[0].value) + lv_obj_get_width(mSlots[0].value) + 6,
                       mSlots[0].top + 20);
    }
}

void DataFace::setValue(Slot& slot, const char* text, uint32_t color)
{
    lv_obj_set_style_text_color(slot.value, lv_color_hex(color), 0);
    const char* old = lv_label_get_text(slot.value);
    if (slot.font != 0xFF && std::strcmp(old, text) == 0) {
        return;
    }
    lv_label_set_text(slot.value, text);
    const auto len = static_cast<uint16_t>(std::strlen(text));
    // Find the font afresh when the length changes; otherwise only step down
    // if the new text no longer fits.
    uint8_t step = (len != slot.textLen || slot.font == 0xFF) ? slot.maxFont : slot.font;
    slot.textLen = len;
    for (;; ++step) {
        lv_obj_set_style_text_font(slot.value, Theme::font(kSteps[step]), 0);
        lv_obj_update_layout(slot.value);
        if (lv_obj_get_width(slot.value) <= slot.width || step + 1 >= kStepCount) {
            break;
        }
    }
    slot.font = step;
    const int32_t w = lv_obj_get_width(slot.value);
    const int32_t y = slot.top + (lineHeight(slot.maxFont) - lineHeight(step)) / 2;
    lv_obj_set_pos(slot.value, slot.centreX - w / 2, y);
}

const char* DataFace::caption(Field field, bool imperial)
{
    switch (field) {
        case Field::PACE:         return "Pace";
        case Field::AVG_PACE:     return "Avg Pace";
        case Field::LAP_PACE:     return "Lap Pace";
        case Field::DISTANCE:     return imperial ? "Miles" : "Kilometres";
        case Field::LAP_DISTANCE: return imperial ? "Lap Miles" : "Lap km";
        case Field::TIME:         return "Time";
        case Field::LAP_TIME:     return "Lap Time";
        case Field::LAPS:         return "Lap";
        case Field::HR:           return "HR";
        case Field::AVG_HR:       return "Avg HR";
        case Field::MAX_HR:       return "Max HR";
        case Field::LAP_HR:       return "Lap HR";
        case Field::HR_ZONE:      return "HR Zone";
        case Field::SPEED:        return imperial ? "mph" : "km/h";
        case Field::AVG_SPEED:    return imperial ? "Avg mph" : "Avg km/h";
        case Field::ELEVATION:    return imperial ? "Elevation ft" : "Elevation m";
        case Field::CALORIES:     return "Calories";
        case Field::INTENSITY:    return "Intensity";
        case Field::CONDITION:    return "Condition";
        case Field::CLOCK:        return "Time of Day";
        case Field::BATTERY:      return "Battery";
        default:                  return "";
    }
}

void DataFace::format(Field field, const Track::Data& d, const Context& c, char* buf, size_t n, uint32_t& color)
{
    const float speedScale = c.imperial ? 2.236936f : 3.6f;
    switch (field) {
        case Field::PACE:         Fmt::pace(buf, n, Fmt::paceUnits(d.pace, c.imperial)); break;
        case Field::AVG_PACE:     Fmt::pace(buf, n, Fmt::paceUnits(d.avgPace, c.imperial)); break;
        case Field::LAP_PACE:     Fmt::pace(buf, n, Fmt::paceUnits(d.lapPace, c.imperial)); break;
        case Field::DISTANCE:     Fmt::distanceTotal(buf, n, Fmt::distUnits(d.distance, c.imperial)); break;
        case Field::LAP_DISTANCE: Fmt::distanceLap(buf, n, Fmt::distUnits(d.lapDistance, c.imperial)); break;
        case Field::TIME:         Fmt::hms(buf, n, d.totalTime); break;
        case Field::LAP_TIME:     duration(buf, n, d.lapTime); break;
        case Field::LAPS:         snprintf(buf, n, "%lu", static_cast<unsigned long>(d.lapNum + 1)); break;
        case Field::HR:           Fmt::heartRate(buf, n, d.hr); break;
        case Field::AVG_HR:       Fmt::heartRate(buf, n, d.avgHR); break;
        case Field::MAX_HR:       Fmt::heartRate(buf, n, d.maxHR); break;
        case Field::LAP_HR:       Fmt::heartRate(buf, n, d.avgLapHR); break;
        case Field::HR_ZONE: {
            const int zone = zoneOf(d.hr, c.hrThresholds, c.hrThresholdCount);
            if (zone == 0) {
                snprintf(buf, n, "---");
            } else {
                snprintf(buf, n, "%d", zone);
                color = kZoneColor[zone - 1];
            }
        } break;
        case Field::SPEED:        Fmt::fixed(buf, n, d.speed * speedScale, 1); break;
        case Field::AVG_SPEED:    Fmt::fixed(buf, n, d.avgSpeed * speedScale, 1); break;
        case Field::ELEVATION:
            snprintf(buf, n, "%ld", static_cast<long>(lroundf(c.imperial ? d.elevation * 3.28084f : d.elevation)));
            break;
        case Field::CALORIES:     snprintf(buf, n, "%u", Fmt::calories(d.distance, c.weightLb)); break;
        case Field::INTENSITY:    Fmt::fixed(buf, n, d.intensity, 2); break;
        case Field::CONDITION:
            if (d.conditionStatus == Track::ConditionStatus::READY) {
                snprintf(buf, n, "%+d", d.condition);
                color = d.condition >= c.conditionFresh  ? Color::GREEN
                      : d.condition >= c.conditionNormal ? Color::WHITE
                      : d.condition >= c.conditionTired  ? Color::YELLOW
                                                         : Color::RED;
            } else {
                snprintf(buf, n, "---");
            }
            break;
        case Field::CLOCK: {
            const SDK::Clock::Hour12 civil = SDK::Clock::to12Hour(c.hour);
            snprintf(buf, n, "%u:%02u", c.is12Hour ? civil.hour : c.hour, c.minute);
        } break;
        case Field::BATTERY:      snprintf(buf, n, "%u%%", c.battery); break;
        default:                  snprintf(buf, n, "---"); break;
    }
}
