/**
 ******************************************************************************
 * @file    DataFace.hpp
 * @brief   A data screen from RouteSync's screen builder: one to four fields,
 *          each a value with its caption.
 *
 * The Track screen keeps one DataFace for all its data screens and lays it
 * out again on each page turn, so more screens cost no LVGL memory. A value
 * too wide for its slot steps down to a smaller font.
 ******************************************************************************
 */

#ifndef DATA_FACE_HPP
#define DATA_FACE_HPP

#include <cstdint>
#include <memory>

#include "lvgl.h"

#include "ScreenLayout.hpp"
#include "Track.hpp"
#include "gui/widgets/Widgets.hpp"

class DataFace
{
public:
    /// What the fields need besides the run's own numbers.
    struct Context {
        bool           imperial         = false;
        bool           is12Hour         = false;
        float          weightLb         = 165.0f;
        const uint8_t* hrThresholds     = nullptr;
        uint8_t        hrThresholdCount = 0;
        uint8_t        battery          = 0;
        uint8_t        hour             = 0;
        uint8_t        minute           = 0;
        int32_t        conditionFresh   = 3;   ///< The condition colours' cut-offs
        int32_t        conditionNormal  = -2;
        int32_t        conditionTired   = -7;
    };

    explicit DataFace(lv_obj_t* parent);

    lv_obj_t* root() const { return mRoot; }

    /// Lay out @p screen. Call show() after it to fill in the values.
    void setScreen(const ScreenLayout::Screen& screen);

    /// Fill in the values from the latest run data.
    void show(const Track::Data& data, const Context& context);

    /// The caption a field shows, with its unit where it has one.
    static const char* caption(ScreenLayout::Field field, bool imperial);

private:
    struct Slot {
        lv_obj_t* caption = nullptr;
        lv_obj_t* value   = nullptr;
        int32_t   centreX = 120;
        int32_t   top     = 0;     ///< Value top at the largest font
        int32_t   width   = 0;     ///< Widest the value may be
        uint8_t   maxFont = 0;     ///< Index into the font steps
        uint8_t   font    = 0xFF;  ///< The step in use
        uint16_t  textLen = 0;     ///< Re-fit only when the length changes
    };

    void place(Slot& slot, int32_t centreX, int32_t top, int32_t width, uint8_t maxFont,
               int32_t captionY, int32_t captionW);
    void setValue(Slot& slot, const char* text, uint32_t color);
    static void format(ScreenLayout::Field field, const Track::Data& data, const Context& context,
                       char* buf, size_t n, uint32_t& color);

    lv_obj_t* mRoot     = nullptr;
    lv_obj_t* mZoneHost = nullptr;  ///< The zone arc, when HR is the top field
    lv_obj_t* mLine1    = nullptr;
    lv_obj_t* mLine2    = nullptr;
    lv_obj_t* mDivider  = nullptr;  ///< Between the middle pair of four
    std::unique_ptr<Widgets::HeartRateZone> mZone;
    Slot      mSlots[ScreenLayout::kMaxFields];
    ScreenLayout::Screen mScreen;
    bool      mImperial = false;
};

#endif // DATA_FACE_HPP
